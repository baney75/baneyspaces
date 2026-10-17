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
        for wait in [3.0, 6, 12, 12, 12] {
            u.scanned(unplaced: [7], known: [7], now: now)
            XCTAssertFalse(u.due([7], now: now.addingTimeInterval(wait - 0.1)))
            XCTAssertTrue(u.due([7], now: now.addingTimeInterval(wait)))
            XCTAssertEqual(u.nextDue, now.addingTimeInterval(wait))
            now = now.addingTimeInterval(wait)
        }
    }

    /// r3 S1: scans that run early for other reasons (a burst at login) don't push the next look
    /// out; only the due look counts as a miss.
    func testEarlyScansLeaveTheNextLookAlone() {
        var u = UnplacedWindows()
        u.scanned(unplaced: [7], now: t0)
        for s in [0.5, 1, 1.5, 2, 2.5] { u.scanned(unplaced: [7], now: t0.addingTimeInterval(s)) }
        XCTAssertEqual(u.nextDue, t0.addingTimeInterval(3))
        XCTAssertTrue(u.due([7], now: t0.addingTimeInterval(3)))
    }

    /// r3 F1: a window hidden or minimized stops counting without a scan. Its entry must go, or
    /// the timer waits on an overdue look that never comes.
    func testKeepDropsWindowsThatStoppedCounting() {
        var u = UnplacedWindows()
        u.scanned(unplaced: [7, 8], now: t0)
        u.keep([8])
        XCTAssertFalse(u.due([], now: t0.addingTimeInterval(10)))
        u.keep([])
        XCTAssertNil(u.nextDue)
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

    /// r4 F2: the first heal look comes 3 s after the blip, inside `newFor`. A window that had a
    /// workspace before isn't new, however soon it heals.
    func testAWindowThatHadAWorkspaceIsNeverNew() {
        var u = UnplacedWindows()
        u.scanned(unplaced: [7], known: [7], now: t0)
        XCTAssertFalse(u.isNew(7, known: [7], now: u.nextDue!))
        XCTAssertTrue(u.isNew(8, known: [7], now: t0))
    }

    /// r4 F1: hiding it drops the entry (`keep`), which used to make it new again.
    func testHidingAKnownWindowDoesntMakeItNew() {
        var u = UnplacedWindows()
        u.scanned(unplaced: [7], known: [7], now: t0)
        u.keep([])
        XCTAssertFalse(u.isNew(7, known: [7], now: t0.addingTimeInterval(300)))
    }

    /// r4 F3: one that never had a workspace settles to a look a minute; one that had one keeps 12 s.
    func testOnlyKnownWindowsKeepTheFastLook() {
        var u = UnplacedWindows()
        var now = t0
        for wait in [3.0, 6, 12, 30, 60, 60] {
            u.scanned(unplaced: [9], now: now)
            XCTAssertEqual(u.nextDue, now.addingTimeInterval(wait))
            now = now.addingTimeInterval(wait)
        }
        var k = UnplacedWindows()
        now = t0
        for wait in [3.0, 6, 12, 12, 12] {
            k.scanned(unplaced: [7], known: [7], now: now)
            XCTAssertEqual(k.nextDue, now.addingTimeInterval(wait))
            now = now.addingTimeInterval(wait)
        }
    }
}
