import CoreGraphics
import XCTest
@testable import BaneySpacesCore

/// The "+N" list and window strip are a panel of their own (Donovan, 2026-10-31: the dock jumped and
/// drew the list clipped when it opened). Where it goes, when it lets go, and how the dock moves.
final class DockSideTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func bar(_ edge: DockEdge) -> CGRect {
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 949)
        return edge.frame(size: edge.isVertical ? CGSize(width: 84, height: 420) : CGSize(width: 420, height: 84), screen: screen, visible: visible)
    }

    func testTheListSitsOnTheScreenSideOfTheBarWithAGapAndNeverOverlapsIt() {
        let size = CGSize(width: 240, height: 150)
        for edge in DockEdge.allCases {
            let b = bar(edge)
            let anchor = CGRect(x: b.midX - 32, y: b.midY - 32, width: 64, height: 64)
            let f = DockSide.frame(size: size, anchor: anchor, bar: b, edge: edge, screen: screen)
            XCTAssertFalse(f.intersects(b), "\(edge)")
            XCTAssertTrue(screen.contains(f), "\(edge) stays on the screen")
            switch edge {
            case .bottom: XCTAssertEqual(f.minY, b.maxY + DockSide.gap)
            case .top: XCTAssertEqual(f.maxY, b.minY - DockSide.gap)
            case .left: XCTAssertEqual(f.minX, b.maxX + DockSide.gap)
            case .right: XCTAssertEqual(f.maxX, b.minX - DockSide.gap)
            }
        }
    }

    func testTheListCentersOnItsTileButNeverPastEitherEndOfTheBar() {
        let b = bar(.bottom)
        let size = CGSize(width: 240, height: 150)
        let mid = DockSide.frame(size: size, anchor: CGRect(x: b.midX - 32, y: b.minY, width: 64, height: 64), bar: b, edge: .bottom, screen: screen)
        XCTAssertEqual(mid.midX, b.midX, accuracy: 0.5)
        let atLeft = DockSide.frame(size: size, anchor: CGRect(x: b.minX, y: b.minY, width: 64, height: 64), bar: b, edge: .bottom, screen: screen)
        XCTAssertEqual(atLeft.minX, b.minX, accuracy: 0.5, "pinned to the bar's left end")
        let atRight = DockSide.frame(size: size, anchor: CGRect(x: b.maxX - 64, y: b.minY, width: 64, height: 64), bar: b, edge: .bottom, screen: screen)
        XCTAssertEqual(atRight.maxX, b.maxX, accuracy: 0.5)
        let wide = DockSide.frame(size: CGSize(width: 600, height: 150), anchor: CGRect(x: b.minX, y: b.minY, width: 64, height: 64), bar: b, edge: .bottom, screen: screen)
        XCTAssertEqual(wide.midX, b.midX, accuracy: 0.5, "wider than the bar: centered on it")
    }

    func testTheGrowPointIsMeasuredFromTheLayersOwnAnchor() {
        // A layer AppKit makes for a view is anchored at (0, 0); a hosting layer's default is the center.
        let size = CGSize(width: 240, height: 150)
        let grow = CGPoint(x: 132, y: 0)
        XCTAssertEqual(DockSide.growOffset(grow: grow, anchorPoint: CGPoint(x: 0.5, y: 0.5), size: size), CGPoint(x: 12, y: -75))
        XCTAssertEqual(DockSide.growOffset(grow: grow, anchorPoint: .zero, size: size), grow)
        // Scaling about that offset leaves the grow point itself where it is, whichever the anchor.
        for anchor in [CGPoint(x: 0.5, y: 0.5), .zero, CGPoint(x: 0, y: 1)] {
            let about = DockSide.growOffset(grow: grow, anchorPoint: anchor, size: size)
            let t = DockSide.growTransform(about: about, scale: 0.96)
            let anchorPt = CGPoint(x: anchor.x * size.width, y: anchor.y * size.height)
            // The layer transform maps v (from the anchor) to t(v); the grow point's v is `about`.
            let moved = about.applying(t)
            XCTAssertEqual(moved.x + anchorPt.x, grow.x, accuracy: 1e-9)
            XCTAssertEqual(moved.y + anchorPt.y, grow.y, accuracy: 1e-9)
        }
    }

    func testThePointerIsWithTheListOnItsTileAndInTheGapBetween() {
        // The tile sits inside the bar, whose top is the list's gap below it: tile top to list is ~16 pt.
        let list = CGRect(x: 600, y: 100, width: 240, height: 150)
        let tile = CGRect(x: 700, y: 20, width: 64, height: 64)
        XCTAssertTrue(DockSide.pointerWithList(CGPoint(x: 720, y: 200), list: list, anchor: tile))
        XCTAssertTrue(DockSide.pointerWithList(CGPoint(x: 730, y: 50), list: list, anchor: tile), "on its tile")
        XCTAssertTrue(DockSide.pointerWithList(CGPoint(x: 730, y: 92), list: list, anchor: tile), "between tile and list")
        XCTAssertFalse(DockSide.pointerWithList(CGPoint(x: list.maxX + 120, y: 200), list: list, anchor: tile), "120 pt to the right")
        XCTAssertFalse(DockSide.pointerWithList(CGPoint(x: 900, y: 50), list: list, anchor: tile), "on another tile")
    }

    func testTheListLetsGoAfterAQuarterSecondOffItAndNotBefore() {
        var g = DockSideGrace()
        XCTAssertFalse(g.step(now: 10, inside: false))
        XCTAssertFalse(g.step(now: 10.2, inside: false))
        XCTAssertTrue(g.step(now: 10.26, inside: false))
        XCTAssertEqual(DockSideGrace.delay, 0.25)
    }

    func testComingBackOnTheListRestartsTheGrace() {
        var g = DockSideGrace()
        XCTAssertFalse(g.step(now: 10, inside: false))
        XCTAssertFalse(g.step(now: 10.2, inside: true))
        XCTAssertFalse(g.step(now: 10.3, inside: false), "a new absence starts again")
        XCTAssertTrue(g.step(now: 10.56, inside: false))
    }

    func testTheListGrowsFromTheEdgeOfItsPanelFacingItsTile() {
        let panel = CGRect(x: 600, y: 120, width: 240, height: 150)
        let anchor = CGRect(x: 700, y: 20, width: 64, height: 64)
        XCTAssertEqual(DockSide.growPoint(panel: panel, anchor: anchor, edge: .bottom), CGPoint(x: 132, y: 0))
        XCTAssertEqual(DockSide.growPoint(panel: panel, anchor: anchor, edge: .top), CGPoint(x: 132, y: 150))
    }

    func testMotionIsShortAndReduceMotionMakesItInstant() {
        XCTAssertEqual(DockMotion.slide, 8)
        XCTAssertEqual(DockMotion.dockIn, 0.18)
        XCTAssertEqual(DockMotion.listIn, 0.14)
        XCTAssertEqual(DockMotion.listOut, 0.10)
        XCTAssertEqual(DockMotion.rowHover, 0.08)
        XCTAssertEqual(DockMotion.listScale, 0.96)
        XCTAssertEqual(DockMotion.lift, 1.04)
        for d in [DockMotion.dockIn, DockMotion.dockOut, DockMotion.listIn, DockMotion.listOut, DockMotion.rowHover, DockMotion.settle] {
            XCTAssertEqual(DockMotion.duration(d, reduceMotion: true), 0)
            XCTAssertEqual(DockMotion.duration(d, reduceMotion: false), d)
        }
        for edge in DockEdge.allCases { XCTAssertEqual(hypot(edge.away.dx, edge.away.dy), 8, "\(edge) slides 8 pt") }
    }

    func testScalingAboutTheGrowPointLeavesThatPointStill() {
        let p = CGPoint(x: -40, y: -75)
        let t = DockSide.growTransform(about: p, scale: DockMotion.listScale)
        let fixed = p.applying(t)
        XCTAssertEqual(fixed.x, p.x, accuracy: 1e-9)
        XCTAssertEqual(fixed.y, p.y, accuracy: 1e-9)
        let far = CGPoint(x: 120, y: 75).applying(t)
        XCTAssertEqual(far.x, p.x + (120 - p.x) * 0.96, accuracy: 1e-9, "everything else moves toward it")
        XCTAssertEqual(far.y, p.y + (75 - p.y) * 0.96, accuracy: 1e-9)
    }
}
