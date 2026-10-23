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
        // Dragging the top edge up: the origin moves, and so does the size.
        var d = TopDrag()
        d.press(window)
        for t in stride(from: 0.0, through: 1.0, by: 0.05) {
            let grown = CGRect(x: 300, y: 30, width: 800, height: 770)
            XCTAssertNil(d.tick(cursor: CGPoint(x: 700, y: 0), frame: grown, screens: [main], now: t))
        }
        XCTAssertFalse(d.moving)
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
