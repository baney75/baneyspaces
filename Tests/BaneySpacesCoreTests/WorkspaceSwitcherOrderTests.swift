import XCTest
@testable import BaneySpacesCore

final class WorkspaceSwitcherOrderTests: XCTestCase {
    func testEmptyWorkspacesStayInTheOrder() {
        let order = WorkspaceSwitcherOrder.make(current: 2, recent: [2, 1, 3], range: [1, 2, 3, 4])
        XCTAssertEqual(order, [2, 1, 3, 4])
    }

    func testOnlyCurrentOccupiedStillListsEveryWorkspace() {
        // Old Spaces.switcherOrder dropped empties and returned [current] alone.
        let order = WorkspaceSwitcherOrder.make(current: 1, recent: [1], range: [1, 2, 3])
        XCTAssertEqual(order, [1, 2, 3])
        XCTAssertGreaterThan(order.count, 1)
    }

    func testCurrentMissingFromRangeIsOmittedThenRangeFills() {
        let order = WorkspaceSwitcherOrder.make(current: 9, recent: [1], range: [1, 2])
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
        XCTAssertEqual(cols, 5) // 5*108 + 4*12 + 28 = 616
        // Two rows: 5 + 4 still shows all nine.
        XCTAssertGreaterThanOrEqual(cols * 2, 9)
    }

    func testSingleTileStaysOneColumn() {
        XCTAssertEqual(SwitcherLayout.workspaceColumns(tileCount: 1), 1)
    }
}
