import XCTest
@testable import BaneySpacesCore

final class LauncherTests: XCTestCase {
    func testPrefixBeatsWordBeatsInitialsBeatsScattered() throws {
        let prefix = try XCTUnwrap(Fuzzy.score("co", "Code"))
        let word = try XCTUnwrap(Fuzzy.score("co", "Visual Studio Code"))
        let initials = try XCTUnwrap(Fuzzy.score("vsc", "Visual Studio Code"))
        let scattered = try XCTUnwrap(Fuzzy.score("sfr", "Safari"))
        XCTAssertGreaterThan(prefix, word)
        XCTAssertGreaterThan(word, initials)
        XCTAssertGreaterThan(initials, scattered)
        XCTAssertNil(Fuzzy.score("zzz", "Safari"))
    }

    func testCaseAndAccentsDoNotMatter() {
        XCTAssertEqual(Fuzzy.score("CAFE", "Café"), 1000)
        XCTAssertEqual(Fuzzy.score("", "Anything"), 0)
    }

    func testCatalogSkipsDisabledAndDeprecated() {
        let json = """
        [{"token":"firefox","name":["Mozilla Firefox"],"desc":"Web browser","homepage":"https://firefox.com"},
         {"token":"old","name":["Old"],"desc":"","homepage":"","disabled":true},
         {"token":"older","name":["Older"],"desc":"","homepage":"","deprecated":true},
         {"token":"bare"}]
        """
        let casks = Cask.parseCatalog(Data(json.utf8))
        XCTAssertEqual(casks.map(\.token), ["firefox", "bare"])
        XCTAssertEqual(casks[0].name, "Mozilla Firefox")
        XCTAssertEqual(casks[1].name, "bare")
        XCTAssertEqual(Cask.parseCatalog(Data("not json".utf8)), [])
    }

    func testCaskSearchRanksNameOverDescription() {
        let casks = [
            Cask(token: "zen", name: "Zen", desc: "Gecko based web browser", homepage: ""),
            Cask(token: "firefox", name: "Mozilla Firefox", desc: "Web browser", homepage: ""),
            Cask(token: "obsidian", name: "Obsidian", desc: "Knowledge base", homepage: ""),
        ]
        XCTAssertEqual(Cask.search("firefox", in: casks).map(\.token), ["firefox"])
        // "browser" is in two descriptions and no names.
        XCTAssertEqual(Set(Cask.search("browser", in: casks).map(\.token)), ["zen", "firefox"])
        XCTAssertEqual(Cask.search("  ", in: casks), [])
        let font = Cask(token: "font-otomanopee-one", name: "Otomanopee One", desc: "", homepage: "")
        XCTAssertEqual(Cask.search("otomanopee", in: casks + [font]), [])
        XCTAssertEqual(Cask.search("font otomanopee", in: casks + [font]).map(\.token), ["font-otomanopee-one"])
    }

    func testRecentsMoveToFrontAndStayBounded() {
        var r = Recents()
        for i in 0..<40 { r.used("/Applications/App\(i).app") }
        XCTAssertEqual(r.paths.count, Recents.limit)
        r.used("/Applications/App20.app")
        XCTAssertEqual(r.paths.first, "/Applications/App20.app")
        XCTAssertEqual(r.paths.filter { $0 == "/Applications/App20.app" }.count, 1)
        XCTAssertGreaterThan(r.boost("/Applications/App20.app"), r.boost("/Applications/App39.app"))
        XCTAssertEqual(r.boost("/Applications/Nope.app"), 0)
    }
}
