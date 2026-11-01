import XCTest
@testable import BaneySpacesCore

final class WorkspaceSwitcherOrderTests: XCTestCase {
    func testEmptyWorkspacesAreHidden() {
        let order = WorkspaceSwitcherOrder.make(current: 2, recent: [2, 1, 3], occupied: [1, 2, 3], range: [1, 2, 3, 4])
        XCTAssertEqual(order, [2, 1, 3])
        XCTAssertFalse(order.contains(4))
    }

    func testCurrentStaysWhenEmptyAndIsMarked() {
        let order = WorkspaceSwitcherOrder.make(current: 5, recent: [5, 2], occupied: [2], range: Array(1...9))
        XCTAssertEqual(order, [5, 2])
        XCTAssertEqual(SwitcherTileText.caption(count: 0, isCurrent: true), "Here · empty")
        XCTAssertEqual(SwitcherTileText.caption(count: 3, isCurrent: true), "Here · 3 windows")
        XCTAssertEqual(SwitcherTileText.caption(count: 1, isCurrent: false), "1 window")
    }

    func testOnlyOccupiedPlusCurrentWithSeveralEmpties() {
        // Nine workspaces, three with windows, current (1) empty: four tiles, not nine.
        let order = WorkspaceSwitcherOrder.make(current: 1, recent: [1, 6, 4, 2], occupied: [3, 6, 8], range: Array(1...9))
        XCTAssertEqual(order, [1, 6, 3, 8])
    }

    func testOrderIsMostRecentFirstThenNumberOrder() {
        // Current first, recent deduped (empty 4 and out-of-range 12 skipped), then the rest by number.
        let order = WorkspaceSwitcherOrder.make(current: 3, recent: [3, 7, 7, 4, 12, 2, 7], occupied: [9, 2, 7, 5, 3], range: Array(1...9))
        XCTAssertEqual(order, [3, 7, 2, 5, 9])
        for _ in 0..<20 {
            XCTAssertEqual(WorkspaceSwitcherOrder.make(current: 3, recent: [3, 7, 7, 4, 12, 2, 7], occupied: [9, 2, 7, 5, 3], range: Array(1...9)), order)
        }
    }

    func testCurrentMissingFromRangeIsOmitted() {
        let order = WorkspaceSwitcherOrder.make(current: 9, recent: [1], occupied: [1, 2], range: [1, 2])
        XCTAssertEqual(order, [1, 2])
    }
}

final class WindowBarGateTests: XCTestCase {
    func testHoldOpensWhenThePidHasMoreThanOneWindowAcrossTiles() {
        let tiles: [(pid: Int32, windows: Int)] = [(7, 1), (7, 1), (8, 3)]
        let count = WindowBarGate.windowCount(pid: 7, tiles: tiles)
        XCTAssertEqual(count, 2)
        XCTAssertTrue(WindowBarGate.shouldOpen(windowCount: count))
    }

    func testHoldSkipsASingleWindowApp() {
        let tiles: [(pid: Int32, windows: Int)] = [(3, 1), (4, 2)]
        let count = WindowBarGate.windowCount(pid: 3, tiles: tiles)
        XCTAssertEqual(count, 1)
        XCTAssertFalse(WindowBarGate.shouldOpen(windowCount: count))
    }
}

final class SwitcherLayoutTests: XCTestCase {
    func testNineTilesFitANarrowScreenByWrapping() {
        let cols = SwitcherLayout.workspaceColumns(tileCount: 9, maxWidth: 1024)
        XCTAssertLessThanOrEqual(SwitcherLayout.rowWidth(columns: cols), 1024)
        // 8*108 + 7*12 + 28 = 976 <= 1024; 9*108 + 8*12 + 28 = 1096 would clip.
        XCTAssertEqual(cols, 8)
        XCTAssertLessThanOrEqual(SwitcherLayout.rowWidth(columns: 8), 1024)
        XCTAssertGreaterThan(SwitcherLayout.rowWidth(columns: 9), 1024)
    }

    func testSingleTileStaysOneColumn() {
        XCTAssertEqual(SwitcherLayout.workspaceColumns(tileCount: 1), 1)
    }

