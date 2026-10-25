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

    func testOnlyAMenuNearThePointerHoldsTheDockBack() {
        // 2026-10-25: MenuBarAgent's empty window at the menu level, on screen for hours just
        // under the menu bar (window server 844, 33, 367 x 154, flipped).
        let stuck = CGRect(x: 844, y: 795, width: 367, height: 154)
        XCTAssertFalse(DockEdge.menuInTheWay([stuck], pointer: CGPoint(x: 756, y: 0)))
        XCTAssertFalse(DockEdge.menuInTheWay([stuck], pointer: CGPoint(x: 0, y: 474)))
        // A long menu reaching down to the bottom edge, the pointer at its foot.
        let long = CGRect(x: 600, y: 4, width: 260, height: 945)
        XCTAssertTrue(DockEdge.menuInTheWay([stuck, long], pointer: CGPoint(x: 756, y: 0)))
        // A menu bar menu hanging under a pointer resting on the top edge, on its title.
        let dropdown = CGRect(x: 700, y: 649, width: 240, height: 300)
        XCTAssertTrue(DockEdge.menuInTheWay([dropdown], pointer: CGPoint(x: 720, y: 981.5)))
        XCTAssertFalse(DockEdge.menuInTheWay([], pointer: CGPoint(x: 756, y: 0)))
    }

    func testAMenuWindowUpForLongIsNotAMenu() {
        // The same stuck window blocks a top dock while fresh: nearness can't tell it from a menu
        // bar menu. After 30 s on screen it no longer counts, on any edge.
        let stuck = CGRect(x: 844, y: 795, width: 367, height: 154)
        let top = CGPoint(x: 900, y: 981.5)
        var menus = MenuWindows()
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(DockEdge.menuInTheWay(menus.update([(66418, stuck)], now: t0), pointer: top))
        XCTAssertTrue(DockEdge.menuInTheWay(menus.update([(66418, stuck)], now: t0 + 29), pointer: top))
        XCTAssertFalse(DockEdge.menuInTheWay(menus.update([(66418, stuck)], now: t0 + 31), pointer: top))
        // A menu opened now beside it is fresh and counts.
        let dropdown = CGRect(x: 700, y: 649, width: 240, height: 300)
        XCTAssertEqual(menus.update([(66418, stuck), (70000, dropdown)], now: t0 + 32), [dropdown])
        // A window that closes and a new one under the same number starts over.
        menus.update([], now: t0 + 33)
        XCTAssertEqual(menus.update([(66418, stuck)], now: t0 + 34), [stuck])
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

    /// The pointer that brought the dock up is inside the zone that keeps it up, on every edge,
    /// including the top dock, which sits below a menu bar the pointer is resting on.
    func testThePointThatOpensTheDockKeepsItOpen() {
        let notched = CGRect(x: 0, y: 0, width: 1512, height: 905) // 77 pt above it: notch menu bar
        let points: [DockEdge: CGPoint] = [.bottom: CGPoint(x: 756, y: 0), .top: CGPoint(x: 756, y: 981.5),
                                           .left: CGPoint(x: 0, y: 452), .right: CGPoint(x: 1511.5, y: 452)]
        for edge in DockEdge.allCases {
            let size = edge.isVertical ? CGSize(width: 120, height: 600) : CGSize(width: 600, height: 120)
            let dock = edge.frame(size: size, screen: main, visible: notched)
            let p = points[edge]!
            XCTAssertEqual(edge.screen(at: p, among: [main]), 0, "\(edge) trigger")
            XCTAssertTrue(edge.keepZone(dock: dock, screen: main).contains(p), "\(edge) keeps its own trigger point")
            // Well into the screen is outside it.
            XCTAssertFalse(edge.keepZone(dock: dock, screen: main).contains(CGPoint(x: 756, y: 452)) && !dock.contains(CGPoint(x: 756, y: 452)),
                           "\(edge) lets go in the middle of the screen")
        }
    }
}
