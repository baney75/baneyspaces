import XCTest
@testable import BaneySpacesCore

/// The app target can't be imported into tests, so these read its source. They guard the
/// regression ledger row "macOS Mission Control still opens from a hot corner" (10-31):
/// every way in to macOS's Mission Control has to be answered by BaneySpaces, and given back.
final class MissionControlGuardTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.components(separatedBy: "//")[0] }.joined(separator: "\n")
    }

    /// The Dock's switch, which is what stops macOS's trackpad swipe, the hot corners and App Exposé.
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

    /// The corners are behind the same switch and open the overview, not toggle it blindly.
    func testTheCornersOpenTheOverview() throws {
        let app = try source("Sources/BaneySpaces/AppDelegate.swift")
        let sync = try XCTUnwrap(app.range(of: "private func syncMissionControl()").map { app[$0.lowerBound...].prefix(1800) })
        XCTAssertTrue(sync.contains("hotCorners.set("))
        let back = try XCTUnwrap(app.range(of: "private func giveMissionControlBack()").map { app[$0.lowerBound...].prefix(600) })
        XCTAssertTrue(back.contains("hotCorners.stop()"))
        XCTAssertTrue(app.contains("guard let self, self.started, !self.viewer.isOpen else { return }\n            self.viewer.open()"))
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

    /// Corners work over BaneySpaces' own windows and when the key a corner wants goes down late.
    func testCornersAreWatchedOverOwnWindowsAndForTheirKey() throws {
        let text = try source("Sources/BaneySpaces/MissionControlOverride.swift")
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

    /// The launch agent is set up off the main thread, and one attempt at a time.
    func testArmingIsOffTheMainThread() throws {
        let over = try source("Sources/BaneySpaces/MissionControlOverride.swift")
        let take = try XCTUnwrap(over.range(of: "static func takeOver(stillWanted").map { String(over[$0.lowerBound...].prefix(600)) })
        XCTAssertTrue(take.contains("DispatchQueue.global") && take.contains("installer.install(pid: getpid())") && take.contains("DispatchQueue.main.async"))
        XCTAssertTrue(take.contains("guard stillWanted()"), "a switch turned off meanwhile changes nothing")
        let app = try source("Sources/BaneySpaces/AppDelegate.swift")
        XCTAssertTrue(app.contains("guard !armingMissionControl else { return }"))
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

    /// Donovan removed the three-finger swipe on 11-01: it opened the overview on accidental touches.
    func testNoTrackpadSwipeCodeIsLeft() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var checked = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            checked += 1
            for name in ["Multitouch" + "Support", "Trackpad" + "Swipe", "Finger" + "Swipe"] {
                XCTAssertFalse(text.contains(name), "\(url.lastPathComponent) mentions \(name). Donovan removed the trackpad swipe on 11-01 because accidental three-finger touches opened the overview; don't bring it back.")
            }
        }
        XCTAssertGreaterThan(checked, 50, "the Sources tree was found")
    }
}
