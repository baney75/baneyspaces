import Foundation

/// The lines `trace.log` and the unified log (subsystem com.baney.baneyspaces) get about each
/// launch and the crash-loop guard, so a crash loop can be read back afterwards: which build
/// started, how, what the guard decided and from which ledger, and what it gave back. They hold
/// counts, pids, the build and a path under the home folder written as `~`, never window titles
/// or user names. Kept here, apart from AppKit, so the text is pinned by `CrashLoopReportTests`.
public enum CrashLoopReport {
    public enum Mode: String {
        case normal, render, setup
    }

    /// "launch: BaneySpaces 0.2.1 (abc1234), normal, pid 412".
    public static func launch(build: String, mode: Mode, pid: Int32) -> String {
        "launch: BaneySpaces \(build), \(mode.rawValue), pid \(pid)"
    }

    /// What `CrashLedgerFile.begin` decided. `recent` is the crashes still in the window after it
    /// (the ledger's `crashes` once `begin` has written it).
    public static func decision(_ decision: CrashLoopGuard.Decision, recent: Int, policy: CrashLoopGuard,
                                mode: Mode, ledger: String) -> String {
        let window = minutes(policy)
        switch decision {
        case .start where policy.limit <= 0:
            return "crash loop: start (\(mode.rawValue)), \(recent) crashes in \(window), guard off (limit 0), ledger \(ledger)"
        case .start:
            return "crash loop: start (\(mode.rawValue)), \(recent) of \(policy.limit) crashes in \(window), ledger \(ledger)"
        case .stop(let n):
            return "crash loop: stop (\(mode.rawValue)), \(n) crashes in \(window) (limit \(policy.limit)), not starting, ledger \(ledger)"
        }
    }

    /// After a stop gave back what BaneySpaces takes. `missionControl` is whether
    /// `SystemMissionControl.restore` changed any saved setting (Dock switch or hot corners).
    /// False means no saved setting changed — Mission Control may still be off if the person or
    /// a managed Mac left it that way, or if there was no record to undo.
    public static func restored(missionControl: Bool) -> String {
        "crash loop: Dock and drag to the top restored, Mission Control "
            + (missionControl ? "saved settings restored" : "no saved settings changed")
    }

    public static let quit = "crash loop: Quit, staying stopped"

    public static func forgave(_ crashes: Int) -> String {
        "crash loop: Start Anyway, \(crashes) crashes forgiven"
    }

    /// A clean quit. `recorded` is false when the run wasn't in the ledger (it was already ended).
    public static func ended(pid: Int32, mode: Mode, recorded: Bool) -> String {
        "crash loop: clean quit (\(mode.rawValue)), pid \(pid) " + (recorded ? "cleared from the ledger" : "was not in the ledger")
    }

    /// "5 minutes", "1 minute", "2.5 minutes".
    public static func minutes(_ policy: CrashLoopGuard) -> String {
        let m = policy.window / 60
        let text = m == m.rounded() ? String(Int(m)) : String(format: "%.1f", m)
        return m == 1 ? "1 minute" : "\(text) minutes"
    }

    /// `path` with the home folder written as `~`, so the log doesn't carry the user name.
    public static func path(_ path: String, home: String) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + String(path.dropFirst(home.count))
    }
}