    func testAFewTilesStayOnOneRow() {
        let cols = SwitcherLayout.workspaceColumns(tileCount: 3, maxWidth: 1024)
        XCTAssertEqual(cols, 3)
        XCTAssertEqual(SwitcherLayout.rows(tileCount: 3, columns: cols), [0..<3])
    }

    func testOneRowIsOneTileHighPlusPadding() {
        XCTAssertEqual(SwitcherLayout.height(rows: 1), 128 + 28)
        let size = SwitcherLayout.panelSize(tileCount: 3)
        XCTAssertEqual(size.width, 3 * 108 + 2 * 12 + 28)
        XCTAssertEqual(size.height, 128 + 28)
    }

    func testTwoWrappedRowsGrowByOneTileAndOneGap() {
        XCTAssertEqual(SwitcherLayout.height(rows: 2), 2 * 128 + 12 + 28)
        let size = SwitcherLayout.panelSize(tileCount: 9, maxWidth: 1024)
        XCTAssertEqual(size.width, 976)
        XCTAssertEqual(size.height, 2 * 128 + 12 + 28)
        XCTAssertEqual(SwitcherLayout.rows(tileCount: 9, columns: 8), [0..<8, 8..<9])
    }

    func testTheRealScreenWidthDecidesTheColumns() {
        // A 1,920 pt display holds nine on one row; the 1,024 default would wrap them.
        XCTAssertEqual(SwitcherLayout.workspaceColumns(tileCount: 9, maxWidth: 1920), 9)
        XCTAssertEqual(SwitcherLayout.panelSize(tileCount: 9, maxWidth: 1920).height, 128 + 28)
        // A narrow one (Sidecar in portrait) wraps to fewer.
        XCTAssertEqual(SwitcherLayout.workspaceColumns(tileCount: 9, maxWidth: 600), 4)
    }
}

final class SwitcherPanelFrameTests: XCTestCase {
    private func inside(_ r: CGRect, _ v: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(r.minX, v.minX, file: file, line: line)
        XCTAssertGreaterThanOrEqual(r.minY, v.minY, file: file, line: line)
        XCTAssertLessThanOrEqual(r.maxX, v.maxX, file: file, line: line)
        XCTAssertLessThanOrEqual(r.maxY, v.maxY, file: file, line: line)
    }

    func testSingleDisplayCentersInTheVisibleFrame() {
        // Menu bar 25 pt, Dock 70 pt: the visible frame isn't the screen.
        let visible = CGRect(x: 0, y: 70, width: 1440, height: 805)
        let r = SwitcherPanelFrame.center(content: CGSize(width: 400, height: 156), visibleFrame: visible)
        XCTAssertEqual(r, CGRect(x: 520, y: 394, width: 400, height: 156))
        inside(r, visible)
    }

    func testMultipleDisplaysUseTheOneUnderThePointer() {
        let screens: [(frame: CGRect, visible: CGRect)] = [
            (CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 0, y: 0, width: 1440, height: 875)),
            (CGRect(x: 1440, y: 0, width: 2560, height: 1440), CGRect(x: 1440, y: 0, width: 2560, height: 1415)),
        ]
        let v = SwitcherPanelFrame.activeVisibleFrame(pointer: CGPoint(x: 2000, y: 500), screens: screens, main: 0)
        XCTAssertEqual(v, screens[1].visible)
        let r = SwitcherPanelFrame.center(content: CGSize(width: 600, height: 156), visibleFrame: v!)
        XCTAssertEqual(r.midX, screens[1].visible.midX)
        inside(r, screens[1].visible)
        // Pointer in a gap between displays: the main one.
        XCTAssertEqual(SwitcherPanelFrame.activeVisibleFrame(pointer: CGPoint(x: -50, y: -50), screens: screens, main: 1), screens[1].visible)
    }

    func testANegativeOriginLeftDisplay() {
        let left = CGRect(x: -1920, y: -200, width: 1920, height: 1055)
        let screens: [(frame: CGRect, visible: CGRect)] = [
            (CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 0, y: 0, width: 1440, height: 875)),
            (CGRect(x: -1920, y: -200, width: 1920, height: 1080), left),
        ]
        let v = SwitcherPanelFrame.activeVisibleFrame(pointer: CGPoint(x: -900, y: 100), screens: screens, main: 0)
        XCTAssertEqual(v, left)
        let r = SwitcherPanelFrame.center(content: CGSize(width: 976, height: 296), visibleFrame: left)
        XCTAssertEqual(r, CGRect(x: -1448, y: 179, width: 976, height: 296))
        inside(r, left)
    }

    func testContentWiderThanTheDisplayIsClampedInside() {
        let left = CGRect(x: -1024, y: 0, width: 1024, height: 743)
        let r = SwitcherPanelFrame.center(content: CGSize(width: 1096, height: 900), visibleFrame: left)
        XCTAssertEqual(r, left)
        inside(r, left)
    }
}

