import XCTest
@testable import BaneySpacesCore

/// The decisions behind full screen (`FullScreen.swift`). The scenarios that put them together as a
/// switch are in `FullScreenScenarioTests`.
final class FullScreenTests: XCTestCase {
    // MARK: What the window server says

    /// `CGSCopyManagedDisplaySpaces` on Donovan's Mac, 2026-11-01, with Helium (pid 1507) in full
    /// screen: a full-screen desktop has `type` 4 and `fs_wid`, the window that owns it.
    private func displays(fullScreenWindow: Int? = 98718, current: Int = 3585) -> [[String: Any]] {
        var spaces: [[String: Any]] = [["id64": 3, "ManagedSpaceID": 3, "type": 0, "uuid": "6B5C2390"]]
        if let w = fullScreenWindow {
            spaces.append(["type": 4, "fs_wid": w, "pid": 1507, "ManagedSpaceID": 3585, "id64": 3585, "uuid": "ABF1BF3C",
                           "TileLayoutManager": ["TileSpaces": [["type": 5, "fs_wid": w, "pid": 1507]]]])
        }
        return [["Display Identifier": "37D8832A", "Current Space": ["ManagedSpaceID": current, "type": 4], "Spaces": spaces]]
    }

    func testAFullScreenDesktopIsReadFromTheSpacesList() {
        let found = FullScreenSpaces.parse(displays())
        XCTAssertEqual(found, [FullScreenSpace(space: 3585, display: "37D8832A", window: 98718, pid: 1507, isCurrent: true)])
    }

    func testOrdinaryDesktopsAreNotFullScreen() {
        XCTAssertEqual(FullScreenSpaces.parse(displays(fullScreenWindow: nil, current: 3)), [])
        XCTAssertEqual(FullScreenSpaces.parse([]), [])
    }

    func testADesktopThatIsNotShownIsStillFullScreen() {
        XCTAssertEqual(FullScreenSpaces.parse(displays(current: 3)).map(\.isCurrent), [false])
    }

    func testAWindowIsOnAFullScreenDesktopByItsSpaces() {
        let fs = FullScreenSpaces.parse(displays())
        XCTAssertEqual(FullScreenSpaces.contains([3585], in: fs), .yes)
        // Split View: a second window shares the desktop.
        XCTAssertEqual(FullScreenSpaces.contains([3, 3585], in: fs), .yes)
        XCTAssertEqual(FullScreenSpaces.contains([3], in: fs), .no)
        XCTAssertEqual(FullScreenSpaces.contains([], in: fs), .no)
        XCTAssertEqual(FullScreenSpaces.contains(nil, in: fs), .unknown, "the window server not answering is not a no")
        XCTAssertEqual(FullScreenSpaces.contains([3], in: []), .no)
    }

    /// A window on a full-screen desktop that the model has never heard of can't be hidden, shown or found.
    func testAFullScreenWindowTheModelDoesNotKnowIsReported() {
        let fs = FullScreenSpaces.parse(displays())
        XCTAssertEqual(FullScreenSpaces.missing(fs, known: [98718]), [])
        XCTAssertEqual(FullScreenSpaces.missing(fs, known: [1, 2]).map(\.window), [98718])
    }

    // MARK: Is it in full screen

    private func call(_ desktop: Answer, _ attribute: Answer, _ size: Answer = .unknown) -> FullScreenCall {
        FullScreenDecision.call(FullScreenEvidence(desktop: desktop, attribute: attribute, screenSized: size))
    }

    func testTheWindowServerAloneIsEnough() {
        XCTAssertTrue(call(.yes, .unknown).needsLeaving)
        XCTAssertTrue(call(.yes, .no).needsLeaving, "an app saying no does not undo a full-screen desktop")
    }

    /// The old check needed a screen-sized frame. Split View windows are half a screen.
    func testASplitViewWindowIsInFullScreenWithoutBeingScreenSized() {
        XCTAssertEqual(call(.yes, .yes, .no).word, "in-full-screen")
    }

