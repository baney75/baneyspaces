import XCTest
@testable import BaneySpacesCore

final class TopDragTests: XCTestCase {
    // Window-server space: a laptop screen, and a narrower monitor stacked above its left side.
    let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let above = CGRect(x: 0, y: -800, width: 1000, height: 800)
    let window = TopDrag.Grab(window: 7, frame: CGRect(x: 300, y: 200, width: 800, height: 600))

    /// Presses on the window, then drags it so its title bar follows the pointer up to `to`.
    private func drag(_ d: inout TopDrag, to y: CGFloat, at t: TimeInterval, screens: [CGRect]? = nil) -> TopDrag.Grab? {
        let moved = window.frame.offsetBy(dx: 40, dy: max(y - 210, -200))
        return d.tick(cursor: CGPoint(x: 700, y: y), frame: moved, screens: screens ?? [main], now: t)
    }

    func testRestingAtTheTopOpensOnceAfterTheDwell() {
        var d = TopDrag()
        d.press(window)
        XCTAssertNil(drag(&d, to: 400, at: 0))
        XCTAssertNil(drag(&d, to: 1, at: 0.5))
        XCTAssertNil(drag(&d, to: 0, at: 0.5 + TopDrag.dwell - 0.01))
        XCTAssertEqual(drag(&d, to: 0, at: 0.5 + TopDrag.dwell), window)
        // Once per drag.
        XCTAssertNil(drag(&d, to: 0, at: 2))
        XCTAssertTrue(d.fired)
    }

    func testRearmedItOpensOnTheNextTickStillAtTheTop() {
        var d = TopDrag()
        d.press(window)
        XCTAssertNil(drag(&d, to: 0, at: 0.5))
        XCTAssertNotNil(drag(&d, to: 0, at: 0.5 + TopDrag.dwell))
        d.rearm()
        XCTAssertEqual(drag(&d, to: 0, at: 1), window)
    }

    func testPassingThroughTheTopDoesNotOpen() {
        var d = TopDrag()
        d.press(window)
        XCTAssertNil(drag(&d, to: 1, at: 0))
        XCTAssertNil(drag(&d, to: 300, at: 0.2))
        // Back at the top, the wait starts over.
        XCTAssertNil(drag(&d, to: 1, at: 0.5))
        XCTAssertNil(drag(&d, to: 1, at: 0.5 + TopDrag.dwell - 0.01))
        XCTAssertNotNil(drag(&d, to: 1, at: 0.5 + TopDrag.dwell))
    }

    func testAWindowThatDidNotMoveNeverOpensIt() {
        // Selecting text, or a click that wanders to the top: the window stays put.
        var d = TopDrag()
        d.press(window)
        for t in stride(from: 0.0, through: 1.0, by: 0.05) {
            XCTAssertNil(d.tick(cursor: CGPoint(x: 700, y: 0), frame: window.frame, screens: [main], now: t))
        }
    }

    func testAResizeNeverOpensIt() {
        // Dragging the top edge up, pressed on the edge itself: the origin moves, and so does the size.
        var d = TopDrag()
        d.press(TopDrag.Grab(window: window.window, frame: window.frame, press: CGPoint(x: 700, y: 201)))
        for t in stride(from: 0.0, through: 1.0, by: 0.05) {
            let grown = CGRect(x: 300, y: 30, width: 800, height: 770)
            XCTAssertNil(d.tick(cursor: CGPoint(x: 700, y: 0), frame: grown, screens: [main], now: t))
        }
        XCTAssertFalse(d.moving)
    }

