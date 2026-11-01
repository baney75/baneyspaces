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
        XCTAssertTrue(app.contains("SystemMissionControl.takeOver(stillWanted:"))
        XCTAssertTrue(app.contains("MissionControlKeys.enabled"))
        // start(), then the Accessibility paths and the restore-dock command each give it back.
        XCTAssertGreaterThanOrEqual(app.components(separatedBy: "SystemMissionControl.restore(").count - 1, 5,
                                    "giveMissionControlBack, quit, startWhenTrusted, stillTrusted and --restore-dock")
        let restoreDock = try XCTUnwrap(app.range(of: "\"--restore-dock\""))
        XCTAssertTrue(app[restoreDock.upperBound...].prefix(400).contains("SystemMissionControl.restore()"))
        XCTAssertNotNil(app.range(of: "missionControlKeys.start()\n        syncMissionControl()"), "start() syncs it right after the key watcher")
    }

    /// The swipe and the corners are behind the same switch and open the overview, not toggle it blindly.
    func testTheSwipeAndTheCornersOpenTheOverview() throws {
        let app = try source("Sources/BaneySpaces/AppDelegate.swift")
        let sync = try XCTUnwrap(app.range(of: "private func syncMissionControl()").map { app[$0.lowerBound...].prefix(1800) })
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
        XCTAssertTrue(over.contains("let reason = installer.install(pid: getpid())") && over.contains("MissionControlSetup.takeOver(takeover, arm: { reason })"), "nothing is switched off before the launch agent is armed")
        XCTAssertTrue(over.contains("installer.remove()"), "giving back removes it")
        let stop = try XCTUnwrap(quit.range(of: "trackpadSwipe.stop()")).lowerBound
        for earlier in ["SystemMissionControl.restore()", "spaces.restoreAll()", "restoreSpotlight()", "spaces.flushWrites()"] {
            XCTAssertLessThan(try XCTUnwrap(quit.range(of: earlier)).lowerBound, stop,
                              "the private framework is let go of last: \(earlier) comes first")
        }
        let script = MissionControlWatchdog.script
        XCTAssertTrue(script.contains("--restore-mission-control") && script.contains(MissionControlWatchdog.capability))
        XCTAssertFalse(script.contains("pgrep"), "a running BaneySpaces that isn't the one that wrote the heartbeat doesn't count")
        let uninstall = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("uninstall.sh"), encoding: .utf8)
        XCTAssertTrue(uninstall.contains("\"${1:-}\" = \"--restore-mission-control\""), "the agent's restore mode lives in uninstall.sh")
    }

    /// Nothing takes Mission Control off before something answers its key.
    func testItIsOnlyTakenWhileTheKeyWatcherRuns() throws {
        let app = try source("Sources/BaneySpaces/AppDelegate.swift")
        XCTAssertTrue(app.contains("private var missionControlWanted: Bool { started && MissionControlKeys.enabled && missionControlKeys.isActive }"))
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

    /// Holding Mission Control off needs the agent loaded and the Dock's switch left alone.
    func testTheTickGivesMissionControlBackWhenTheWayBackOrTheSwitchIsGone() throws {
        let app = try source("Sources/BaneySpaces/AppDelegate.swift")
        let check = try XCTUnwrap(app.range(of: "private func checkMissionControlHeld()").map { String(app[$0.lowerBound...].prefix(1500)) })
        XCTAssertTrue(check.contains("SystemMissionControl.isOffAtDock"))
        XCTAssertTrue(check.contains("setup.model.setViewerKeys(false)"), "the switch in Settings goes off too, so the next launch doesn't take it again")
        XCTAssertTrue(check.contains("SystemMissionControl.isArmed") && check.contains("syncMissionControl()"))
        XCTAssertTrue(check.contains("DispatchQueue.global"), "launchctl is asked off the main thread")
        XCTAssertTrue(app.contains("self.checkMissionControlHeld()"))
        let over = try source("Sources/BaneySpaces/MissionControlOverride.swift")
        XCTAssertTrue(over.contains("done.wait(timeout: .now() + 3)"), "launchctl can't hold the app up")
        XCTAssertTrue(over.contains("DurableRecord.write(record, to: file)") && over.contains("CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)"))
    }

    /// The launch agent is set up off the main thread, one attempt at a time, and a swipe queued
    /// before a stop is dropped.
    func testArmingIsOffTheMainThreadAndALateSwipeIsDropped() throws {
        let over = try source("Sources/BaneySpaces/MissionControlOverride.swift")
        let take = try XCTUnwrap(over.range(of: "static func takeOver(stillWanted").map { String(over[$0.lowerBound...].prefix(600)) })
        XCTAssertTrue(take.contains("DispatchQueue.global") && take.contains("installer.install(pid: getpid())") && take.contains("DispatchQueue.main.async"))
        XCTAssertTrue(take.contains("guard stillWanted()"), "a switch turned off meanwhile changes nothing")
        let app = try source("Sources/BaneySpaces/AppDelegate.swift")
        XCTAssertTrue(app.contains("guard !armingMissionControl else { return }"))
        XCTAssertTrue(over.contains("self.generation == session"), "a swipe from an earlier session is dropped")
        XCTAssertTrue(over.contains("showMissionControlGestureEnabled"))
    }

    /// Nothing answers the key once the watcher is gone, so Mission Control comes back.
    func testTheHeldCheckGivesMissionControlBackWhenTheKeyWatcherStops() throws {
        let app = try source("Sources/BaneySpaces/AppDelegate.swift")
        let check = try XCTUnwrap(app.range(of: "private func checkMissionControlHeld()").map { String(app[$0.lowerBound...].prefix(500)) })
        XCTAssertTrue(check.contains("guard missionControlKeys.isActive else"))
    }

    func testTheMachPortOfAMemoryRegionIsLetGo() throws {
        let buffer = try source("Sources/BaneySpacesCore/SafeBuffer.swift")
        XCTAssertTrue(buffer.contains("mach_port_deallocate(mach_task_self_, object)"))
        // And a long run of lookups neither fails nor grows the process's ports without end.
        var block = [UInt8](repeating: 0, count: 64)
        block.withUnsafeMutableBytes { raw in
            let inside = UnsafeRawPointer(raw.baseAddress!)
            for _ in 0..<2000 { XCTAssertGreaterThan(SafeBuffer.length(of: inside), 0) }
        }
    }
}