    /// The old check read an app that didn't answer as "not in full screen".
    func testAnAppThatDoesNotAnswerIsNotOutOfFullScreen() {
        XCTAssertTrue(call(.yes, .unknown, .yes).needsLeaving)
        XCTAssertTrue(call(.unknown, .unknown, .yes).needsLeaving, "screen-sized, and nobody can say: not provably out")
        XCTAssertEqual(call(.unknown, .unknown, .yes).word, "cannot-tell")
    }

    func testAttributeAddsAWindowThatIsEnteringFullScreen() {
        XCTAssertTrue(call(.no, .yes).needsLeaving)
    }

    /// (k) A window the size of the screen that is not in full screen.
    func testAScreenSizedWindowOnNoFullScreenDesktopIsOut() {
        XCTAssertTrue(call(.no, .no, .yes).isOut)
        XCTAssertTrue(call(.no, .unknown, .yes).isOut, "an app that doesn't answer doesn't make it full screen")
        XCTAssertTrue(call(.unknown, .no, .yes).isOut)
        XCTAssertTrue(call(.unknown, .unknown, .no).isOut)
    }

    func testEveryCallSaysWhy() {
        for d in [Answer.yes, .no, .unknown] { for a in [Answer.yes, .no, .unknown] { for s in [Answer.yes, .no, .unknown] {
            XCTAssertFalse(call(d, a, s).reason.isEmpty)
        } } }
    }

    // MARK: Refusals and the plan

    private let t0 = Date(timeIntervalSince1970: 5000)

    func testARefusalIsRemembered() {
        var r = RefusedFullScreen()
        r.refuse(7, now: t0)
        XCTAssertTrue(r.contains(7, now: t0.addingTimeInterval(60)))
        XCTAssertFalse(r.contains(7, now: t0.addingTimeInterval(RefusedFullScreen.memory + 1)), "an app that was only busy gets another try")
        r.forget(7)
        XCTAssertFalse(r.contains(7, now: t0))
    }

    func testAClosedWindowIsForgottenByARefusal() {
        var r = RefusedFullScreen()
        r.refuse(7, now: t0); r.refuse(8, now: t0)
        r.keep(alive: [8])
        XCTAssertEqual(r.ids, [8])
    }

    func testAskedOrCarried() {
        var r = RefusedFullScreen()
        r.refuse(2, now: t0)
        let calls: [WindowID: FullScreenCall] = [1: .inFullScreen("x"), 2: .inFullScreen("x"), 3: .notInFullScreen("x"), 4: .cannotTell("x")]
        let p = FullScreenSwitch.plan(hide: [1, 2, 3, 4, 5], calls: calls, refused: r, now: t0)
        XCTAssertEqual(p.ask, [1, 4])
        XCTAssertEqual(p.carry, [2])
    }

    func testAWindowThatDidNotAnswerHasNotLeft() {
        let after: [WindowID: FullScreenCall] = [1: .notInFullScreen("x"), 2: .cannotTell("x"), 3: .inFullScreen("x")]
        XCTAssertEqual(FullScreenSwitch.refused(asked: [1, 2, 3, 4], after: after), [2, 3, 4], "no reading at all is not a window that left")
    }

    // MARK: The audit

    private func obs(_ id: WindowID, ws: Int, onScreen: Bool = true, parked: Bool = false, hidden: Bool = false, spot: Bool = false,
                     minimized: Bool = false, fs: Bool = false, kept: Bool = false) -> WindowObservation {
        WindowObservation(id: id, app: "App\(id)", workspace: ws, onScreen: onScreen, parked: parked, appHidden: hidden,
                          atHidingSpot: spot, minimized: minimized, onFullScreenDesktop: fs, closedButKept: kept)
    }

    func testAShownWindowDrawnOnScreenIsFine() {
        XCTAssertEqual(VanishAudit.findings([obs(1, ws: 1)], shown: [1]), [])
    }

