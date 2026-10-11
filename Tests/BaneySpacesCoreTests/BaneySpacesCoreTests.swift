import CoreGraphics
import Foundation
import XCTest
@testable import BaneySpacesCore

final class WorkspacesTests: XCTestCase {
    func testNewWindowsJoinTheCurrentWorkspace() {
        var w = Workspaces()
        XCTAssertEqual(w.sync(seen: [10, 11], alive: [10, 11]), [10, 11])
        _ = w.switchTo(2)
        XCTAssertEqual(w.sync(seen: [10, 11, 12], alive: [10, 11, 12]), [12])
        XCTAssertEqual(w.workspace(of: 10), 1)
        XCTAssertEqual(w.workspace(of: 12), 2)
    }

    func testSwitchingToAnEmptyWorkspaceHidesEverythingAndFocusesNothing() {
        var w = Workspaces()
        w.sync(seen: [10, 11], alive: [10, 11])
        let plan = w.switchTo(2)
        XCTAssertEqual(plan, SwitchPlan(hide: [10, 11], show: [], focus: nil))
        XCTAssertEqual(w.current, 2)
    }

    func testMovingAWindowCarriesItAndItBecomesThatWorkspacesFocus() {
        var w = Workspaces()
        w.sync(seen: [10, 11], alive: [10, 11])
        w.assign(11, to: 3)
        XCTAssertEqual(w.windows(on: 1), [10])
        XCTAssertEqual(w.switchTo(3), SwitchPlan(hide: [10], show: [11], focus: 11))
    }

    func testALateWindowDoesNotTakeOverTheRememberedFocus() {
        var w = Workspaces()
        w.sync(seen: [10, 11, 12], alive: [10, 11, 12])
        w.assign(11, to: 3)
        w.assign(12, to: 3, focus: false)
        XCTAssertEqual(w.switchTo(3).focus, 11)
        w.assign(10, to: 5, focus: false)
        XCTAssertEqual(w.switchTo(5).focus, 10)
    }

    func testComingBackFocusesTheLastWindowYouUsedThere() {
        var w = Workspaces()
        w.sync(seen: [10, 11, 12], alive: [10, 11, 12])
        w.noteFocus(12)
        _ = w.switchTo(4)
        XCTAssertEqual(w.switchTo(1).focus, 12)
    }

    func testClosedWindowsAreForgotten() {
        var w = Workspaces()
        w.sync(seen: [10, 11], alive: [10, 11])
        w.noteFocus(11)
        w.sync(seen: [10], alive: [10])
        XCTAssertNil(w.workspace(of: 11))
        XCTAssertEqual(w.switchTo(1).focus, 10)
    }

    func testAWindowAccessibilityMissedKeepsItsWorkspace() {
        var w = Workspaces()
        w.sync(seen: [10, 11], alive: [10, 11])
        w.assign(11, to: 5)
        // App 11 is busy: Accessibility doesn't list it, but the WindowServer still has it.
        w.sync(seen: [10], alive: [10, 11])
        XCTAssertEqual(w.workspace(of: 11), 5)
    }

    func testAListedWindowTheWindowServerDoesNotHaveIsIgnored() {
        var w = Workspaces()
        XCTAssertEqual(w.sync(seen: [10, 11], alive: [10]), [10])
    }

    func testOutOfRangeAssignIsIgnored() {
        var w = Workspaces()
        w.sync(seen: [10], alive: [10])
        w.assign(10, to: 0)
        w.assign(10, to: 10)
        w.assign(99, to: 2)
        XCTAssertEqual(w.workspace(of: 10), 1)
        XCTAssertNil(w.workspace(of: 99))
    }
}

final class GeometryTests: XCTestCase {
    let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testAppKitToAccessibilityFlipsY() {
        // A 1080p display stacked above a 982-point-tall primary display.
        let above = CGRect(x: 0, y: 982, width: 1920, height: 1080)
        XCTAssertEqual(Geometry.toAX(above, primaryHeight: 982), CGRect(x: 0, y: -1080, width: 1920, height: 1080))
        XCTAssertEqual(Geometry.toAX(laptop, primaryHeight: 982), laptop)
    }

    func testHidingSpotIsTheLastPixelOfTheFurthestScreen() {
        XCTAssertEqual(Geometry.hidingSpot(screens: [laptop]), CGPoint(x: 1511, y: 981))
        let right = CGRect(x: 1512, y: -100, width: 2560, height: 1440)
        XCTAssertEqual(Geometry.hidingSpot(screens: [laptop, right]), CGPoint(x: 4071, y: 1339))
    }

    func testStrandedMeansUnderAQuarterShows() {
        XCTAssertTrue(Geometry.isStranded(CGRect(x: 1511, y: 981, width: 800, height: 600), screens: [laptop]))
        // AeroSpace parks windows with a sliver left above the Dock.
        XCTAssertTrue(Geometry.isStranded(CGRect(x: 1500, y: 900, width: 800, height: 600), screens: [laptop]))
        XCTAssertFalse(Geometry.isStranded(CGRect(x: 1000, y: 500, width: 800, height: 600), screens: [laptop]))
    }

    func testRestoreRejectsASavedFrameThatIsMostlyOffscreen() {
        let corner = CGRect(x: 1511, y: 981, width: 800, height: 600)
        let r = Geometry.restoreFrame(saved: corner, size: .zero, screens: [laptop])
        XCTAssertEqual(r, CGRect(x: 356, y: 191, width: 800, height: 600))
    }

