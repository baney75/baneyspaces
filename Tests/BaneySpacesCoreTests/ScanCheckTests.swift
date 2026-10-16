import XCTest
@testable import BaneySpacesCore

final class ScanCheckTests: XCTestCase {
    /// 10-16: Accessibility answered with nothing, the model dropped every window, and the dock
    /// showed workspace 1 empty with T3 Code on screen. Those windows must count as unplaced.
    func testWindowsOnScreenWithNoWorkspaceAreUnplaced() {
        let onScreen: [WindowID: Int32] = [48268: 53933, 41612: 46981]
        XCTAssertEqual(ScanCheck.unplaced(onScreen: onScreen, placed: [], notWindows: [], unsure: []), [48268, 41612])
    }

    func testPlacedSheetsAndUnreadableAppsDontCount() {
        let onScreen: [WindowID: Int32] = [1: 10, 2: 10, 3: 20, 4: 30]
        XCTAssertEqual(ScanCheck.unplaced(onScreen: onScreen, placed: [1], notWindows: [2], unsure: [20]), [4])
    }
}

final class UnplacedWindowsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1000)

    func testAWindowNoScanHasLookedAtIsDueAtOnce() {
        XCTAssertTrue(UnplacedWindows().due([7], now: t0))
        XCTAssertFalse(UnplacedWindows().due([], now: t0))
    }

    func testBacksOffAfterEachMissAndNeverStops() {
        var u = UnplacedWindows()
        var now = t0
        for wait in [3.0, 6, 12, 30, 60, 60, 60] {
            u.scanned(unplaced: [7], now: now)
            XCTAssertFalse(u.due([7], now: now.addingTimeInterval(wait - 0.1)))
            XCTAssertTrue(u.due([7], now: now.addingTimeInterval(wait)))
            XCTAssertEqual(u.nextDue, now.addingTimeInterval(wait))
            now = now.addingTimeInterval(wait)
        }
    }

    /// r2 F1: a scan landing before the heal timer fires moves the window's next look, and the
    /// timer must follow it rather than give up.
    func testAnotherScanMovesTheNextLook() {
        var u = UnplacedWindows()
        u.scanned(unplaced: [7], now: t0)
        u.scanned(unplaced: [7], now: t0.addingTimeInterval(2))
        XCTAssertFalse(u.due([7], now: t0.addingTimeInterval(3.1)))
        XCTAssertEqual(u.nextDue, t0.addingTimeInterval(8))
    }

    func testPlacedWindowsAreForgottenAndANewOneIsDueRegardless() {
        var u = UnplacedWindows()
        u.scanned(unplaced: [7], now: t0)
        u.scanned(unplaced: [], now: t0.addingTimeInterval(3))
        XCTAssertNil(u.nextDue)
        u.scanned(unplaced: [8], now: t0.addingTimeInterval(3))
        XCTAssertTrue(u.due([8, 9], now: t0.addingTimeInterval(3)))
    }

    /// r2 S2: a window Accessibility lists a moment late is still new; one that sat unplaced
    /// through an outage isn't.
    func testNewOnlyIfFirstFoundUnplacedRecently() {
        var u = UnplacedWindows()
        u.scanned(unplaced: [7], now: t0)
        XCTAssertTrue(u.isNew(7, now: t0.addingTimeInterval(3)))
        XCTAssertFalse(u.isNew(7, now: t0.addingTimeInterval(9)))
        XCTAssertTrue(u.isNew(99, now: t0))
    }
}