    func testAWindowHiddenByUsIsFine() {
        let w = [obs(1, ws: 2, onScreen: false, hidden: true), obs(2, ws: 2, parked: true, spot: true), obs(3, ws: 2, onScreen: false, minimized: true)]
        XCTAssertEqual(VanishAudit.findings(w, shown: [1]), [])
    }

    func testAHiddenWorkspaceWindowOnAFullScreenDesktopIsFlagged() {
        let f = VanishAudit.findings([obs(9, ws: 2, onScreen: false, hidden: true, fs: true)], shown: [1])
        XCTAssertEqual(f.map(\.kind), [.hiddenButInFullScreen])
        XCTAssertEqual(f.first?.line, "window=9 app=App9 workspace=2 hidden-but-in-full-screen")
        XCTAssertEqual(VanishAudit.repairable(f), f)
    }

    func testAShownWindowOnItsFullScreenDesktopIsFine() {
        XCTAssertEqual(VanishAudit.findings([obs(9, ws: 1, onScreen: false, fs: true)], shown: [1]), [])
    }

    func testNeitherShownNorHiddenByUs() {
        // On a shown workspace but not drawn, and not minimized, not on a full-screen desktop.
        XCTAssertEqual(VanishAudit.findings([obs(1, ws: 1, onScreen: false)], shown: [1]).map(\.kind), [.shownButNotVisible])
        XCTAssertEqual(VanishAudit.findings([obs(1, ws: 1, onScreen: false, hidden: true)], shown: [1]).map(\.kind), [.shownButNotVisible])
        // On a hidden workspace but drawn, not parked, its app not hidden.
        XCTAssertEqual(VanishAudit.findings([obs(2, ws: 2)], shown: [1]).map(\.kind), [.inSightOnHiddenWorkspace])
        // On a hidden workspace, not drawn, not parked, app not hidden: nothing of ours put it away.
        XCTAssertEqual(VanishAudit.findings([obs(3, ws: 2, onScreen: false)], shown: [1]).map(\.kind), [.neitherShownNorHidden])
        // On a shown workspace at the hiding spot.
        XCTAssertEqual(VanishAudit.findings([obs(4, ws: 1, spot: true)], shown: [1]).map(\.kind), [.shownButParked])
    }

    func testOnlyAFullScreenFindingIsRepairable() {
        let f = VanishAudit.findings([obs(2, ws: 2), obs(3, ws: 2, onScreen: false, fs: true)], shown: [1])
        XCTAssertEqual(f.count, 2)
        XCTAssertEqual(VanishAudit.repairable(f).map(\.id), [3])
    }

    func testAClosedButKeptWindowIsNotAFinding() {
        XCTAssertEqual(VanishAudit.findings([obs(1, ws: 2, onScreen: false, kept: true)], shown: [1]), [])
    }

    func testFindingsAreInWindowOrder() {
        let f = VanishAudit.findings([obs(5, ws: 2), obs(3, ws: 2)], shown: [1])
        XCTAssertEqual(f.map(\.id), [3, 5])
    }

    // MARK: BaneySpaces full screen, the routes

    func testTheModeIsReadFromASetting() {
        XCTAssertEqual(FullScreenMode.default, .baneyspaces)
        XCTAssertEqual(FullScreenMode(setting: " Native "), .native)
        XCTAssertEqual(FullScreenMode(setting: "baneyspaces"), .baneyspaces)
        XCTAssertNil(FullScreenMode(setting: "maximize"))
        XCTAssertNil(FullScreenMode(setting: nil))
        XCTAssertEqual(FullScreenMode.usage, "baneyspaces|native")
    }