    func testATiledWindowThatShrinksAsTheDragStartsStillCounts() {
        // macOS gives a tiled window its old size back on the first move, then it follows.
        var d = TopDrag()
        d.press(window)
        let small = CGSize(width: 600, height: 400)
        XCTAssertNil(d.tick(cursor: CGPoint(x: 700, y: 180), frame: CGRect(origin: CGPoint(x: 400, y: 170), size: small), screens: [main], now: 0))
        XCTAssertNil(d.tick(cursor: CGPoint(x: 700, y: 60), frame: CGRect(origin: CGPoint(x: 400, y: 50), size: small), screens: [main], now: 0.1))
        XCTAssertTrue(d.moving)
        XCTAssertNil(d.tick(cursor: CGPoint(x: 700, y: 0), frame: CGRect(origin: CGPoint(x: 400, y: 33), size: small), screens: [main], now: 0.5))
        XCTAssertNotNil(d.tick(cursor: CGPoint(x: 700, y: 0), frame: CGRect(origin: CGPoint(x: 400, y: 33), size: small), screens: [main], now: 0.5 + TopDrag.dwell))
    }

    func testAWindowAlreadyAgainstTheMenuBarCountsWhenPushedUp() {
        // A full-height window under a 33 pt menu bar can't go any higher: the pointer does.
        let tall = TopDrag.Grab(window: 8, frame: CGRect(x: 0, y: 33, width: 1512, height: 949), press: CGPoint(x: 700, y: 45))
        var d = TopDrag()
        d.press(tall)
        XCTAssertNil(d.tick(cursor: CGPoint(x: 700, y: 20), frame: tall.frame, screens: [main], now: 0.5))
        XCTAssertTrue(d.pinned)
        XCTAssertNil(d.tick(cursor: CGPoint(x: 700, y: 0), frame: tall.frame, screens: [main], now: 0.6))
        XCTAssertEqual(d.tick(cursor: CGPoint(x: 700, y: 0), frame: tall.frame, screens: [main], now: 0.6 + TopDrag.dwell), tall)
    }