final class SwitcherSelectionTests: XCTestCase {
    func testNextIsTheNextDisplayedCard() {
        XCTAssertEqual(SwitcherSelection.advance(selected: 0, count: 4, forward: true), 1)
        XCTAssertEqual(SwitcherSelection.advance(selected: 2, count: 4, forward: true), 3)
    }

    func testWrapsAtBothEnds() {
        XCTAssertEqual(SwitcherSelection.advance(selected: 3, count: 4, forward: true), 0)
        XCTAssertEqual(SwitcherSelection.advance(selected: 0, count: 4, forward: false), 3)
        XCTAssertEqual(SwitcherSelection.advance(selected: 0, count: 1, forward: true), 0)
        XCTAssertEqual(SwitcherSelection.advance(selected: 0, count: 0, forward: true), 0)
        // A stale index from a longer list still lands on a card.
        XCTAssertEqual(SwitcherSelection.advance(selected: 7, count: 3, forward: true), 2)
    }

    func testBackStepsReverseForwardSteps() {
        var i = 1
        for _ in 0..<5 { i = SwitcherSelection.advance(selected: i, count: 4, forward: true) }
        for _ in 0..<5 { i = SwitcherSelection.advance(selected: i, count: 4, forward: false) }
        XCTAssertEqual(i, 1)
    }

    func testAGestureStartsOnTheCardAfterCurrent() {
        XCTAssertEqual(SwitcherSelection.first(count: 4, forward: true), 1)
        XCTAssertEqual(SwitcherSelection.first(count: 4, forward: false), 3)
        XCTAssertEqual(SwitcherSelection.first(count: 1, forward: true), 0)
    }

    func testArrowsStepLikeTab() {
        XCTAssertEqual(SwitcherSelection.arrow(keyCode: 124), true)
        XCTAssertEqual(SwitcherSelection.arrow(keyCode: 125), true)
        XCTAssertEqual(SwitcherSelection.arrow(keyCode: 123), false)
        XCTAssertEqual(SwitcherSelection.arrow(keyCode: 126), false)
        XCTAssertNil(SwitcherSelection.arrow(keyCode: 48))
        XCTAssertNil(SwitcherSelection.arrow(keyCode: 53))
    }

    func testWorkspacesModeTabReleaseOwesNoStep() {
        // Workspaces mode steps on the press and never defers, so Tab's release must not step again.
        var hold = TabHold()
        hold.press(at: 0)
        XCTAssertNil(hold.release())
        hold.press(at: 1, forward: true, deferStep: false)
        XCTAssertNil(hold.release())
        // Apps mode defers once, and only once.
        hold.press(at: 2, forward: false, deferStep: true)
        XCTAssertEqual(hold.release(), false)
        XCTAssertNil(hold.release())
    }
}

/// The app reaches each rule above through Core, so the tests above test what runs.
final class SwitcherWiringTests: XCTestCase {
    func testTheAppListsOnlyOccupiedWorkspaces() throws {
        let spaces = try Repo.code("Sources/BaneySpaces/Spaces.swift")
        XCTAssertTrue(spaces.contains("occupied: Set(Workspaces.range.filter(isOccupied))"))
        let switcher = try Repo.code("Sources/BaneySpaces/WorkspaceSwitcher.swift")
        XCTAssertTrue(switcher.contains("isCurrent: n == current"))
        XCTAssertTrue(switcher.contains("SwitcherTileText.caption(count: tile.count, isCurrent: tile.isCurrent)"))
    }