    func testTheKeyIsControlCommandFAndNothingElse() {
        let both = FullScreenRoute.Modifiers(control: true, command: true)
        XCTAssertTrue(FullScreenRoute.isFullScreenKey(code: 3, both))
        XCTAssertFalse(FullScreenRoute.isFullScreenKey(code: 3, .init(command: true)))
        XCTAssertFalse(FullScreenRoute.isFullScreenKey(code: 3, .init(control: true, command: true, shift: true)))
        XCTAssertFalse(FullScreenRoute.isFullScreenKey(code: 3, .init(control: true, command: true, option: true)))
        XCTAssertFalse(FullScreenRoute.isFullScreenKey(code: 4, both))
    }

    func testTheKeyFillsUnlessMacOSIsToHandleIt() {
        XCTAssertEqual(FullScreenRoute.key(mode: .baneyspaces, windowInNativeFullScreen: false), .fill)
        XCTAssertEqual(FullScreenRoute.key(mode: .native, windowInNativeFullScreen: false), .passThrough)
        XCTAssertEqual(FullScreenRoute.key(mode: .baneyspaces, windowInNativeFullScreen: true), .passThrough, "macOS leaves its own full screen")
    }

    func testTheGreenButton() {
        let plain = FullScreenRoute.Modifiers()
        XCTAssertEqual(FullScreenRoute.click(mode: .baneyspaces, plain, windowInNativeFullScreen: false), .fill)
        XCTAssertEqual(FullScreenRoute.click(mode: .baneyspaces, .init(option: true), windowInNativeFullScreen: false), .native,
                       "an Option-click keeps macOS full screen")
        XCTAssertEqual(FullScreenRoute.click(mode: .native, plain, windowInNativeFullScreen: false), .passThrough)
        XCTAssertEqual(FullScreenRoute.click(mode: .native, .init(option: true), windowInNativeFullScreen: false), .passThrough)
        XCTAssertEqual(FullScreenRoute.click(mode: .baneyspaces, plain, windowInNativeFullScreen: true), .passThrough)
        XCTAssertEqual(FullScreenRoute.click(mode: .baneyspaces, .init(shift: true), windowInNativeFullScreen: false), .passThrough)
        XCTAssertEqual(FullScreenRoute.click(mode: .baneyspaces, .init(command: true), windowInNativeFullScreen: false), .passThrough)
    }

    // MARK: Filled windows

    private let screens = [CGRect(x: 0, y: 0, width: 1512, height: 982)]
    private let area = CGRect(x: 0, y: 38, width: 1512, height: 944)
    private let small = CGRect(x: 200, y: 150, width: 800, height: 600)

    func testFillThenRestore() {
        var f = FilledWindows()
        XCTAssertEqual(f.toggle(7, current: small, area: area, screens: screens), .fill(from: small, to: area))
        XCTAssertTrue(f.isFilled(7))
        XCTAssertEqual(f.toggle(7, current: area, area: area, screens: screens), .restore(to: small), "the same key puts it back")
        XCTAssertFalse(f.isFilled(7))
    }

    /// A terminal snaps to its cell grid, so the frame it takes is a few points short.
    func testRestoreAfterAnAppSnappedTheFill() {
        var f = FilledWindows()
        _ = f.toggle(7, current: small, area: area, screens: screens)
        let snapped = CGRect(x: 0, y: 38, width: 1500, height: 931)
        f.settled(7, actual: snapped)
        XCTAssertEqual(f.toggle(7, current: snapped, area: area, screens: screens), .restore(to: small))
    }

    func testAResizedFilledWindowIsFilledAgain() {
        var f = FilledWindows()
        _ = f.toggle(7, current: small, area: area, screens: screens)
        let dragged = CGRect(x: 100, y: 100, width: 900, height: 700)
        XCTAssertEqual(f.toggle(7, current: dragged, area: area, screens: screens), .fill(from: dragged, to: area))
        XCTAssertEqual(f.toggle(7, current: area, area: area, screens: screens), .restore(to: dragged))
    }

    func testAWindowThatAlreadyFillsShrinksToTheMiddle() {
        var f = FilledWindows()
        guard case let .restore(to: r) = f.toggle(7, current: area, area: area, screens: screens) else { return XCTFail("expected a restore") }
        XCTAssertEqual(r.width, area.width * 0.75, accuracy: 1)
        XCTAssertTrue(area.contains(r))
        XCTAssertFalse(f.isFilled(7))
    }

