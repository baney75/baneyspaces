import XCTest
@testable import BaneySpacesCore

final class SidebarVisibilityTests: XCTestCase {
    func testHiddenByDefault() {
        XCTAssertFalse(SidebarVisibility().visible(ghosttyFront: true))
    }

    func testEdgeRestOpensAndLeavingCloses() {
        var v = SidebarVisibility()
        v.handle(.edgeRest)
        XCTAssertTrue(v.visible(ghosttyFront: true))
        v.handle(.pointerLeft)
        XCTAssertFalse(v.visible(ghosttyFront: true))
    }

    func testKeyOpenWaitsForThePointerBeforeLeavingCloses() {
        var v = SidebarVisibility()
        v.handle(.toggleKey)
        v.handle(.pointerLeft)
        XCTAssertTrue(v.visible(ghosttyFront: true), "never entered, so it must not vanish")
        v.handle(.pointerEntered)
        v.handle(.pointerLeft)
        XCTAssertFalse(v.visible(ghosttyFront: true))
    }

    func testToggleKeyClosesAnOpenDrawer() {
        var v = SidebarVisibility()
        v.handle(.toggleKey)
        v.handle(.toggleKey)
        XCTAssertFalse(v.visible(ghosttyFront: true))
    }

    func testPickEscapeAndSwitchingAppsClose() {
        for e in [SidebarVisibility.Event.picked, .escape, .ghosttyInactive] {
            var v = SidebarVisibility()
            v.handle(.edgeRest)
            v.handle(e)
            XCTAssertFalse(v.visible(ghosttyFront: true), "\(e)")
        }
    }

    func testPinnedStaysThroughEverythingButUnpinOrKey() {
        var v = SidebarVisibility(pinned: true)
        for e in [SidebarVisibility.Event.pointerLeft, .picked, .escape, .ghosttyInactive, .edgeRest] { v.handle(e) }
        XCTAssertTrue(v.visible(ghosttyFront: true))
        XCTAssertFalse(v.visible(ghosttyFront: false), "only over Ghostty")
        v.handle(.toggleKey)
        XCTAssertFalse(v.pinned)
        XCTAssertFalse(v.visible(ghosttyFront: true))
    }

    func testUnpinHides() {
        var v = SidebarVisibility()
        v.handle(.edgeRest)
        v.handle(.pin(true))
        v.handle(.pointerLeft)
        XCTAssertTrue(v.visible(ghosttyFront: true))
        v.handle(.pin(false))
        XCTAssertFalse(v.visible(ghosttyFront: true))
    }

    func testThePointerOnTheEdgeThatOpenedItIsStillAtTheSidebar() {
        // A 264-point sidebar 6 points in from the left edge of a laptop screen.
        let sidebar = CGRect(x: 6, y: 6, width: 264, height: 936)
        // Resting on the edge strip, left of the sidebar: it opened the drawer, so it hasn't left.
        XCTAssertTrue(SidebarZone.contains(CGPoint(x: 0, y: 610), sidebar: sidebar, screenMinX: 0))
        XCTAssertTrue(SidebarZone.contains(CGPoint(x: 100, y: 610), sidebar: sidebar, screenMinX: 0))
        XCTAssertTrue(SidebarZone.contains(CGPoint(x: 278, y: 610), sidebar: sidebar, screenMinX: 0))
        XCTAssertFalse(SidebarZone.contains(CGPoint(x: 281, y: 610), sidebar: sidebar, screenMinX: 0))
        // Down the edge past the sidebar's bottom, or on the screen to its left.
        XCTAssertFalse(SidebarZone.contains(CGPoint(x: 0, y: 2), sidebar: sidebar, screenMinX: 0))
        XCTAssertFalse(SidebarZone.contains(CGPoint(x: -1, y: 610), sidebar: sidebar, screenMinX: 0))
        // Beside a 70-point Dock on the left: crossing from the edge to the sidebar never leaves it.
        let besideDock = sidebar.offsetBy(dx: 70, dy: 0)
        for x in stride(from: CGFloat(0), through: 76, by: 4) {
            XCTAssertTrue(SidebarZone.contains(CGPoint(x: x, y: 610), sidebar: besideDock, screenMinX: 0))
        }
    }

    func testTheEdgeStripBackUnderARestingPointerWaitsForItToMoveAway() {
        let strip = CGRect(x: 0, y: 95, width: 2, height: 758)
        var a = EdgeArming()
        a.shown(pointerOnStrip: true)
        XCTAssertFalse(a.armed)
        // A hand drifting off the 2-point strip and back isn't leaving.
        for x in [CGFloat(1), 2, 3, 0, 10, 1] {
            a.sample(CGPoint(x: x, y: 610), strip: strip)
            XCTAssertFalse(a.armed, "drifted to x=\(x)")
        }
        a.sample(CGPoint(x: 40, y: 610), strip: strip)
        XCTAssertTrue(a.armed)
        // Shown with the pointer elsewhere, a rest counts straight away.
        var b = EdgeArming()
        b.shown(pointerOnStrip: false)
        XCTAssertTrue(b.armed)
    }
}
