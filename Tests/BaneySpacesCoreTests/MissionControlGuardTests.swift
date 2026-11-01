import XCTest
@testable import BaneySpacesCore

/// The app target can't be imported into tests, so these read its source. They guard the
/// regression ledger row "macOS Mission Control still opens from the trackpad/hot corner" (10-31):
/// every way in to macOS's Mission Control has to be answered by BaneySpaces, and given back.
final class MissionControlGuardTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.components(separatedBy: "//")[0] }.joined(separator: "\n")
    }

    /// The Dock's switch, which is what stops the trackpad swipe, the hot corners and App Exposé.
    func testTheDockSwitchAndHotCornersAreTheOnesTaken() {
        XCTAssertEqual(MissionControlTakeover.flag, "mcx-expose-disabled")
        XCTAssertEqual(MissionControlTakeover.domain, "com.apple.dock")
        XCTAssertEqual(MissionControlTakeover.missionControl, 2)
        XCTAssertEqual(MissionControlTakeover.Corner.allCases.map(\.key),
                       ["wvous-tl-corner", "wvous-tr-corner", "wvous-bl-corner", "wvous-br-corner"])
    }

    /// Taken when BaneySpaces can answer (Accessibility granted, switch on); given back on the
    /// paths the Dock and the top drag use: switch off, Accessibility lost, `--restore-dock`.
    func testItIsTakenOnStartAndGivenBackOnTheRestorePaths() throws {
        let app = try source("Sources/BaneySpaces/AppDelegate.swift")
        XCTAssertTrue(app.contains("SystemMissionControl.takeOver()"))
        XCTAssertTrue(app.contains("MissionControlKeys.enabled"))
        // start(), then the Accessibility paths and the restore-dock command each give it back.
        XCTAssertGreaterThanOrEqual(app.components(separatedBy: "SystemMissionControl.restore(").count - 1, 5,
                                    "syncMissionControl, quit, startWhenTrusted, stillTrusted and --restore-dock")
        let restoreDock = try XCTUnwrap(app.range(of: "\"--restore-dock\""))
        XCTAssertTrue(app[restoreDock.upperBound...].prefix(400).contains("SystemMissionControl.restore()"))
        XCTAssertNotNil(app.range(of: "missionControlKeys.start()\n        syncMissionControl()"), "start() syncs it right after the key watcher")
    }

    /// The swipe and the corners are behind the same switch and open the overview, not toggle it blindly.
    func testTheSwipeAndTheCornersOpenTheOverview() throws {
        let app = try source("Sources/BaneySpaces/AppDelegate.swift")
        let sync = try XCTUnwrap(app.range(of: "private func syncMissionControl()").map { app[$0.lowerBound...].prefix(700) })
        XCTAssertTrue(sync.contains("trackpadSwipe.start()") && sync.contains("hotCorners.set("))
        XCTAssertTrue(sync.contains("trackpadSwipe.stop()") && sync.contains("hotCorners.stop()"))
        XCTAssertTrue(app.contains("case .up: if !self.viewer.isOpen { self.viewer.open() }"))
        XCTAssertTrue(app.contains("case .down: if self.viewer.isOpen { self.viewer.toggle() }"))
    }

    /// The private framework is loaded at run time and never linked, so a Mac without it still starts.
    func testTheTrackpadFrameworkIsLoadedAtRunTimeAndFailsSoft() throws {
        let text = try source("Sources/BaneySpaces/MissionControlOverride.swift")
        XCTAssertTrue(text.contains("dlopen(\"/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport\""))
        XCTAssertTrue(text.contains("loadFailed = true"), "Settings is told when it won't load")
        let package = try source("Package.swift")
        XCTAssertFalse(package.contains("MultitouchSupport"), "linking it would stop BaneySpaces opening where it's missing")
        let settings = try source("Sources/BaneySpaces/Setup.swift")
        XCTAssertTrue(settings.contains("trackpadFailed"), "Settings shows why the swipe is off")
    }

    /// The Mission Control key and ⌃↑ go through the tested matcher; F3 and ⌃↑ are the two.
    func testTheKeysUseTheTestedMatcher() throws {
        let keys = try source("Sources/BaneySpaces/MissionControlKeys.swift")
        XCTAssertTrue(keys.contains("MissionControlKey.matches("))
        XCTAssertFalse(keys.contains("code == missionControlKey"), "the key list lives in MissionControlKey")
    }

    /// A BaneySpaces that isn't running can't answer anything: quitting gives Mission Control back,
    /// except for an update's quit, which the launch agent covers.
    func testQuittingGivesMissionControlBackExceptForAnUpdate() throws {
        let app = try source("Sources/BaneySpaces/AppDelegate.swift")
        let quit = try XCTUnwrap(app.range(of: "func applicationWillTerminate").map { app[$0.lowerBound...].prefix(1200) })
        XCTAssertTrue(quit.contains("SystemMissionControl.restore()"))
        XCTAssertTrue(quit.contains("updatingTo") && quit.contains("SystemMissionControl.leaveForUpdate()"))
        let over = try source("Sources/BaneySpaces/MissionControlOverride.swift")
        XCTAssertTrue(over.contains("MissionControlSetup.takeOver(takeover, arm: { installer.install(pid: getpid()) })"), "nothing is switched off before the launch agent is armed")
        XCTAssertTrue(over.contains("installer.remove()"), "giving back removes it")
        XCTAssertLessThan(try XCTUnwrap(quit.range(of: "SystemMissionControl.restore()")).lowerBound, try XCTUnwrap(quit.range(of: "trackpadSwipe.stop()")).lowerBound,
                          "the private framework is let go of last, after what matters is restored")
        let script = MissionControlWatchdog.script
        XCTAssertTrue(script.contains("--restore-mission-control") && script.contains("pgrep"))
        let uninstall = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("uninstall.sh"), encoding: .utf8)
        XCTAssertTrue(uninstall.contains("\"${1:-}\" = \"--restore-mission-control\""), "the agent's restore mode lives in uninstall.sh")
    }

    /// Nothing takes Mission Control off before something answers its key.
    func testItIsOnlyTakenWhileTheKeyWatcherRuns() throws {
        let app = try source("Sources/BaneySpaces/AppDelegate.swift")
        XCTAssertTrue(app.contains("if started, MissionControlKeys.enabled, missionControlKeys.isActive, SystemMissionControl.takeOver() {"))
        XCTAssertTrue(app.contains("self.missionControlKeys.isActive,\n                          SystemMissionControl.problem == nil"), "an unarmed or taken-back state is tried again")
        XCTAssertTrue(app.contains("if self.missionControlKeys.isActive { self.syncMissionControl() }"), "retried watcher takes over")
    }

    /// The trackpads are listed once, then on IOKit's say-so; never on a timer, and by device id.
    func testTrackpadsAreListedOnNoticeNotOnATimer() throws {
        let text = try source("Sources/BaneySpaces/MissionControlOverride.swift")
        let swipe = try XCTUnwrap(text.range(of: "final class TrackpadSwipe").map { String(text[$0.lowerBound...]) })
        XCTAssertFalse(swipe.contains("Timer."), "no polling")
        XCTAssertEqual(text.components(separatedBy: "create()?.takeRetainedValue()").count - 1, 1, "one place lists devices")
        XCTAssertTrue(swipe.contains("kIOFirstMatchNotification") && swipe.contains("kIOTerminatedNotification"))
        let registry = try source("Sources/BaneySpacesCore/TrackpadRegistry.swift")
        XCTAssertTrue(registry.contains("framework.deviceID(d)"), "devices are told apart by id, not by pointer")
        XCTAssertTrue(registry.contains("TrackpadDevice.isTrackpad("), "a Magic Mouse is never watched")
        XCTAssertTrue(registry.contains("withExtendedLifetime(old)"), "lists outlive the unregistering")
    }

    /// The release frame has no data and still has to reach the swipe; mouse gestures are left alone.
    func testTheReleaseFrameIsDeliveredAndMouseGesturesAreLeftAlone() throws {
        let text = try source("Sources/BaneySpaces/MissionControlOverride.swift")
        XCTAssertTrue(text.contains("guard let device else { return 0 }"))
        XCTAssertFalse(text.contains("count > 0 else"), "a zero-contact frame ends the gesture")
        XCTAssertFalse(text.contains("MouseTwoFingerDoubleTapGesture"))
        XCTAssertTrue(text.contains("addLocalMonitorForEvents(matching: kinds"), "corners work over BaneySpaces' own windows")
        XCTAssertTrue(text.contains("[.mouseMoved, .flagsChanged]"), "and when the key a corner wants goes down with the pointer already there")
    }
}