    func testTheRestoredFrameIsOnAScreen() {
        var f = FilledWindows()
        let gone = CGRect(x: 4000, y: 0, width: 800, height: 600)   // a display that is not there any more
        _ = f.toggle(7, current: gone, area: area, screens: screens)
        guard case let .restore(to: r) = f.toggle(7, current: area, area: area, screens: screens) else { return XCTFail("expected a restore") }
        XCTAssertTrue(Geometry.visibleFraction(r, screens: screens) >= 0.5)
    }

    func testADisplayChangeRefitsAFilledWindowOnly() {
        var f = FilledWindows()
        _ = f.toggle(7, current: small, area: area, screens: screens)
        let bigger = CGRect(x: 0, y: 38, width: 1920, height: 1042)
        XCTAssertEqual(f.refit(7, current: area, area: bigger), bigger)
        XCTAssertNil(f.refit(7, current: bigger, area: bigger), "already fits")
        XCTAssertNil(f.refit(8, current: small, area: bigger), "not filled")
        XCTAssertNil(f.refit(7, current: small, area: CGRect(x: 0, y: 0, width: 640, height: 480)), "resized by hand since")
    }

    func testClosedWindowsAreForgotten() {
        var f = FilledWindows()
        _ = f.toggle(7, current: small, area: area, screens: screens)
        _ = f.toggle(8, current: small, area: area, screens: screens)
        f.keep(alive: [8])
        XCTAssertEqual(f.entries.keys.sorted(), [8])
    }

    func testFilledWindowsSurviveARestart() throws {
        var f = FilledWindows()
        _ = f.toggle(7, current: small, area: area, screens: screens)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bs-filled-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        f.save(to: url)
        XCTAssertEqual(FilledWindows.load(from: url), f)
        XCTAssertEqual(FilledWindows.load(from: url.appendingPathExtension("missing")), FilledWindows())
    }

    // MARK: Migration and desktop slides

    private func fsSpace(_ w: WindowID, current: Bool = false) -> FullScreenSpace {
        FullScreenSpace(space: Int(w) + 1000, display: "A", window: w, pid: 1, isCurrent: current)
    }

    /// Word, Helium and Obsidian, all in native full screen: the one on the desktop in front is asked
    /// where it is; the other two are visited, one at a time.
    func testMigrationVisitsTheDesktopsAccessibilityCannotSee() {
        let p = FullScreenMigration.plan(mode: .baneyspaces, desktops: [fsSpace(1), fsSpace(2, current: true), fsSpace(3)], listed: [2, 9])
        XCTAssertEqual(p.now, [2])
        XCTAssertEqual(p.visit.map(\.window), [1, 3])
    }

    func testNativeModeMigratesNothing() {
        let p = FullScreenMigration.plan(mode: .native, desktops: [fsSpace(1, current: true)], listed: [1])
        XCTAssertEqual(p, FullScreenMigration.Plan(now: [], visit: []))
    }

    func testNoFullScreenDesktopMeansNothingToMigrate() {
        XCTAssertEqual(FullScreenMigration.plan(mode: .baneyspaces, desktops: [], listed: [1]).now, [])
    }

    func testNothingIsAskedWhileMacOSSlidesBetweenDesktops() {
        var t = SpaceTransition()
        let t0 = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(t.wait(now: t0), 0, "nothing in flight")
        t.changed(at: t0)
        XCTAssertEqual(t.wait(now: t0.addingTimeInterval(0.2)), 0.8, accuracy: 0.001)
        XCTAssertEqual(t.wait(now: t0.addingTimeInterval(1.01)), 0)
        t.changed(at: t0.addingTimeInterval(0.9))
        XCTAssertGreaterThan(t.wait(now: t0.addingTimeInterval(1.5)), 0.3, "a second change extends it")
    }
}
