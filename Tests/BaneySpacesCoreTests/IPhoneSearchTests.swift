import XCTest
@testable import BaneySpacesCore

/// Donovan, 2026-11-01 (12:25 recording): "include in the search things like snapchat and have it open in
/// the mirroring view." Typing "snapchat" gave web and install rows only.
final class IPhoneSearchTests: XCTestCase {
    // MARK: Rows

    func testEverySearchGetsASearchRowWhileMirroringIsInstalled() {
        let rows = IPhoneSearch.rows("snapchat", apps: [], installed: true)
        XCTAssertEqual(rows.map(\.title), ["Search iPhone for “snapchat”"])
        XCTAssertEqual(rows[0].kind, .search("snapchat"))
    }

    func testNoRowsWithoutMirroringOrWithNothingTyped() {
        XCTAssertTrue(IPhoneSearch.rows("snapchat", apps: [], installed: false).isEmpty)
        XCTAssertTrue(IPhoneSearch.rows("  ", apps: [], installed: true).isEmpty)
    }

    func testAProvidersAppsComeFirstRankedLikeAppsAndTheSearchRowLast() {
        let apps = [IPhoneApp(name: "Snapchat", bundleID: "com.toyopagroup.picaboo"), IPhoneApp(name: "Snap Chess"),
                    IPhoneApp(name: "Weather")]
        let rows = IPhoneSearch.rows("snap", apps: apps, installed: true)
        XCTAssertEqual(rows.map(\.title), ["Snapchat · iPhone", "Snap Chess · iPhone", "Search iPhone for “snap”"],
                       "the shorter name first, as apps rank")
        XCTAssertEqual(IPhoneSearch.rows("snapchat", apps: apps, installed: true).first?.title, "Snapchat · iPhone")
        XCTAssertFalse(rows.contains { $0.title.contains("Weather") })
    }

    func testAtMostThreeProviderAppsAreShown() {
        let apps = (0..<10).map { IPhoneApp(name: "Game \($0)") }
        XCTAssertEqual(IPhoneSearch.rows("game", apps: apps, installed: true).count, IPhoneSearch.appLimit + 1)
    }

    func testRowsRankBelowRealAppsAndAboveTheWebInTheLauncher() throws {
        let launcher = try Repo.code("Sources/BaneySpaces/Launcher.swift")
        let apps = try XCTUnwrap(launcher.range(of: "out += appItems(q, limit: 8)"))
        let phone = try XCTUnwrap(launcher.range(of: "out += iphoneItems(q)"))
        let web = try XCTUnwrap(launcher.range(of: "out += searchEverywhere(q).prefix(3)"))
        XCTAssertLessThan(apps.lowerBound, phone.lowerBound)
        XCTAssertLessThan(phone.lowerBound, web.lowerBound)
    }

    // MARK: State

    func testTheStatesMirroringReports() {
        XCTAssertEqual(IPhoneState.classify(["Unlock Your iPhone", "Follow the instructions"]).state, .needsUnlock)
        XCTAssertEqual(IPhoneState.classify(["Unable to Connect to iPhone"]).state, .unavailable)
        XCTAssertEqual(IPhoneState.classify(["Mac Locked"]).state, .macLocked)
        XCTAssertEqual(IPhoneState.classify(["Connecting to Donovan’s iPhone"]).state, .connecting)
        XCTAssertEqual(IPhoneState.classify(["Home Screen"]).state, .ready)
        XCTAssertEqual(IPhoneState.classify([]).state, .unknown)
        XCTAssertEqual(IPhoneState.classify(["Unlock Your iPhone", "Connecting to X"]).state, .needsUnlock, "a reason beats 'connecting'")
    }

    func testTheRowShowsMirroringsOwnWordsWhenItCantSearch() {
        let rows = IPhoneSearch.rows("snap", apps: [], installed: true, state: .needsUnlock, phrase: "Unlock Your iPhone")
        XCTAssertEqual(rows[0].subtitle, "Unlock Your iPhone")
        XCTAssertEqual(IPhoneSearch.rows("snap", apps: [], installed: true, state: .unavailable)[0].subtitle, "Unable to Connect to iPhone")
        XCTAssertEqual(IPhoneSearch.rows("snap", apps: [], installed: true, state: .ready)[0].subtitle, "Asks iPhone Mirroring's Spotlight")
    }

    func testAnotherLanguagesPhrasesAreMatched() {
        let de = IPhoneState.Phrases(needsUnlock: "iPhone entsperren", unavailable: "Verbindung nicht möglich",
                                     macLocked: "Mac gesperrt", connecting: "Verbindung mit")
        XCTAssertEqual(IPhoneState.classify(["iPhone entsperren"], phrases: de).state, .needsUnlock)
        XCTAssertEqual(IPhoneState.classify(["iPhone entsperren"], phrases: de).phrase, "iPhone entsperren")
    }

