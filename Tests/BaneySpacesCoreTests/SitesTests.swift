import XCTest
@testable import BaneySpacesCore

/// Donovan, 2026-11-01: "opening bookmarks that exist in the default browser or super frequently visited
/// sites ... if I search X an x icon pops up and can be pressed to open it in helium."
final class SitesTests: XCTestCase {
    // MARK: Fixtures (generic: structures a browser writes, not anyone's bookmarks)

    private let chromium = """
    {"roots":{"bookmark_bar":{"type":"folder","name":"Bar","children":[
      {"type":"url","name":"Course Portal","url":"https://portal.example.edu/courses?term=fall"},
      {"type":"folder","name":"Dev","children":[{"type":"url","name":"Swift Docs","url":"https://docs.example.org/swift/index"}]}]},
     "other":{"type":"folder","name":"Other","children":[
      {"type":"url","name":"Mail","url":"https://mail.example.com/"},
      {"type":"url","name":"A Script","url":"javascript:alert(1)"},
      {"type":"url","name":"A File","url":"file:///tmp/x"}]},
     "synced":{"type":"folder","name":"Mobile","children":[]}}}
    """

    private func safariPlist() throws -> Data {
        let root: [String: Any] = ["WebBookmarkType": "WebBookmarkTypeList", "Children": [
            ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://one.example.com/a", "URIDictionary": ["title": "One"]],
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "Folder", "Children": [
                ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://two.example.com", "URIDictionary": ["title": "Two"]]]],
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "com.apple.ReadingList", "Children": [
                ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://later.example.com", "URIDictionary": ["title": "Later"]]]],
        ]]
        return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    // MARK: Parsing

    func testChromiumBookmarksAreFlattenedAndOnlyWebAddressesKept() {
        let marks = BookmarkParse.chromium(Data(chromium.utf8))
        XCTAssertEqual(marks.map(\.title).sorted(), ["Course Portal", "Mail", "Swift Docs"])
        XCTAssertEqual(marks.first { $0.title == "Course Portal" }?.url, "https://portal.example.edu/courses?term=fall")
    }

    func testSafariBookmarksSkipTheReadingList() throws {
        let marks = BookmarkParse.safari(try safariPlist())
        XCTAssertEqual(marks.map(\.title).sorted(), ["One", "Two"])
    }

    func testNotABookmarksFileGivesNothing() {
        XCTAssertTrue(BookmarkParse.chromium(Data("nope".utf8)).isEmpty)
        XCTAssertTrue(BookmarkParse.safari(Data("nope".utf8)).isEmpty)
    }

    func testHistoryRowsBecomeSitesByHostWithOnlyAnOrigin() {
        let rows: [(url: String, visits: Int)] = [
            ("https://www.example.com/a/very/long/path?token=secret&q=private", 40),
            ("https://example.com/other", 10),
            ("https://news.example.org/story/1", 30),
            ("http://localhost:3000/app", 500), ("http://192.168.1.5/admin", 400), ("https://printer.local/", 300),
            ("chrome://settings", 90), ("file:///Users/x/doc.pdf", 80),
        ]
        let top = FrequentSites.top(rows)
        XCTAssertEqual(top.map(\.host), ["example.com", "news.example.org"])
        XCTAssertEqual(top[0].visits, 50, "pages of one site are summed")
        XCTAssertEqual(top[0].url, "https://www.example.com", "an origin only: no path, no query")
        XCTAssertFalse(top.contains { $0.url.contains("secret") || $0.url.contains("?") })
    }

    func testOnlyTheTopTwoHundredAreKept() {
        let rows = (0..<500).map { (url: "https://site\($0).example.com/", visits: 1000 - $0) }
        XCTAssertEqual(FrequentSites.top(rows).count, 200)
        XCTAssertEqual(FrequentSites.top(rows)[0].host, "site0.example.com")
    }

    func testHostOfAnAddress() {
        XCTAssertEqual(SiteCatalog.host(of: "https://WWW.GitHub.com/a/b?c=d"), "github.com")
        XCTAssertNil(SiteCatalog.host(of: "ftp://x.com"))
        XCTAssertNil(SiteCatalog.host(of: "not a url"))
    }

    // MARK: Ranking

    private func ids(_ q: String, _ index: SiteIndex = SiteIndex(), limit: Int = 3) -> [String] { index.rank(q, limit: limit).map(\.site.id) }

    func testAnExactAliasIsFirst() {
        XCTAssertEqual(ids("x").first, "x", "\"x\" gives X first")
        XCTAssertEqual(ids("yt").first, "youtube")
        XCTAssertEqual(ids("twitter").first, "x", "the old name is an alias")
        XCTAssertEqual(ids("gh").first, "github")
        XCTAssertTrue(SiteIndex().rank("x").first?.exactAlias == true)
    }

    func testOneLetterMatchesOnlyAnExactAlias() {
        XCTAssertEqual(ids("x"), ["x"], "not every site with an x in it")
        XCTAssertTrue(SiteIndex().rank("q").isEmpty)
    }

    func testPrefixesOfNamesAliasesAndDomains() {
        XCTAssertEqual(ids("git").first, "github")
        XCTAssertTrue(ids("goog", limit: 20).contains("google"))
        XCTAssertEqual(ids("snap").first, "snapchat")
        XCTAssertEqual(ids("spot").first, "spotify")
        XCTAssertTrue(SiteIndex().rank("zzzzqq").isEmpty)
    }

    func testSitesOnTheSameHostStayDistinct() {
        let all = ids("google", limit: 20)
        XCTAssertTrue(all.contains("google-docs") && all.contains("google-sheets") && all.contains("google-slides"))
    }

    func testYourBookmarksAndMostVisitedSitesAreFound() {
        let marks = BookmarkParse.chromium(Data(chromium.utf8))
        let frequent = FrequentSites.top([("https://forum.example.net/thread/5", 90)])
        let index = SiteIndex(bookmarks: marks, frequent: frequent)
        XCTAssertEqual(ids("course", index).first, "https://portal.example.edu/courses?term=fall")
        XCTAssertEqual(index.rank("course").first?.site.source, .bookmark)
        XCTAssertEqual(ids("swift", index).first, "https://docs.example.org/swift/index")
        XCTAssertEqual(index.rank("forum").first?.site.source, .frequent)
        XCTAssertEqual(index.rank("forum").first?.site.host, "forum.example.net")
    }

    func testAMostVisitedSiteTheListAlreadyNamesIsNotRepeated() {
        let frequent = FrequentSites.top([("https://github.com/someone/repo", 500)])
        let hits = SiteIndex(frequent: frequent).rank("github")
        XCTAssertEqual(hits.map(\.site.source), [.builtIn])
    }

    func testNativeAppsAndPhoneAppsComeFromTheList() {
        let spotify = SiteCatalog.builtIn.first { $0.id == "spotify" }
        XCTAssertEqual(spotify?.nativeApps, ["Spotify"])
        XCTAssertEqual(spotify?.iphoneApp, "Spotify")
        XCTAssertEqual(SiteCatalog.builtIn.first { $0.id == "x" }?.iphoneApp, "X")
        XCTAssertNil(SiteCatalog.builtIn.first { $0.id == "wikipedia" }?.iphoneApp)
    }

    // MARK: Timing (rows from memory inside the app budget)

    func testRowsComeInUnder16MsAtP90WithThousandsOfBookmarks() {
        let marks = (0..<5_000).map { Bookmark(title: "Page number \($0) about topic \($0 % 97)", url: "https://host\($0 % 900).example.com/p/\($0)") }
        let frequent = FrequentSites.top((0..<400).map { (url: "https://visited\($0).example.org/", visits: 400 - $0) })
        let index = SiteIndex(bookmarks: marks, frequent: frequent)
        var samples: [Double] = []
        for _ in 0..<30 {
            let t = DispatchTime.now().uptimeNanoseconds
            for q in ["x", "yt", "pa", "topic 4", "visit"] { _ = index.rank(q) }
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6 / 5)
        }
        let p90 = samples.sorted()[27]
        print("sites: 5,000 bookmarks + 200 most visited + 68 built in, per keystroke p90 \(String(format: "%.2f", p90)) ms")
        XCTAssertLessThan(p90, 16)
    }

    // MARK: The shared list (spec/sites.json)

    func testTheSwiftListIsTheSpecList() throws {
        let data = try Repo.text("spec/sites.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any])
        let sites = try XCTUnwrap(json["sites"] as? [[String: Any]])
        XCTAssertEqual(sites.count, SiteCatalog.entries.count, "run scripts/gen-sites-data.sh")
        for (spec, e) in zip(sites, SiteCatalog.entries) {
            XCTAssertEqual(spec["id"] as? String, e.id)
            XCTAssertEqual(spec["name"] as? String, e.name)
            XCTAssertEqual(spec["url"] as? String, e.url)
            XCTAssertEqual(spec["aliases"] as? [String], e.aliases)
            XCTAssertEqual(spec["native"] as? [String] ?? [], e.native)
            XCTAssertEqual(spec["iphone"] as? String, e.iphone)
        }
        XCTAssertGreaterThanOrEqual(sites.count, 60)
        XCTAssertEqual(Set(sites.compactMap { $0["id"] as? String }).count, sites.count, "ids are unique")
    }

    func testEveryBuiltInSiteIsAWebAddressWithAnAlias() {
        for e in SiteCatalog.entries {
            XCTAssertNotNil(SiteCatalog.host(of: e.url), e.id)
            XCTAssertFalse(e.aliases.isEmpty, e.id)
        }
    }
}

/// What the app may read and write down (spec/launcher.md, "Privacy").
final class SiteRulesTests: XCTestCase {
    func testNoAddressOrHostIsEverLogged() throws {
        for file in ["Sources/BaneySpaces/SiteSources.swift", "Sources/BaneySpaces/Launcher.swift", "Sources/BaneySpaces/AppDelegate.swift"] {
            let code = try Repo.code(file)
            for chunk in code.components(separatedBy: "Trace.log(").dropFirst() {
                let line = String(chunk.prefix(while: { $0 != "\n" }))
                if line.contains("site") || line.contains("sites") {
                    for bad in ["url", "address", ".host", ".name", "title", "bookmark.", "site.id"] {
                        XCTAssertFalse(line.contains("\\(") && line.contains(bad) && !line.contains("bookmarks=") , "\(file): \(line)")
                    }
                }
            }
        }
        let sources = try Repo.code("Sources/BaneySpaces/SiteSources.swift")
        XCTAssertTrue(sources.contains("Trace.log(\"sites: bookmarks=\\(bookmarks.count) frequent=\\(frequent.count) icons=\\(iconCount)\")"))
    }

    func testOnlyTheNamedColumnsAreReadAndNothingElseOfTheBrowser() throws {
        let code = try Repo.code("Sources/BaneySpaces/SiteSources.swift")
        XCTAssertTrue(code.contains("SELECT url, visit_count FROM urls ORDER BY visit_count DESC LIMIT 3000"))
        XCTAssertTrue(code.contains("SQLITE_OPEN_READONLY"))
        XCTAssertTrue(code.contains("try? fm.removeItem(at: dir)"), "the copy is deleted")
        for never in ["Cookies", "Login Data", "Web Data", "keyword_search_terms", "downloads", "visit_time", "form_history", "autofill", "Preferences\""] {
            XCTAssertFalse(code.contains(never), "the browser's \(never) is never opened")
        }
        // The only files read from the profile.
        for name in ["\"Bookmarks\"", "\"History\"", "\"Favicons\"", "\"Local State\""] { XCTAssertTrue(code.contains(name), name) }
        XCTAssertFalse(code.contains("URLSession") || code.contains("dataTask") || code.contains("https://www.google.com/s2/favicons"), "nothing over the network")
    }

    func testSiteRowsRankAboveTheWebAndBelowApps() throws {
        let launcher = try Repo.code("Sources/BaneySpaces/Launcher.swift")
        let apps = try XCTUnwrap(launcher.range(of: "out += appItems(q, limit: 8)"))
        let sites = try XCTUnwrap(launcher.range(of: "out += siteItems(q)"))
        let phone = try XCTUnwrap(launcher.range(of: "out += iphoneItems(q)"))
        let web = try XCTUnwrap(launcher.range(of: "out += searchEverywhere(q).prefix(3)"))
        XCTAssertLessThan(apps.lowerBound, sites.lowerBound)
        XCTAssertLessThan(sites.lowerBound, phone.lowerBound)
        XCTAssertLessThan(phone.lowerBound, web.lowerBound)
    }

    func testSecondaryActionsForThePhoneAndForNativeApps() throws {
        let launcher = try Repo.code("Sources/BaneySpaces/Launcher.swift")
        XCTAssertTrue(launcher.contains("(\"Open on iPhone\""), "a site with an app on the phone offers it")
        XCTAssertTrue(launcher.contains("!hasNativeApp($0.site)"), "a site with a native app on this Mac is not a row of its own")
        XCTAssertTrue(launcher.contains("Self.sitesByNativeApp[Fuzzy.fold(a.name)]"), "the app row offers the site")
        XCTAssertTrue(launcher.contains("if let second = items[selected].secondary { close(); second.run(); return }"), "Tab runs it")
        XCTAssertFalse(launcher.contains("FileManager") && launcher.contains("Bookmarks\"") , "no file is read while rows are built")
    }

    func testOpeningASiteIsOpenHere() throws {
        let delegate = try Repo.code("Sources/BaneySpaces/AppDelegate.swift")
        XCTAssertTrue(delegate.contains("OpenHere.plan(.init(target: target, running: running != nil, windowsOn: on, windowCommand: known)"))
        XCTAssertTrue(delegate.contains("spaces.expectLaunch(bundle: bundle, on: target)"), "a browser that starts is registered first")
        XCTAssertTrue(delegate.contains("Trace.log(\"open site: \\(action) on workspace \\(target)\")"))
    }
}