    func testRestoreKeepsAVisibleSavedFrame() {
        let saved = CGRect(x: 100, y: 80, width: 900, height: 700)
        XCTAssertEqual(Geometry.restoreFrame(saved: saved, size: .zero, screens: [laptop]), saved)
    }

    func testRestoreCentersAWindowWhoseScreenIsGone() {
        let saved = CGRect(x: 3000, y: 200, width: 2000, height: 700)
        let r = Geometry.restoreFrame(saved: saved, size: .zero, screens: [laptop])
        XCTAssertEqual(r, CGRect(x: 0, y: 141, width: 1512, height: 700))
    }

    func testRestoreWithNothingSavedCentersTheCurrentSize() {
        let r = Geometry.restoreFrame(saved: nil, size: CGSize(width: 800, height: 600), screens: [laptop])
        XCTAssertEqual(r, CGRect(x: 356, y: 191, width: 800, height: 600))
    }
}

final class SavedFramesTests: XCTestCase {
    func testRoundTripsThroughDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bs-\(UUID().uuidString)/frames.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var s = SavedFrames()
        s.frames[42] = CGRect(x: 1, y: 2, width: 3, height: 4)
        s.hiddenApps = [501, 777]
        s.save(to: url)
        XCTAssertEqual(SavedFrames.load(from: url), s)
    }

    func testMissingOrCorruptFileGivesAnEmptySet() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(SavedFrames.load(from: dir.appendingPathComponent("none.json")), SavedFrames())
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bad = dir.appendingPathComponent("bad.json")
        try Data("{not json".utf8).write(to: bad)
        XCTAssertEqual(SavedFrames.load(from: bad), SavedFrames())
    }

    func testAFileFromBeforeAppHidingStillLoads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = dir.appendingPathComponent("frames.json")
        try Data(#"{"frames":[7,[[1,2],[3,4]]]}"#.utf8).write(to: old)
        let s = SavedFrames.load(from: old)
        XCTAssertEqual(s.frames[7], CGRect(x: 1, y: 2, width: 3, height: 4))
        XCTAssertEqual(s.hiddenApps, [])
    }
}

final class ConcealmentTests: XCTestCase {
    func testAppsWithNothingHereAreHiddenWhole() {
        let plan = SwitchPlan(hide: [1, 2, 3], show: [4], focus: 4)
        let c = Concealment(plan: plan, owner: [1: 100, 2: 100, 3: 200, 4: 300])
        XCTAssertEqual(c.hideApps, [100, 200])
        XCTAssertEqual(c.showApps, [300])
        XCTAssertEqual(c.park, [])
    }

    func testAnAppSplitAcrossWorkspacesParksOnlyItsOtherWindows() {
        // Two Helium windows: one stays here, one belongs elsewhere.
        let plan = SwitchPlan(hide: [1, 2], show: [3], focus: 3)
        let c = Concealment(plan: plan, owner: [1: 100, 2: 200, 3: 100])
        XCTAssertEqual(c.hideApps, [200])
        XCTAssertEqual(c.park, [1])
    }

    func testAnAppComingBackForAWaitingWindowStaysShownAndParksTheRest() {
        // App 100's window for this workspace hasn't answered yet; its window 1 belongs elsewhere.
        let plan = SwitchPlan(hide: [1, 2], show: [], focus: nil)
        let c = Concealment(plan: plan, owner: [1: 100, 2: 200], alsoShown: [100])
        XCTAssertEqual(c.hideApps, [200])
        XCTAssertEqual(c.park, [1])
    }
}

final class SavedLayoutTests: XCTestCase {
    func testRestartPutsWindowsBackOnTheirWorkspaces() {
        // Before the restart: 10 on 1, 11 on 4, 12 on 7; you were on 4 looking at 11.
        let saved = SavedLayout(current: 4, entries: [
            .init(window: 10, pid: 100, workspace: 1),
            .init(window: 11, pid: 100, workspace: 4),
            .init(window: 12, pid: 200, workspace: 7),
        ], lastFocused: [4: 11])
        // After the restart every window starts on workspace 1.
        var w = Workspaces()
        w.sync(seen: [10, 11, 12], alive: [10, 11, 12])
        w.restore(current: saved.current, home: saved.homes(livePids: [10: 100, 11: 100, 12: 200]),
                  lastFocused: saved.lastFocused)
        XCTAssertEqual(w.current, 4)
        XCTAssertEqual(w.workspace(of: 11), 4)
        XCTAssertEqual(w.workspace(of: 12), 7)
        XCTAssertEqual(w.switchTo(4).focus, 11)
    }

    func testAReusedWindowNumberFromAnotherAppIsNotMoved() {
        let saved = SavedLayout(current: 1, entries: [.init(window: 12, pid: 200, workspace: 7)])
        // After a logout, window 12 now belongs to a different process.
        XCTAssertEqual(saved.homes(livePids: [12: 999]), [:])
    }

    func testRoundTripsThroughDisk() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bs-\(UUID().uuidString)/layout.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let saved = SavedLayout(current: 3, entries: [.init(window: 5, pid: 9, workspace: 3)], lastFocused: [3: 5])
        saved.save(to: url)
        XCTAssertEqual(SavedLayout.load(from: url), saved)
    }
}
