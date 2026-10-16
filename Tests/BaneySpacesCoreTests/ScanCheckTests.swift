import XCTest
@testable import BaneySpacesCore

final class ScanCheckTests: XCTestCase {
    /// 10-16: Accessibility answered with nothing, the model dropped every window, and the dock
    /// showed workspace 1 empty with T3 Code on screen. Those windows must count as unplaced.
    func testWindowsOnScreenWithNoWorkspaceAreUnplaced() {
        let onScreen: [WindowID: Int32] = [48268: 53933, 41612: 46981]
        XCTAssertEqual(ScanCheck.unplaced(onScreen: onScreen, placed: [], notWindows: [], unsure: []), [48268, 41612])
    }

    func testPlacedSheetsAndBusyAppsDontCount() {
        let onScreen: [WindowID: Int32] = [1: 10, 2: 10, 3: 20, 4: 30]
        XCTAssertEqual(ScanCheck.unplaced(onScreen: onScreen, placed: [1], notWindows: [2], unsure: [20]), [4])
    }

    func testRescansOnlyWhenSomethingIsUnplacedAndNotTooOften() {
        let t = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(ScanCheck.shouldRescan(unplaced: [1], lastScan: t, now: t.addingTimeInterval(3)))
        XCTAssertFalse(ScanCheck.shouldRescan(unplaced: [1], lastScan: t, now: t.addingTimeInterval(1)))
        XCTAssertFalse(ScanCheck.shouldRescan(unplaced: [], lastScan: t, now: t.addingTimeInterval(60)))
    }
}
