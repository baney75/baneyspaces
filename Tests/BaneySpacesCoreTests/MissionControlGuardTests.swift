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
        XCTAssertGreaterThanOrEqual(app.components(separatedBy: "SystemMissionControl.restore()").count - 1, 4,
                                    "syncMissionControl, startWhenTrusted, stillTrusted and --restore-dock")
        let restoreDock = try XCTUnwrap(app.range(of: "\"--restore-dock\""))
        XCTAssertTrue(app[restoreDock.upperBound...].prefix(400).contains("SystemMissionControl.restore()"))
        XCTAssertNotNil(app.range(of: "missionControlKeys.start()\n        syncMissionControl()"), "start() syncs it right after the key watcher")
    }

    /// The swipe and the corners are behind the same switch and open the overview, not toggle it blindly.
    func testTheSwipeAndTheCornersOpenTheOverview() throws {
        let app = try source("Sources/BaneySpaces/AppDelegate.swift")
        let sync = try XCTUnwrap(app.range(of: "private func syncMissionControl()").map { app[$0.lowerBound...].prefix(700) })
        XCTAssertTrue(sync.contains("trackpadSwipe.start()") && sync.contains("hotCorners.start("))
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
}
