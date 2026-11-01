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

    /// `--render` draws and exits on its own; a loop of it only stops, with a line on stderr.
    static func checkRender() {
        let file = ledger(render: true)
        guard case .stop(let n) = file.begin(pid: getpid(), now: Date(), isAlive: isAlive) else { return }
        FileHandle.standardError.write(Data("BaneySpaces --render crashed \(n) times in \(minutes(file.policy)); not starting. Delete \(file.url.path) to try again.\n".utf8))
        exit(75)
    }

    static func renderEnded() { ledger(render: true).end(pid: getpid()) }

    /// After too many crashes: Mission Control, the macOS Dock and the drag to the top go back as
    /// they were (what `--restore-dock` does), then the person picks. Quit leaves it stopped; Start
    /// Anyway forgives the crashes and carries on with the launch.
    static func checkLaunch() {
        let file = ledger(render: false)
        guard case .stop(let n) = file.begin(pid: getpid(), now: Date(), isAlive: isAlive) else { return }
        Trace.log("crash loop: \(n) crashes in \(minutes(file.policy)), not starting")
        SystemDock.restore()
        SystemTopDrag.restore()
        SystemMissionControl.restore()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "BaneySpaces crashed \(n) times in \(minutes(file.policy))"
        alert.informativeText = "So it can't keep crashing, it isn't starting now. Mission Control and the macOS Dock are back as they were. Crash reports are in Console › Crash Reports."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Start Anyway")
        guard alert.runModal() == .alertSecondButtonReturn else { exit(0) }
        Trace.log("crash loop: Start Anyway")
        file.forgive()
        _ = file.begin(pid: getpid(), now: Date(), isAlive: isAlive)
    }

    static func launchEnded() { ledger(render: false).end(pid: getpid()) }

    private static func minutes(_ policy: CrashLoopGuard) -> String {
        let m = policy.window / 60
        let text = m == m.rounded() ? String(Int(m)) : String(format: "%.1f", m)
        return m == 1 ? "1 minute" : "\(text) minutes"
    }
}