    func testThePanelIsFramedAndSizedFromCore() throws {
        let switcher = try Repo.code("Sources/BaneySpaces/WorkspaceSwitcher.swift")
        XCTAssertEqual(switcher.components(separatedBy: "SwitcherPanelFrame.center(").count - 1, 2, "show and relayout")
        XCTAssertTrue(switcher.contains("SwitcherPanelFrame.activeVisibleFrame("))
        XCTAssertFalse(switcher.contains("frame.midX"), "centered on the whole screen, not its visible frame")
        let row = try XCTUnwrap(switcher.range(of: "private var workspaceRow").flatMap { start in
            switcher.range(of: "private func workspaceTile").map { String(switcher[start.lowerBound..<$0.lowerBound]) }
        })
        XCTAssertFalse(row.contains("LazyVGrid"), "a lazy grid measured far taller than its one row")
        XCTAssertTrue(row.contains("SwitcherLayout.rows(") && row.contains("maxWidth: model.maxWidth"))
        XCTAssertTrue(switcher.contains("SwitcherLayout.panelSize(tileCount: model.tiles.count, maxWidth: model.maxWidth)"))
    }

    func testSameAppFocusStampsBeforeTheDockReloads() throws {
        let spaces = try Repo.code("Sources/BaneySpaces/Spaces.swift")
        let helper = try XCTUnwrap(spaces.range(of: "private func noteFocusAndReload"))
        let body = String(spaces[helper.lowerBound...].prefix(260))
        let stamp = try XCTUnwrap(body.range(of: "noteFocus(id)"))
        let reload = try XCTUnwrap(body.range(of: "noteFocusedDisplay(of: id)"))
        XCTAssertLessThan(stamp.lowerBound, reload.lowerBound, "stamp the activation, then reload the dock")
        XCTAssertTrue(body.contains("onChange?()"), "same focused display still reloads")
        let within = try XCTUnwrap(spaces.range(of: "private func focusMovedWithin").flatMap { s in
            spaces.range(of: "private func parkedPids").map { String(spaces[s.lowerBound..<$0.lowerBound]) }
        })
        XCTAssertTrue(within.contains("return noteFocusAndReload(w.id)"))
        XCTAssertFalse(within.contains("noteFocusedDisplay("), "no reload before the stamp")
        let stay = try XCTUnwrap(spaces.range(of: "private func stay(on").map { String(spaces[$0.lowerBound...].prefix(400)) })
        XCTAssertTrue(stay.contains("noteFocusAndReload(w.id)") && !stay.contains("noteFocusedDisplay("))
    }

    func testTabShiftTabAndArrowsShareOneStepper() throws {
        let switcher = try Repo.code("Sources/BaneySpaces/WorkspaceSwitcher.swift")
        XCTAssertEqual(switcher.components(separatedBy: "SwitcherSelection.advance(").count - 1, 2, "list and window bar")
        XCTAssertTrue(switcher.contains("SwitcherSelection.first(count: model.count, forward: forward)"))
        XCTAssertFalse(switcher.contains("% c"), "no hand-rolled wrap left")
        let keys = try Repo.code("Sources/BaneySpaces/MissionControlKeys.swift")
        XCTAssertTrue(keys.contains("SwitcherSelection.arrow(keyCode: code)"))
        let escape = try XCTUnwrap(keys.range(of: "code == escapeKey")).lowerBound
        let arrow = try XCTUnwrap(keys.range(of: "SwitcherSelection.arrow(keyCode: code)")).lowerBound
        XCTAssertLessThan(escape, arrow, "Esc still cancels before arrows are looked at")
        let app = try Repo.code("Sources/BaneySpaces/AppDelegate.swift")
        XCTAssertTrue(app.contains("keys.onArrow = { [weak self] forward in self?.switcher.arrow(forward: forward) }"))
    }
}
