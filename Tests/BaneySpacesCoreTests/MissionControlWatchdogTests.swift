import XCTest
@testable import BaneySpacesCore

/// The launch agent that puts macOS's Mission Control back when BaneySpaces stopped running
/// without doing it. The real script and the real uninstall.sh run against a made-up home, with
/// `defaults`, `pgrep`, `launchctl` and `killall` replaced by ones that write a log.
final class MissionControlWatchdogTests: XCTestCase {
    private let fm = FileManager.default
    private var home: URL!
    private var bin: URL!
    private var folder: URL { home.appendingPathComponent("Library/Application Support/BaneySpaces") }
    private var log: URL { home.appendingPathComponent("calls.log") }
    private let record = "{\n    \"com.apple.dock/wvous-tl-corner\" = 2;\n}\n"

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appendingPathComponent("bs-watchdog-\(UUID().uuidString)").resolvingSymlinksInPath()
        bin = home.appendingPathComponent("fakebin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fake("defaults", """
            echo "defaults $*" >> "$FAKE_LOG"
            case "$*" in
              "read com.baney.baneyspaces systemMissionControlSaved") [ -f "$FAKE_RECORD" ] && cat "$FAKE_RECORD" || exit 1 ;;
              "read com.apple.dock mcx-expose-disabled") echo 1 ;;
              "read com.apple.dock wvous-tl-corner") echo 1 ;;
              "read "*) exit 1 ;;
              *) exit 0 ;;
            esac
            """)
        try fake("pgrep", "echo \"pgrep $*\" >> \"$FAKE_LOG\"; [ \"$FAKE_RUNNING\" = 1 ]")
        for name in ["launchctl", "killall"] { try fake(name, "echo \"\(name) $*\" >> \"$FAKE_LOG\"") }
        try MissionControlWatchdog.script.write(to: folder.appendingPathComponent(MissionControlWatchdog.scriptName), atomically: true, encoding: .utf8)
        let uninstall = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("uninstall.sh")
        try fm.copyItem(at: uninstall, to: folder.appendingPathComponent(MissionControlWatchdog.restoreName))
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: home) }

    private func fake(_ name: String, _ body: String) throws {
        let url = bin.appendingPathComponent(name)
        try ("#!/bin/bash\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Writes the heartbeat `age` seconds old (nil: none).
    private func beat(age: TimeInterval?, updating: Bool = false) throws {
        if let age {
            let url = folder.appendingPathComponent(MissionControlWatchdog.heartbeat)
            fm.createFile(atPath: url.path, contents: Data())
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        if updating { fm.createFile(atPath: folder.appendingPathComponent(MissionControlWatchdog.updating).path, contents: Data()) }
    }

    /// Runs the agent's script once; what the fakes were asked to do.
    private func tick(recorded: Bool = true, running: Bool = false) throws -> String {
        let recordFile = home.appendingPathComponent("record.txt")
        if recorded { try record.write(to: recordFile, atomically: true, encoding: .utf8) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [folder.appendingPathComponent(MissionControlWatchdog.scriptName).path]
        p.environment = ["HOME": home.path, "PATH": bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin", "FAKE_LOG": log.path,
                         "FAKE_RECORD": recordFile.path, "FAKE_RUNNING": running ? "1" : "0"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        return (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    }

    func testAFreshHeartbeatLeavesMissionControlOff() throws {
        try beat(age: 5)
        XCTAssertFalse(try tick().contains("killall"))
    }

    func testNoBaneySpacesForAMinutePutsItBack() throws {
        try beat(age: Double(MissionControlWatchdog.limit + 5))
        let calls = try tick()
        XCTAssertTrue(calls.contains("defaults delete com.apple.dock mcx-expose-disabled"), calls)
        XCTAssertTrue(calls.contains("defaults write com.apple.dock wvous-tl-corner -int 2"), calls)
        XCTAssertTrue(calls.contains("killall Dock"), calls)
        XCTAssertTrue(calls.contains("defaults delete com.baney.baneyspaces systemMissionControlSaved"), "the record goes, so the next launch saves what's there then")
        XCTAssertTrue(calls.contains("launchctl bootout"), "the agent has nothing more to watch")
        XCTAssertFalse(fm.fileExists(atPath: folder.appendingPathComponent(MissionControlWatchdog.heartbeat).path))
    }

    func testARunningBaneySpacesIsNeverInterruptedEvenIfQuiet() throws {
        try beat(age: 600)
        XCTAssertFalse(try tick(running: true).contains("killall"))
    }

    func testAnUpdateGetsThirtySecondsNotSixty() throws {
        try beat(age: 40)
        XCTAssertFalse(try tick().contains("killall"), "an ordinary 40 seconds is still waiting")
        try beat(age: 40, updating: true)
        XCTAssertTrue(try tick().contains("killall Dock"), "an update whose new build hasn't started in 30")
        try beat(age: 20, updating: true)
        try? fm.removeItem(at: log)
        XCTAssertFalse(try tick().contains("killall"), "the new build has time")
    }

    func testNothingRecordedOrNeverBeatingIsNothingToDo() throws {
        try beat(age: 600)
        XCTAssertFalse(try tick(recorded: false).contains("killall"), "no record: nothing was changed")
        try? fm.removeItem(at: folder.appendingPathComponent(MissionControlWatchdog.heartbeat))
        XCTAssertFalse(try tick().contains("killall"), "no heartbeat: BaneySpaces never held it off")
    }

    func testThePlistRunsTheScriptOften() {
        let plist = MissionControlWatchdog.plist(folder: "/Users/x/Library/Application Support/BaneySpaces")
        XCTAssertTrue(plist.contains("<string>com.baney.baneyspaces.mc-watchdog</string>"))
        XCTAssertTrue(plist.contains("<string>/Users/x/Library/Application Support/BaneySpaces/mc-watchdog.sh</string>"))
        XCTAssertTrue(plist.contains("<key>StartInterval</key><integer>15</integer>"))
        XCTAssertNoThrow(try PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil))
    }
}
