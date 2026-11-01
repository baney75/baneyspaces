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
        try fake("ps", "echo \"$FAKE_PS\"")
        try fake("launchctl", "echo \"launchctl $* plist=$([ -f \"$HOME/Library/LaunchAgents/com.baney.baneyspaces.mc-watchdog.plist\" ] && echo present || echo gone)\" >> \"$FAKE_LOG\"")
        try fake("killall", "echo \"killall $*\" >> \"$FAKE_LOG\"")
        try fm.createDirectory(at: home.appendingPathComponent("Library/LaunchAgents"), withIntermediateDirectories: true)
        try "<plist/>".write(to: home.appendingPathComponent("Library/LaunchAgents/\(MissionControlWatchdog.plistName)"), atomically: true, encoding: .utf8)
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

    /// Writes the heartbeat `age` seconds old (nil: none), holding the process id of a BaneySpaces
    /// that is long gone unless `pid` says otherwise.
    private func beat(age: TimeInterval?, updating: Bool = false, pid: Int32 = 999_999) throws {
        if let age {
            let url = folder.appendingPathComponent(MissionControlWatchdog.heartbeat)
            fm.createFile(atPath: url.path, contents: Data("\(pid)\n".utf8))
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        if updating { fm.createFile(atPath: folder.appendingPathComponent(MissionControlWatchdog.updating).path, contents: Data()) }
    }

    /// Runs the agent's script once; what the fakes were asked to do.
    private func tick(recorded: Bool = true, running: Bool = false, ps: String = "") throws -> String {
        let recordFile = home.appendingPathComponent("record.txt")
        if recorded { try record.write(to: recordFile, atomically: true, encoding: .utf8) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [folder.appendingPathComponent(MissionControlWatchdog.scriptName).path]
        p.environment = ["HOME": home.path, "PATH": bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin", "FAKE_LOG": log.path,
                         "FAKE_RECORD": recordFile.path, "FAKE_RUNNING": running ? "1" : "0", "FAKE_PS": ps]
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

    /// "BaneySpaces 2.app" is how macOS names a second download; the bundle's name is no test of
    /// whether it runs. Its process id, in the heartbeat, is.
    func testARenamedBundleThatIsRunningIsNeverInterrupted() throws {
        try beat(age: 600, pid: getpid())   // alive: this very test
        let calls = try tick(running: false, ps: "/Applications/BaneySpaces 2.app/Contents/MacOS/BaneySpaces")
        XCTAssertFalse(calls.contains("killall"), calls)
        // The process id has been reused by something else: that isn't BaneySpaces.
        try? fm.removeItem(at: log)
        try beat(age: 600, pid: getpid())
        XCTAssertTrue(try tick(running: false, ps: "/usr/bin/other").contains("killall Dock"))
    }

    /// The agent can be the process doing the restore, and unloading it ends the job: the plist is
    /// gone before that, so it can't load again at login.
    func testTheAgentsPlistIsGoneBeforeItIsUnloaded() throws {
        try beat(age: 600)
        let calls = try tick()
        XCTAssertTrue(calls.contains("launchctl bootout"), calls)
        XCTAssertTrue(calls.contains("bootout gui/\(getuid())/com.baney.baneyspaces.mc-watchdog plist=gone"), calls)
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent("Library/LaunchAgents/\(MissionControlWatchdog.plistName)").path))
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

    // MARK: Arming before Mission Control is switched off

    private func installer(restore: Bool = true, launchctl: @escaping ([String]) -> Bool, folder: URL? = nil, plist: URL? = nil) -> WatchdogInstaller {
        let source = home.appendingPathComponent("uninstall-source.sh")
        try? "#!/bin/bash\n".write(to: source, atomically: true, encoding: .utf8)
        return WatchdogInstaller(folder: folder ?? home.appendingPathComponent("armed"),
                                 agentPlist: plist ?? home.appendingPathComponent("armed-agents/\(MissionControlWatchdog.plistName)"),
                                 restoreSource: restore ? source : nil, uid: 501, launchctl: launchctl)
    }

    func testArmedWhenTheFilesAreWrittenAndTheAgentIsLoaded() {
        var calls: [[String]] = []
        var loaded = false
        let i = installer { args in
            calls.append(args)
            if args.first == "bootstrap" { loaded = true; return true }
            return args.first == "print" ? loaded : true
        }
        XCTAssertNil(i.install(pid: 4242))
        XCTAssertEqual(calls.filter { $0.first == "bootstrap" }.count, 1)
        XCTAssertEqual(try? String(contentsOf: i.folder.appendingPathComponent(MissionControlWatchdog.heartbeat), encoding: .utf8), "4242\n")
        XCTAssertTrue(fm.fileExists(atPath: i.folder.appendingPathComponent(MissionControlWatchdog.restoreName).path))
        XCTAssertTrue(fm.fileExists(atPath: i.folder.appendingPathComponent(MissionControlWatchdog.scriptName).path))
        XCTAssertTrue(fm.fileExists(atPath: i.agentPlist.path))
        XCTAssertNil(i.install(pid: 4242), "armed again without loading it twice")
        XCTAssertEqual(calls.filter { $0.first == "bootstrap" }.count, 1)
    }

    func testNotArmedWithoutTheRestoreScript() {
        let i = installer(restore: false) { _ in true }
        XCTAssertNotNil(i.install(pid: 1))
        XCTAssertFalse(fm.fileExists(atPath: i.agentPlist.path), "nothing half-installed")
    }

    func testNotArmedWhenTheFilesCantBeWritten() throws {
        // The folder is where a file is.
        let blocker = home.appendingPathComponent("blocker")
        fm.createFile(atPath: blocker.path, contents: Data())
        XCTAssertNotNil(installer(launchctl: { _ in true }, folder: blocker.appendingPathComponent("inside")).install(pid: 1))
        // The agent's folder is where a file is.
        XCTAssertNotNil(installer(launchctl: { _ in true }, plist: blocker.appendingPathComponent("agents/x.plist")).install(pid: 1))
    }

    func testNotArmedWhenLaunchctlWontLoadIt() {
        let i = installer { args in args.first != "bootstrap" && args.first != "print" }
        let why = i.install(pid: 1)
        XCTAssertNotNil(why)
        XCTAssertTrue(why?.contains("Login Items") == true, "says where to look")
        // It claims to load but isn't there afterwards.
        XCTAssertNotNil(installer { args in args.first != "print" }.install(pid: 1))
    }

    private func takeover() -> (MissionControlTakeoverTests.FakePrefs, MissionControlTakeoverTests.FakeRecord, MissionControlTakeover) {
        let prefs = MissionControlTakeoverTests.FakePrefs(), record = MissionControlTakeoverTests.FakeRecord()
        return (prefs, record, MissionControlTakeover(prefs: prefs, record: record))
    }

    func testMissionControlIsLeftAloneUntilTheSafetyNetIsArmed() {
        let (prefs, record, t) = takeover()
        prefs.values["com.apple.dock/wvous-tl-corner"] = 2
        let result = MissionControlSetup.takeOver(t) { "no uninstaller" }
        XCTAssertEqual(result, .notArmed(reason: "no uninstaller", restored: false))
        XCTAssertNil(prefs.values["com.apple.dock/mcx-expose-disabled"], "not switched off")
        XCTAssertEqual(prefs.values["com.apple.dock/wvous-tl-corner"], 2, "not remapped")
        XCTAssertNil(record.saved)
        XCTAssertTrue(prefs.writes.isEmpty)
    }

    func testMissionControlIsGivenBackWhenTheSafetyNetStopsWorking() {
        let (prefs, record, t) = takeover()
        XCTAssertEqual(MissionControlSetup.takeOver(t) { nil }, .taken(changed: true))
        XCTAssertEqual(prefs.values["com.apple.dock/mcx-expose-disabled"], true)
        // A later launch can't arm it.
        XCTAssertEqual(MissionControlSetup.takeOver(t) { "launchctl said no" }, .notArmed(reason: "launchctl said no", restored: true))
        XCTAssertNil(prefs.values["com.apple.dock/mcx-expose-disabled"])
        XCTAssertNil(record.saved)
    }

    func testTheAgentIsRemovedPlistFirst() {
        var order: [String] = []
        let plist = home.appendingPathComponent("remove-agents/\(MissionControlWatchdog.plistName)")
        try? fm.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: plist.path, contents: Data())
        let i = installer(launchctl: { args in order.append(args.first! + (self.fm.fileExists(atPath: plist.path) ? ":plist" : ":gone")); return true }, plist: plist)
        i.remove()
        XCTAssertEqual(order, ["bootout:gone"])
    }

    /// The agent's script looks in the folder the app writes to.
    func testTheAppAndTheScriptShareOneFolder() throws {
        XCTAssertTrue(MissionControlWatchdog.script.contains("$HOME/Library/Application Support/BaneySpaces\""))
        let app = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/BaneySpaces/MissionControlOverride.swift"), encoding: .utf8)
        XCTAssertTrue(app.contains("folder: Spaces.folder,"), "Spaces.folder is Application Support/BaneySpaces already")
        XCTAssertFalse(app.contains("Spaces.folder.appendingPathComponent(\"BaneySpaces\")"))
    }
}
