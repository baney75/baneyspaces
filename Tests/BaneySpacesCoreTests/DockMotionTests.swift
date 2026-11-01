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

    /// F10 of #106: each motion's own site checks Reduce Motion and takes its time from `DockMotion`,
    /// so deleting one check fails here and a comment can't stand in for it.
    func testEachMotionSiteChecksReduceMotionAndUsesTheDurationHelper() throws {
        let text = try dock()
        // Dock in and out; list in and out.
        for name in ["dockIn", "dockOut", "listIn", "listOut"] {
            XCTAssertTrue(text.contains("ctx.duration = DockMotion.duration(DockMotion.\(name), reduceMotion: reduceMotion)"), "\(name)")
        }
        XCTAssertTrue(text.contains("if reduceMotion {\n            \n            p.setFrame(up, display: true)\n            p.alphaValue = 1"), "the dock comes in at once")
        XCTAssertTrue(text.contains("guard animated, !reduceMotion else { dismissSide(); p.orderOut(nil); return }"), "the dock leaves at once")
        XCTAssertTrue(text.contains("sp.alphaValue = reduceMotion ? 1 : 0\n        sp.orderFront(nil)\n        guard !reduceMotion else { return }"), "the list opens at once")
        XCTAssertTrue(text.contains("guard !reduceMotion, isShown else { return finish() }"), "the list closes at once")
        // Row highlight, lift and settle: each reads it in its own view.
        for (marker, check) in [("private struct RowHighlight: View", "accessibilityDisplayShouldReduceMotion ? nil"),
                                ("private struct DragLift: ViewModifier", "accessibilityDisplayShouldReduceMotion ? nil"),
                                ("private struct SettleIcon: View", "reduce ? nil")] {
            let at = try XCTUnwrap(text.range(of: marker), marker)
            XCTAssertTrue(text[at.lowerBound...].prefix(900).contains(check), "\(marker) checks Reduce Motion")
        }
        XCTAssertTrue(text.contains("DockMotion.duration(DockMotion.rowHover"))
        XCTAssertTrue(text.contains("DockMotion.duration(DockMotion.settle"))
        XCTAssertTrue(text.contains("if !reduce { settling = Settling("), "no settle icon under Reduce Motion")
    }

    func testNoAnimationIsOnAParentAndTheDropAnimatesOnlyItsOwnIcon() throws {
        let text = try dock()
        let uses = try NSRegularExpression(pattern: #"\.animation\((?!forKey)"#).numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        XCTAssertEqual(uses, 5, "HoverScale (two forms), SettleIcon, RowHighlight and DragLift's older form: each on its own small view, none on a parent")
        XCTAssertFalse(text.contains("value: hovered)"))
        // F3: `drag = nil` is not inside withAnimation; only SettleIcon's own state animates the drop.
        XCTAssertFalse(text.contains("withAnimation"), "a transaction-wide animation also moves rows and labels")
        let end = try XCTUnwrap(text.range(of: "func endDrag()"))
        let body = String(text[end.lowerBound...].prefix(1700))
        XCTAssertTrue(body.contains("self.drag = nil"))
        XCTAssertTrue(body.contains("settling = Settling(icon: drag.icon, location: drag.location)"))
    }

    /// F1: frames missing for one pass must not close or misplace a list that is open.
    func testMissingFramesKeepTheListWhereItWasAndAFadedListComesBack() throws {
        let text = try dock()
        let sync = try XCTUnwrap(text.range(of: "func syncSide() {"))
        let body = String(text[sync.lowerBound...].prefix(1300))
        XCTAssertTrue(body.contains("guard isShown, let p = panel, let side = model.liveSide else {\n            closeSidePanel()"), "closes only when nothing is open")
        XCTAssertTrue(body.contains("let barFrame = model.frames[DockView.barKey], let anchor = sideAnchor() else { return }"), "unmeasured: wait")
        XCTAssertTrue(body.contains("sp.alphaValue < 1"), "a list faded by a close that came to nothing opens again")
        XCTAssertTrue(text.contains("guard self.model.liveSide == nil else { self.syncSide(); return }"))
    }

    /// F2: the probe pins the dock and never moves the pointer, so a list a check opened is exempt
    /// from the grace and the real path (pinned or not) is the one it measures.
    func testAListACheckOpenedIsHeldUntilTheCheckClosesIt() throws {
        let text = try dock()
        XCTAssertTrue(text.contains("sideHeldForCheck = true\n        model.more = t.id"))
        XCTAssertTrue(text.contains("if sideHeldForCheck { sideGrace.reset(); return }"))
        XCTAssertTrue(text.contains("sideHeldForCheck = false\n        model.more = nil"))
    }

    /// F4: the growth animation reads the layer's own anchor, in a container this code owns.
    func testTheGrowthAnimationReadsTheLayersAnchor() throws {
        let text = try dock()
        XCTAssertTrue(text.contains("DockSide.growOffset(grow: grow, anchorPoint: layer.anchorPoint, size: layer.bounds.size)"))
        XCTAssertTrue(text.contains("container.addSubview(host)\n        sp.contentView = container"))
    }

    /// F5/F7: the label slot keeps its offset and its measure, and keeps its size while a list covers it.
    func testTheLabelSlotKeepsItsAlignmentAndItsSizeWhileAListIsOpen() throws {
        let text = try dock()
        let side = try XCTUnwrap(text.range(of: "@ViewBuilder private var side: some View {"))
        let body = String(text[side.lowerBound...].prefix(1700))
        XCTAssertEqual(body.components(separatedBy: ".offset(sideOffset(labelKey))").count - 1, 2, "both orientations line the label up with its tile")
        XCTAssertEqual(body.components(separatedBy: ".modifier(SizeReport(size: $sideSize))").count - 1, 2)
        XCTAssertTrue(body.contains("if model.liveSide != nil {"), "a list open: the slot holds its size")
        XCTAssertTrue(body.contains("Color.clear.frame(width: vertical ? max(sideSize.width, 1) : max(sideSize.width, 1)"))
        XCTAssertFalse(text.contains("mode == .bar, model.liveSide != nil { return nil }"), "the label text isn't dropped (that resized a side dock)")
    }

    /// F8/F9: Esc fades the list with the dock, and ends a drag in flight first.
    func testEscFadesTheListWithTheDockAndEndsADragFirst() throws {
        let text = try dock()
        let hide = try XCTUnwrap(text.range(of: "func hide(animated: Bool = true) {"))
        let body = String(text[hide.lowerBound...].prefix(2200))
        XCTAssertTrue(body.contains("let fadeSide = animated && !reduceMotion && (sidePanel?.isVisible ?? false)"))
        XCTAssertTrue(body.contains("if fadeSide { sidePanel?.animator().alphaValue = 0 }"), "in the same group as the dock's fade")
        XCTAssertTrue(body.contains("self.dismissSide()\n            p.orderOut(nil)"), "ordered out after the fade")
        let monitor = try XCTUnwrap(text.range(of: "matching: .keyDown"))
        let esc = String(text[monitor.lowerBound...].prefix(900))
        let cancel = try XCTUnwrap(esc.range(of: "self.model.cancelDrag()"))
        let close = try XCTUnwrap(esc.range(of: "self.closeSideNow(\"Esc\")"))
        XCTAssertLessThan(cancel.lowerBound, close.lowerBound, "the drag ends before the list goes")
        XCTAssertFalse(text.contains("lastSide = nil\n    }\n\n    func forgetSide"), "reset keeps the list's content for the fade")
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