    func testAWindowWhoseTopIsTheScreenEdgeCountsWhenPushedUp() {
        // The menu bar hides itself: the window's top is the screen's top, and so is the pointer.
        let tall = TopDrag.Grab(window: 9, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), press: CGPoint(x: 700, y: 12))
        var d = TopDrag()
        d.press(tall)
        XCTAssertNil(d.tick(cursor: CGPoint(x: 700, y: 0), frame: tall.frame, screens: [main], now: 0.5))
        XCTAssertTrue(d.pinned)
        XCTAssertEqual(d.tick(cursor: CGPoint(x: 700, y: 0), frame: tall.frame, screens: [main], now: 0.5 + TopDrag.dwell), tall)
    }

    func testATiledWindowThatShrinksAgainstTheMenuBarCountsWhenPushedUp() {
        // Tiled to the top half, it gets its old size back on the press and stays put up there.
        let tiled = TopDrag.Grab(window: 10, frame: CGRect(x: 0, y: 33, width: 1512, height: 475), press: CGPoint(x: 700, y: 45))
        let shrunk = CGRect(x: 400, y: 33, width: 700, height: 500)
        var d = TopDrag()
        d.press(tiled)
        XCTAssertNil(d.tick(cursor: CGPoint(x: 700, y: 20), frame: shrunk, screens: [main], now: 0.4))
        XCTAssertNil(d.tick(cursor: CGPoint(x: 700, y: 0), frame: shrunk, screens: [main], now: 0.5))
        XCTAssertTrue(d.pinned)
        XCTAssertEqual(d.tick(cursor: CGPoint(x: 700, y: 0), frame: shrunk, screens: [main], now: 0.5 + TopDrag.dwell), tiled)
    }

    func testAPressBelowTheTitleBarOfAWindowAtTheTopNeverCounts() {
        // Selecting text from the middle of a full-height window up into the menu bar.
        let tall = TopDrag.Grab(window: 8, frame: CGRect(x: 0, y: 33, width: 1512, height: 949), press: CGPoint(x: 700, y: 400))
        var d = TopDrag()
        d.press(tall)
        for t in stride(from: 0.0, through: 1.0, by: 0.05) {
            XCTAssertNil(d.tick(cursor: CGPoint(x: 700, y: 0), frame: tall.frame, screens: [main], now: t))
        }
    }

    func testAWindowThatClosesMidDragEndsIt() {
        var d = TopDrag()
        d.press(window)
        XCTAssertNil(drag(&d, to: 300, at: 0))
        XCTAssertNil(d.tick(cursor: CGPoint(x: 700, y: 0), frame: nil, screens: [main], now: 0.1))
        XCTAssertNil(d.grab)
        XCTAssertNil(drag(&d, to: 0, at: 1))
    }

    func testNoPressOnAWindowNeverOpens() {
        var d = TopDrag()
        d.press(nil)
        XCTAssertNil(d.tick(cursor: CGPoint(x: 700, y: 0), frame: window.frame, screens: [main], now: 1))
    }

    func testReleaseForgetsTheDrag() {
        var d = TopDrag()
        d.press(window)
        XCTAssertNil(drag(&d, to: 0, at: 0))
        d.release()
        XCTAssertNil(drag(&d, to: 0, at: 1))
    }

    func testAnEdgeLeadingOntoAScreenAboveIsNotTheTop() {
        // The laptop's top edge leads onto the monitor above it.
        XCTAssertFalse(TopDrag.atTop(CGPoint(x: 700, y: 0), screens: [main, above]))
        // Past the monitor's right side, the laptop's edge is a real edge.
        XCTAssertTrue(TopDrag.atTop(CGPoint(x: 1300, y: 0), screens: [main, above]))
        XCTAssertTrue(TopDrag.atTop(CGPoint(x: 700, y: -800), screens: [main, above]))
        XCTAssertTrue(TopDrag.atTop(CGPoint(x: 700, y: 2), screens: [main]))
        XCTAssertFalse(TopDrag.atTop(CGPoint(x: 700, y: 3), screens: [main]))
        XCTAssertFalse(TopDrag.atTop(CGPoint(x: 700, y: -5), screens: [main]))
    }

    /// A window dragged to the top and let go there fills the screen, as macOS does it
    /// (Donovan, 2026-10-28): BaneySpaces may turn off Mission Control for that drag, never
    /// fill-the-screen. `SystemTopDrag` lives in the app target, so this reads the source.
    func testTheDragToTheTopLeavesFillTheScreenOn() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BaneySpaces/TopDragWatcher.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
            .split(separator: "\n").map { $0.components(separatedBy: "//")[0] }.joined(separator: "\n")
        let taken = try XCTUnwrap(text.range(of: "private static let settings = [").map { text[$0.upperBound...] }
            .flatMap { rest in rest.range(of: "]").map { rest[..<$0.lowerBound] } })
        XCTAssertTrue(taken.contains("enterMissionControlByTopWindowDrag"), String(taken))
        XCTAssertFalse(taken.contains("EnableTopTilingByEdgeDrag"), "fill-the-screen must stay macOS's")
    }

    /// Fill-the-screen comes back on where an older build turned it off, unless it was off
    /// before BaneySpaces; on a Mac BaneySpaces never took over, or with it on, nothing changes.
    func testFillTheScreenComesBackOnOnlyWhereBaneySpacesTookIt() {
        XCTAssertTrue(FillTheScreen.turnBackOn(taken: true, saved: nil, now: false), "saved as absent: macOS's default, on")
        XCTAssertTrue(FillTheScreen.turnBackOn(taken: true, saved: true, now: false))
        XCTAssertFalse(FillTheScreen.turnBackOn(taken: true, saved: false, now: false), "off before BaneySpaces stays off")
        XCTAssertFalse(FillTheScreen.turnBackOn(taken: true, saved: nil, now: true), "already on")
        XCTAssertFalse(FillTheScreen.turnBackOn(taken: true, saved: nil, now: nil), "not set is on")
        XCTAssertFalse(FillTheScreen.turnBackOn(taken: false, saved: nil, now: false), "never taken: the person's own off")
    }

    private func decide(record: Bool = true, pending: Bool = false, saved: Bool? = nil, now: Bool? = false,
                        tries: Int = 0, triedThisLaunch: Bool = false, readBack: Bool = false) -> FillTheScreen.Decision {
        FillTheScreen.decide(record: record, pending: pending, saved: saved, now: now,
                             tries: tries, triedThisLaunch: triedThisLaunch, readBack: readBack).decision
    }

    /// Three launches that each fail to turn it on spend the three tries; the third gives up.
    func testFillTheScreenGivesUpOnTheThirdLaunchThatFails() {
        XCTAssertEqual(decide(tries: 0), .retry(tries: 1))
        XCTAssertEqual(decide(record: false, pending: true, tries: 1), .retry(tries: 2))
        XCTAssertEqual(decide(record: false, pending: true, tries: 2), .giveUp)
    }

    /// A try that reads back ends it at any count.
    func testFillTheScreenSettlesOnceItReadsBack() {
        XCTAssertEqual(decide(tries: 0, readBack: true), .settled)
        XCTAssertEqual(decide(record: false, pending: true, tries: 2, readBack: true), .settled)
    }

    /// First-F1: a hiccup plus toggling the switch calls it again in the same launch. That
    /// isn't another try, however many times it runs.
    func testFillTheScreenCountsOneTryPerLaunch() {
        XCTAssertEqual(decide(tries: 1, triedThisLaunch: true), .retry(tries: 1))
        XCTAssertEqual(decide(tries: 2, triedThisLaunch: true), .retry(tries: 2), "the third try needs a new launch")
        XCTAssertEqual(decide(tries: 2, triedThisLaunch: true, readBack: true), .settled, "but reading back still settles")
    }

    /// First-F2: the pending flag alone keeps it owed once `restore()` drops the record.
    func testFillTheScreenPendingWithoutARecordIsStillOwed() {
        XCTAssertEqual(decide(record: false, pending: true, tries: 1), .retry(tries: 2))
        XCTAssertEqual(decide(record: false, pending: false, tries: 0), .settled, "no record, not pending: never ours")
    }

    /// First-F2: the record dropped by `restore()`, with nothing left saying it was off before,
    /// still gets its tries; one saying it was off before never does.
    func testFillTheScreenSurvivesTheRecordBeingDropped() {
        XCTAssertEqual(decide(record: false, pending: true, saved: nil, tries: 0), .retry(tries: 1))
        XCTAssertEqual(decide(record: true, pending: true, saved: false, tries: 1), .settled, "off before BaneySpaces")
    }

    /// Second-S1 / first-F1: giving up is its own record, apart from giving back, so the
    /// uninstaller still writes once more. Checks the Core mapping from decision to flag, and that
    /// uninstall.sh names both keys; not what uninstall.sh does with them.
    func testGiveUpAndGivenBackFlagsAreDistinctAndBothNamedInUninstallSh() throws {
        XCTAssertEqual(FillTheScreen.Decision.settled.flagKey, "systemTopDragFillGivenBack")
        XCTAssertEqual(FillTheScreen.Decision.giveUp.flagKey, "systemTopDragFillGaveUp")
        XCTAssertNil(FillTheScreen.Decision.retry(tries: 1).flagKey, "a retry sets no flag")
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("uninstall.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(text.contains(FillTheScreen.gaveUpKey) && text.contains(FillTheScreen.givenBackKey), "uninstall.sh reads both flags")
    }

    /// Second-F4: two calls in one launch, the way a hiccup plus toggling the switch makes them.
    /// The first spends a try, the second doesn't, and the flag comes from the pure layer.
    func testTheLaunchFlagComesBackFromTheStep() {
        func call(tries: Int, tried: Bool, readBack: Bool = false) -> FillTheScreen.Step {
            FillTheScreen.decide(record: true, pending: tries > 0, saved: nil, now: false,
                                 tries: tries, triedThisLaunch: tried, readBack: readBack)
        }
        let first = call(tries: 1, tried: false)
        XCTAssertEqual(first, FillTheScreen.Step(decision: .retry(tries: 2), triedThisLaunch: true))
        let second = call(tries: 2, tried: first.triedThisLaunch)
        XCTAssertEqual(second, FillTheScreen.Step(decision: .retry(tries: 2), triedThisLaunch: true), "no second try in the launch")
        let nothingDue = FillTheScreen.decide(record: false, pending: false, saved: nil, now: false,
                                              tries: 0, triedThisLaunch: false, readBack: false)
        XCTAssertFalse(nothingDue.triedThisLaunch, "a call with nothing due is not a try")
    }
}
