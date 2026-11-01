import AppKit
import BaneySpacesCore

/// The app's side of `CrashLoopGuard`: checked in main.swift before anything else starts, so a
/// crash anywhere in launch counts, and cleared by a clean quit.
enum CrashLoop {
    private static func ledger(render: Bool) -> CrashLedgerFile {
        let d = UserDefaults.standard
        let policy = CrashLoopGuard(limit: d.object(forKey: CrashLoopGuard.limitKey) as? Int,
                                    windowMinutes: d.object(forKey: CrashLoopGuard.windowKey) as? Double)
        let name = render ? CrashLedgerFile.renderFileName : CrashLedgerFile.fileName
        return CrashLedgerFile(url: Spaces.folder.appendingPathComponent(name), policy: policy)
    }

    private static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    private static func shown(_ url: URL) -> String {
        CrashLoopReport.path(url.path, home: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    /// Logs the launch (unless it's the second look after Start Anyway), decides, and logs the
    /// decision with the ledger it came from.
    private static func begin(_ file: CrashLedgerFile, mode: CrashLoopReport.Mode, announce: Bool = true) -> CrashLoopGuard.Decision {
        if announce { Trace.log(CrashLoopReport.launch(build: Updater.buildDescription, mode: mode, pid: getpid())) }
        let decision = file.begin(pid: getpid(), now: Date(), isAlive: isAlive)
        Trace.log(CrashLoopReport.decision(decision, recent: file.read().crashes.count, policy: file.policy,
                                           mode: mode, ledger: shown(file.url)))
        return decision
    }

    private static func ended(_ file: CrashLedgerFile, mode: CrashLoopReport.Mode) {
        Trace.log(CrashLoopReport.ended(pid: getpid(), mode: mode, recorded: file.end(pid: getpid())))
    }

    /// `--render` draws and exits on its own; a loop of it only stops, with a line on stderr.
    static func checkRender() {
        let file = ledger(render: true)
        guard case .stop(let n) = begin(file, mode: .render) else { return }
        FileHandle.standardError.write(Data("BaneySpaces --render crashed \(n) times in \(CrashLoopReport.minutes(file.policy)); not starting. Delete \(file.url.path) to try again.\n".utf8))
        exit(75)
    }

    static func renderEnded() { ended(ledger(render: true), mode: .render) }

    private static var launchMode: CrashLoopReport.Mode {
        CommandLine.arguments.contains("--setup") ? .setup : .normal
    }

    /// After too many crashes: Mission Control, the macOS Dock and the drag to the top go back as
    /// they were (what `--restore-dock` does), then the person picks. Quit leaves it stopped; Start
    /// Anyway forgives the crashes and carries on with the launch.
    static func checkLaunch() {
        let file = ledger(render: false)
        guard case .stop(let n) = begin(file, mode: launchMode) else { return }
        SystemDock.restore()
        SystemTopDrag.restore()
        Trace.log(CrashLoopReport.restored(missionControl: SystemMissionControl.restore()))
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "BaneySpaces crashed \(n) times in \(CrashLoopReport.minutes(file.policy))"
        alert.informativeText = "So it can't keep crashing, it isn't starting now. Mission Control and the macOS Dock are back as they were. Crash reports are in Console › Crash Reports."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Start Anyway")
        guard alert.runModal() == .alertSecondButtonReturn else {
            Trace.log(CrashLoopReport.quit)
            exit(0)
        }
        Trace.log(CrashLoopReport.forgave(file.forgive()))
        _ = begin(file, mode: launchMode, announce: false)
    }

    static func launchEnded() { ended(ledger(render: false), mode: launchMode) }
}
