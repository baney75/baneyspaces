import XCTest
@testable import BaneySpacesCore

final class DockCarryTests: XCTestCase {
    func testOnlyABottomDockTakesAWindow() {
        // The top is the overview's; at the sides macOS tiles the window for the same drag.
        XCTAssertTrue(DockCarry.accepts(.bottom))
        for e in [DockEdge.top, .left, .right] { XCTAssertFalse(DockCarry.accepts(e)) }
    }

    func testThePointerLandsOnTheTileUnderIt() {
        // A bottom dock 600 wide and 120 tall, 6 points up from a 1512-wide screen's bottom; its
        // stack starts 16 in from the left and 0 down from the panel's top.
        let panel = CGRect(x: 456, y: 6, width: 600, height: 120)
        let origin = CGPoint(x: 16, y: 0)
        let tiles: [Int: CGRect] = [1: CGRect(x: 10, y: 40, width: 120, height: 70),
                                    2: CGRect(x: 138, y: 40, width: 120, height: 70)]
        // On screen: x = 456 + 16 + 200, y = 126 - 75 (75 down from the panel's top).
        let p = DockCarry.point(CGPoint(x: 672, y: 51), panel: panel, origin: origin)
        XCTAssertEqual(p, CGPoint(x: 200, y: 75))
        XCTAssertEqual(DockDrop.target(at: p, from: 1, tiles: tiles), 2)
        // Its own workspace takes nothing.
        XCTAssertNil(DockDrop.target(at: p, from: 2, tiles: tiles))
        // Above the dock, over the screen: no tile.
        XCTAssertNil(DockDrop.target(at: DockCarry.point(CGPoint(x: 672, y: 400), panel: panel, origin: origin), from: 1, tiles: tiles))
    }
}
