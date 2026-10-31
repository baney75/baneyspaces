import XCTest
@testable import BaneySpacesCore

/// The dock stayed up with the pointer resting 25 to 50 pt above or beside the bar, over the app
/// underneath, and went down only once the pointer moved far off (Donovan, three recordings,
/// 2026-10-31). The zone that keeps it up came from the panel, which is bigger than the bar: it
/// keeps a row for the hover label above a bottom dock and is at least 480 pt long. Geometry here
/// is the one in those recordings: a 210 pt bar in a 480 × 120 panel on a 1512 × 982 screen.
final class DockKeepZoneTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let panel = CGRect(x: 516, y: 6, width: 480, height: 120)
    let bar = CGRect(x: 651, y: 6, width: 210, height: 84)

    func testThePanelZoneHeldTheDockWherePointerRestedInTheRecordings() {
        // What the old code did, kept so the failure stays explained.
        let old = DockEdge.bottom.keepZone(dock: panel, screen: screen)
        XCTAssertTrue(old.contains(CGPoint(x: 756, y: 135)), "45 pt above the bar")
        XCTAssertTrue(old.contains(CGPoint(x: 906, y: 50)), "45 pt beside the bar")
    }

    func testTheDockLetsGoOnceThePointerIsOffTheBar() {
        let zone = DockEdge.bottom.keepZone(bar: bar, panel: panel, sideOpen: false, screen: screen)
        XCTAssertFalse(zone.contains(CGPoint(x: 756, y: 135)), "45 pt above the bar is the app underneath")
        XCTAssertFalse(zone.contains(CGPoint(x: 906, y: 50)), "45 pt beside the bar is the app underneath")
        XCTAssertFalse(zone.contains(CGPoint(x: 756, y: 110)), "past the slack above the bar")
    }

    func testThePointerOnTheBarOrBelowItKeepsTheDock() {
        let zone = DockEdge.bottom.keepZone(bar: bar, panel: panel, sideOpen: false, screen: screen)
        XCTAssertTrue(zone.contains(CGPoint(x: 756, y: 50)), "on a tile")
        XCTAssertTrue(zone.contains(CGPoint(x: 756, y: 0)), "on the edge below it, where it came from")
        XCTAssertTrue(zone.contains(CGPoint(x: 756, y: 100)), "within the slack just above it")
        XCTAssertTrue(zone.contains(CGPoint(x: 870, y: 50)), "within the slack just beside it")
    }

    /// Review of #91: the stretch of edge that brings the dock up was still sized from the panel,
    /// so resting on the edge 120-260 pt from the middle brought it up and dropped it 0.4 s later
    /// with the pointer still. Every edge point that brings it up must keep it up.
    func testTheEdgeThatBringsTheDockUpKeepsItUp() {
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 949)
        for edge in DockEdge.allCases {
            let b = edge.frame(size: edge.isVertical ? CGSize(width: 84, height: 210) : CGSize(width: 210, height: 84),
                               screen: screen, visible: visible)
            let length = edge.isVertical ? b.height : b.width
            let zone = edge.keepZone(bar: b, panel: b.insetBy(dx: -135, dy: -135), sideOpen: false, screen: screen)
            var opened = 0
            for i in 0..<Int(edge.isVertical ? screen.height : screen.width) {
                let t = CGFloat(i) + 0.5
                let p: CGPoint
                switch edge {
                case .bottom: p = CGPoint(x: t, y: 0.5)
                case .top: p = CGPoint(x: t, y: screen.maxY - 0.5)
                case .left: p = CGPoint(x: 0.5, y: t)
                case .right: p = CGPoint(x: screen.maxX - 0.5, y: t)
                }
                guard edge.withinSpan(p, screen: screen, visible: visible, length: length, slack: DockEdge.barSlack) else { continue }
                opened += 1
                XCTAssertTrue(zone.contains(p), "\(edge): \(p) brings the dock up but doesn't keep it up")
            }
            XCTAssertGreaterThan(opened, Int(length), "\(edge): the whole bar's stretch of edge brings it up")
        }
    }

    func testAnOpenWindowStripCountsTheWholePanel() {
        // The strip sits above the bar and takes clicks; reaching for it must not drop the dock.
        let zone = DockEdge.bottom.keepZone(bar: bar, panel: panel, sideOpen: true, screen: screen)
        XCTAssertTrue(zone.contains(CGPoint(x: 756, y: 120)))
    }

    func testBeforeTheBarIsMeasuredThePanelStandsIn() {
        XCTAssertEqual(DockEdge.bottom.keepZone(bar: nil, panel: panel, sideOpen: false, screen: screen),
                       DockEdge.bottom.keepZone(dock: panel, screen: screen))
    }

    func testEveryEdgeHugsItsBar() {
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 949)
        for edge in DockEdge.allCases {
            let size = edge.isVertical ? CGSize(width: 120, height: 480) : CGSize(width: 480, height: 120)
            let p = edge.frame(size: size, screen: screen, visible: visible)
            let b = edge.frame(size: edge.isVertical ? CGSize(width: 84, height: 210) : CGSize(width: 210, height: 84),
                               screen: screen, visible: visible)
            let zone = edge.keepZone(bar: b, panel: p, sideOpen: false, screen: screen)
            XCTAssertTrue(zone.contains(CGPoint(x: b.midX, y: b.midY)), "\(edge) keeps the pointer on its bar")
            // 45 pt past the bar's far end, still inside the panel.
            let past = edge.isVertical ? CGPoint(x: b.midX, y: b.maxY + 45) : CGPoint(x: b.maxX + 45, y: b.midY)
            XCTAssertTrue(edge.keepZone(dock: p, screen: screen).contains(past), "\(edge): the panel reaches there")
            XCTAssertFalse(zone.contains(past), "\(edge) lets go 45 pt past the bar")
        }
    }

    /// The bar's frame comes from SwiftUI in the dock's space; on screen it must land where the
    /// pointer conversion the drag code uses says it is.
    func testScreenRectIsTheInverseOfThePointerConversion() {
        let origin = CGPoint(x: 16, y: 40)
        let inDock = CGRect(x: 119, y: 32, width: 210, height: 84)
        let r = DockEdge.screenRect(inDock, panel: panel, origin: origin)
        for corner in [CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.minY)] {
            let back = DockCarry.point(corner, panel: panel, origin: origin)
            XCTAssertTrue(abs(back.x - (corner.x == r.minX ? inDock.minX : inDock.maxX)) < 0.001)
            XCTAssertTrue(abs(back.y - (corner.y == r.maxY ? inDock.minY : inDock.maxY)) < 0.001)
        }
    }

    /// The tick must use the bar's zone. The app target can't be imported by tests, so this reads
    /// its source, as `DockHoverMotionTests` does.
    func testTheTickUsesTheBarsZone() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BaneySpaces/WorkspaceDock.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
            .split(separator: "\n").map { $0.components(separatedBy: "//")[0] }.joined(separator: "\n")
        XCTAssertTrue(text.contains("input.inKeepZone = edge.keepZone(bar: bar"), "the keep zone hugs the bar")
        XCTAssertTrue(text.contains(".modifier(CenterReport(key: DockView.barKey))"), "the bar reports its frame")
    }
}
