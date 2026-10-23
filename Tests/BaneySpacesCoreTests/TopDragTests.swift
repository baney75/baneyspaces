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
}