    func testOnlyReadyOrUnreadableCanTakeASearch() {
        XCTAssertTrue(IPhoneState.ready.canSearch)
        XCTAssertTrue(IPhoneState.unknown.canSearch, "the phone's screen is video: no text isn't a refusal")
        for s in [IPhoneState.needsUnlock, .unavailable, .macLocked, .connecting] { XCTAssertFalse(s.canSearch, "\(s)") }
    }

    // MARK: The menu item

    func testSpotlightIsFoundByItsOwnTitleOrByTheWord() {
        XCTAssertTrue(IPhoneSearch.isSpotlightItem("Spotlight", known: []))
        XCTAssertTrue(IPhoneSearch.isSpotlightItem("Spotlight-Suche", known: []))
        XCTAssertTrue(IPhoneSearch.isSpotlightItem("Recherche", known: ["Recherche"]))
        XCTAssertFalse(IPhoneSearch.isSpotlightItem("Home Screen", known: ["Recherche"]))
        XCTAssertFalse(IPhoneSearch.isSpotlightItem("", known: []))
    }

    // MARK: The open sequence, with a fake Mirroring

    private final class Fake: MirroringDriver {
        var windowComes = true, current = IPhoneState.ready, hasItem = true, canType = true
        var calls: [String] = []
        func bringUp() -> Bool { calls.append("bringUp"); return windowComes }
        func state() -> IPhoneState { calls.append("state"); return current }
        func openSpotlight() -> Bool { calls.append("spotlight"); return hasItem }
        func type(_ text: String) -> Bool { calls.append("type:\(text)"); return canType }
    }

    func testTheSequenceBringsUpReadsOpensAndTypesInThatOrder() {
        let m = Fake()
        XCTAssertEqual(IPhoneOpen.run("snapchat", driver: m), .asked("snapchat"))
        XCTAssertEqual(m.calls, ["bringUp", "state", "spotlight", "type:snapchat"])
    }

    func testALockedPhoneTypesNothingAndSaysWhy() {
        let m = Fake()
        m.current = .needsUnlock
        XCTAssertEqual(IPhoneOpen.run("snapchat", driver: m), .blocked(.needsUnlock))
        XCTAssertEqual(m.calls, ["bringUp", "state"], "no menu, no keys")
        XCTAssertEqual(IPhoneOpen.message(.blocked(.needsUnlock), phrase: "Unlock Your iPhone"), "Unlock Your iPhone")
        XCTAssertEqual(IPhoneOpen.message(.blocked(.unavailable)), "Unable to Connect to iPhone")
    }

    func testEachStepThatFailsStopsTheSequence() {
        let a = Fake(); a.windowComes = false
        XCTAssertEqual(IPhoneOpen.run("x", driver: a), .noWindow)
        XCTAssertEqual(a.calls, ["bringUp"])
        let b = Fake(); b.hasItem = false
        XCTAssertEqual(IPhoneOpen.run("x", driver: b), .noSpotlightItem)
        XCTAssertFalse(b.calls.contains { $0.hasPrefix("type") })
        let c = Fake(); c.canType = false
        XCTAssertEqual(IPhoneOpen.run("x", driver: c), .typingFailed)
    }

    func testTheAnswerSaysAskedNeverOpened() {
        XCTAssertEqual(IPhoneOpen.message(.asked("Snapchat")), "Opened iPhone Mirroring and asked for “Snapchat”")
    }

    // MARK: Sources (the app target can't be imported)

    func testKeysGoToMirroringsPidOnlyAndTheMenuIsUsedFirst() throws {
        let code = try Repo.code("Sources/BaneySpaces/IPhoneMirroring.swift")
        XCTAssertTrue(code.contains(".postToPid(pid)"))
        XCTAssertFalse(code.contains(".post(tap:"), "no global HID post")
        XCTAssertTrue(code.contains(".privateState"), "no key or modifier state from the real keyboard")
        XCTAssertTrue(code.contains("IPhoneSearch.isSpotlightItem(title"), "the menu item is found by title")
        let seq = try Repo.code("Sources/BaneySpacesCore/IPhoneSearch.swift")
        let menu = try XCTUnwrap(seq.range(of: "driver.openSpotlight()"))
        let keys = try XCTUnwrap(seq.range(of: "driver.type(query)"))
        XCTAssertLessThan(menu.lowerBound, keys.lowerBound)
    }

    func testMirroringOpensHereAndTheQueryIsNeverLogged() throws {
        let delegate = try Repo.code("Sources/BaneySpaces/AppDelegate.swift")
        XCTAssertTrue(delegate.contains("launcher.openHere(app: IPhoneMirroring.path, target: target)"), "Mirroring's window goes to the target")
        XCTAssertTrue(delegate.contains("replacingOccurrences(of: query, with: \"…\")"), "the trace names the outcome, not the query")
    }
}
