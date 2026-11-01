import XCTest
@testable import BaneySpacesCore

/// Donovan, 2026-10-31 (23:31 recording): the dock and its "+N" list popped in and out, the dock panel
/// jumped when the list opened, and the list once drew clipped. The view code lives in the app
/// target, which tests can't import, so what can't be run is read from the source.
final class DockMotionTests: XCTestCase {
    private func dock() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BaneySpaces/WorkspaceDock.swift")
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").map { $0.components(separatedBy: "//")[0] }.joined(separator: "\n")
    }

    func testTheListAndStripAreAPanelOfTheirOwnNotPartOfTheDocksStack() throws {
        let text = try dock()
        let bar = try XCTUnwrap(text.range(of: "private var barBody: some View"))
        let end = try XCTUnwrap(text.range(of: "private var barScale: CGFloat"))
        let body = String(text[bar.lowerBound..<end.lowerBound])
        XCTAssertFalse(body.contains("moreList("), "the dock's own stack no longer holds the list")
        XCTAssertFalse(body.contains("windowStrip("), "...or the strip")
        XCTAssertTrue(text.contains("case .side: sideBody"))
        XCTAssertTrue(text.contains("p.addChildWindow(sp, ordered: .above)"), "a child panel, which follows the dock")
        // Opening or closing the list never sets the dock panel's frame: only resize() does, from its own size.
        let sync = try XCTUnwrap(text.range(of: "func syncSide()"))
        let close = try XCTUnwrap(text.range(of: "private func closeSidePanel()"))
        let syncBody = String(text[sync.lowerBound..<close.lowerBound])
        let dockSetFrame = try NSRegularExpression(pattern: #"(?<![A-Za-z])p\.setFrame\("#)
        XCTAssertEqual(dockSetFrame.numberOfMatches(in: syncBody, range: NSRange(syncBody.startIndex..., in: syncBody)), 0,
                       "syncSide moves the side panel (sp), never the dock's (p)")
        XCTAssertTrue(syncBody.contains("sp.setFrame(frame"))
    }

    func testTheKeepZoneUsesTheListsOwnFrameNotTheWholePanel() throws {
        let text = try dock()
        XCTAssertTrue(text.contains("edge.keeps(mouse, bar: bar, panel: p.frame, side: side, screen: screenFrame) || unmoved"))
        XCTAssertFalse(text.contains("sideOpen"), "no flag that turns the whole panel back on")
    }

    func testTheListClosesOnGraceEscAndAClickOutsideAndSaysWhy() throws {
        let text = try dock()
        XCTAssertTrue(text.contains("sideGrace.step(now: now, inside: inside)"))
        XCTAssertTrue(text.contains("closeSideNow(\"pointer left it at"))
        XCTAssertTrue(text.contains("closeSideNow(\"Esc\")"))
        XCTAssertTrue(text.contains("closeSideNow(\"click outside\")"))
        XCTAssertTrue(text.contains("Trace.log(\"dock list closed ("))
        let tick = try XCTUnwrap(text.range(of: "checkSide(now: ProcessInfo"))
        let pinned = try XCTUnwrap(text.range(of: "guard !pinned else { return }"))
        XCTAssertLessThan(tick.lowerBound, pinned.lowerBound, "a pinned dock's list lets go too")
    }

    func testEveryMotionHonorsReduceMotionAndIsScopedToItsOwnView() throws {
        let text = try dock()
        XCTAssertGreaterThanOrEqual(text.components(separatedBy: "educeMotion").count - 1, 8, "the dock, the list, the rows, the lift and the settle each check it")
        XCTAssertTrue(text.contains("guard animated, !reduceMotion else { p.orderOut(nil); return }"), "the dock leaves at once")
        XCTAssertTrue(text.contains("if reduceMotion {\n            \n            p.setFrame(up, display: true)\n            p.alphaValue = 1"), "the dock comes in at once")
        // The only .animation(_, value:) is the row highlight's own fill; everything else is scoped
        // (DockLift/HoverScale's closure form, NSAnimationContext, a layer animation, withAnimation).
        let uses = try NSRegularExpression(pattern: #"\.animation\((?!forKey)"#).numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        let hover = try XCTUnwrap(text.range(of: "private struct RowHighlight: View"))
        let rowHighlight = String(text[hover.lowerBound...].prefix(600))
        XCTAssertTrue(rowHighlight.contains(".animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: DockMotion.rowHover), value: on)"))
        XCTAssertEqual(uses, 4, "RowHighlight, DragLift's two forms, HoverScale: no animation on a parent")
        XCTAssertFalse(text.contains("value: hovered)"))
        XCTAssertTrue(text.contains("DockMotion.listIn") && text.contains("DockMotion.listOut") && text.contains("DockMotion.dockIn"))
    }

    func testTheDockPanelNeverMovesForTheListItsFrameComesFromItsOwnSize() throws {
        let text = try dock()
        let resize = try XCTUnwrap(text.range(of: "private func resize() {"))
        let rest = text[resize.lowerBound...]
        let body = String(rest[..<(rest.range(of: "\n    }\n")!.lowerBound)])
        XCTAssertTrue(body.contains("p.contentView?.fittingSize"), "the dock's size is its own content's")
        XCTAssertFalse(body.contains("sidePanel"), "the list's size never enters it")
    }
}
