import XCTest
@testable import BaneySpacesCore

final class DockEdgeTests: XCTestCase {
    // A laptop screen with a second screen to its right, bottoms aligned.
    let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let side = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
    let visible = CGRect(x: 0, y: 0, width: 1512, height: 949) // 33 pt menu bar

    func testEachEdgeFindsItsScreen() {
        XCTAssertEqual(DockEdge.bottom.screen(at: CGPoint(x: 700, y: 0), among: [main]), 0)
        XCTAssertEqual(DockEdge.top.screen(at: CGPoint(x: 700, y: 981.5), among: [main]), 0)
        XCTAssertEqual(DockEdge.left.screen(at: CGPoint(x: 0, y: 400), among: [main]), 0)
        XCTAssertEqual(DockEdge.right.screen(at: CGPoint(x: 1511.5, y: 400), among: [main]), 0)
        XCTAssertNil(DockEdge.bottom.screen(at: CGPoint(x: 700, y: 300), among: [main]))
        XCTAssertNil(DockEdge.left.screen(at: CGPoint(x: 700, y: 400), among: [main]))
    }

    func testAnEdgeSharedWithAnotherScreenDoesNotCount() {
        // The main screen's right edge leads onto the side screen.
        XCTAssertNil(DockEdge.right.screen(at: CGPoint(x: 1511.5, y: 400), among: [main, side]))
        // The side screen's right edge is a real edge.
        XCTAssertEqual(DockEdge.right.screen(at: CGPoint(x: 3431.5, y: 400), among: [main, side]), 1)
        // Its left edge isn't.
        XCTAssertNil(DockEdge.left.screen(at: CGPoint(x: 1512, y: 400), among: [main, side]))
        // Above the shorter main screen, the side screen continues: not an edge where it overlaps.
        XCTAssertEqual(DockEdge.top.screen(at: CGPoint(x: 700, y: 981.5), among: [main, side]), 0)
    }

    func testSpanKeepsCornersFree() {
        XCTAssertTrue(DockEdge.bottom.withinSpan(CGPoint(x: 756, y: 0), screen: main, visible: visible, length: 600))
        XCTAssertFalse(DockEdge.bottom.withinSpan(CGPoint(x: 1500, y: 0), screen: main, visible: visible, length: 600))
        XCTAssertTrue(DockEdge.left.withinSpan(CGPoint(x: 0, y: 474), screen: main, visible: visible, length: 500))
        XCTAssertFalse(DockEdge.left.withinSpan(CGPoint(x: 0, y: 940), screen: main, visible: visible, length: 500))
        // The top dock never opens from the Apple menu corner.
        XCTAssertFalse(DockEdge.top.withinSpan(CGPoint(x: 10, y: 981), screen: main, visible: visible, length: 600))
    }

    func testFramesSitInsideTheScreenAndClearOfTheMenuBar() {
        let size = CGSize(width: 600, height: 120)
        for edge in DockEdge.allCases {
            let s = edge.isVertical ? CGSize(width: 120, height: 600) : size
            let f = edge.frame(size: s, screen: main, visible: visible)
            XCTAssertTrue(main.contains(f), "\(edge) dock is on screen")
            XCTAssertLessThanOrEqual(f.maxY, visible.maxY, "\(edge) dock is under the menu bar")
        }
        XCTAssertEqual(DockEdge.bottom.frame(size: size, screen: main, visible: visible).minY, 6)
        XCTAssertEqual(DockEdge.top.frame(size: size, screen: main, visible: visible).maxY, visible.maxY - 6)
        XCTAssertEqual(DockEdge.right.frame(size: CGSize(width: 120, height: 600), screen: main, visible: visible).maxX, main.maxX - 6)
    }

    func testTopWaitsLongerAndEveryEdgeSlidesTowardItself() {
        XCTAssertGreaterThan(DockEdge.top.dwell, DockEdge.bottom.dwell)
        XCTAssertLessThan(DockEdge.bottom.away.dy, 0)
        XCTAssertGreaterThan(DockEdge.top.away.dy, 0)
        XCTAssertLessThan(DockEdge.left.away.dx, 0)
        XCTAssertGreaterThan(DockEdge.right.away.dx, 0)
    }
}
