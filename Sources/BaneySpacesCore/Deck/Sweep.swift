import Foundation

/// Which scripted apps the Deck engine reads on its own. Each read is an AppleScript round trip
/// that wakes the app too: Ghostty and the browser were read at least 24 times a minute with
/// nothing happening (BaneySpaces averaged 0.7% CPU over a day, 2026-10-30). Accessibility already
/// announces what's in front, and the launcher reads every app as it opens. The timer is only for
/// what neither sees: a background terminal tab whose agent stops without a hook. So terminals are
/// read often only while an agent in a terminal is working, and everything else waits for the
/// slow pass. An agent with no hooks that starts in a background tab can take about a minute (up
/// to `everything` plus a tick and the timer's tolerance, 65 s) to show as working; one you start
/// by typing is in front, where Accessibility sees it at once.
public enum Sweep {
    /// How often the timer fires.
    public static let tick: TimeInterval = 5
    /// How long any scripted app goes unread at most.
    public static let everything: TimeInterval = 60

    /// Whether a sweep at `now` reads an app in `role`. `lastRead` is the last time a script was
    /// sent to it, answered or not: an app that keeps failing (a hung Ghostty times out every
    /// read) waits for the slow pass instead of being tried again every tick. `agentWorking` is
    /// whether this app's own rows have an agent at work. Times are seconds on one clock. The slow pass is due half a tick early, so a
    /// timer that fires a little late (it has tolerance) doesn't push it a whole tick later.
    public static func reads(role: Role, agentWorking: Bool, lastRead: TimeInterval, now: TimeInterval) -> Bool {
        if now - lastRead >= everything - tick / 2 { return true }
        return agentWorking && role == .terminal
    }

    /// The apps a sweep at `now` reads, among scripted ones, each with whether an agent is at
    /// work in its own rows and whether its last script answered. One whose script was never sent
    /// (no permission yet) stays due; one whose last script failed loses the fast path until the
    /// slow pass, agent or not.
    public static func due<ID>(_ apps: [(id: ID, role: Role, lastRead: TimeInterval, agentWorking: Bool, lastOK: Bool)],
                               now: TimeInterval) -> [ID] {
        apps.filter {
            reads(role: $0.role, agentWorking: $0.agentWorking && !backingOff(lastTried: $0.lastRead, lastOK: $0.lastOK, now: now),
                  lastRead: $0.lastRead, now: now)
        }.map(\.id)
    }

    /// Whether an app whose last script failed is still waiting out the slow pass. No read script
    /// is sent to it until then, whoever asks: `Engine.refresh` checks this itself, so a timer tick,
    /// a hook, an Accessibility notification, an activation and a re-run of a read that went dirty
    /// all build its rows from Accessibility alone. The first read after the slow pass is the retry.
    /// Scripts a person asked for (focus, close, send) still go through.
    public static func backingOff(lastTried: TimeInterval, lastOK: Bool, now: TimeInterval) -> Bool {
        !lastOK && now - lastTried < everything - tick / 2
    }

    /// The snapshot an app's rows are built from. The one this read's script answered, else the last
    /// good one while the app is backing off or its script just failed, so a hung Ghostty or Terminal
    /// keeps its tabs on screen (paired with fresh windows) instead of dropping to bare windows. Never
    /// after macOS refused the script: the permission is gone, and so is the right to those rows.
    public static func snapshotToShow<S>(answered: S?, last: S?, backingOff: Bool, scriptable: Bool, refused: Bool) -> S? {
        if let answered { return answered }
        return !refused && (backingOff || scriptable) ? last : nil
    }

    /// The time a read script counts as tried. A failure counts from when it ended, so a script that
    /// ran for its whole timeout still waits out the slow pass; a success from when it started.
    public static func triedAt<T>(started: T, finished: T, ok: Bool) -> T { ok ? started : finished }

    /// The scripted apps an agent's hook event re-reads: the one whose rows carry its terminal
    /// (`tty`), else the app it runs under, else every terminal. Never the browser: no agent runs
    /// in one. Each hook read every scripted app twice, so an agent at work kept Ghostty, the
    /// browser and Terminal at about 30 reads a minute each (2026-10-30), most of them for an
    /// agent in an app with no script at all.
    ///
    /// An event with no tty comes from a process with no terminal (a headless `claude -p`, a
    /// subagent, a job): `__CFBundleIdentifier` still names Terminal because it passes down from
    /// the app, but Terminal and iTerm rows are bound by tty (`byTTY`), so no row there can be
    /// that agent's and a read can't show one. Only apps that bind by folder (Ghostty) are read.
    public static func forHook<ID>(_ apps: [(id: ID, bundleID: String, role: Role, byTTY: Bool, ttys: Set<String>)],
                                   eventApp: String, tty: String = "") -> [ID] {
        let candidates = apps.filter { $0.role != .browser && (!tty.isEmpty || !$0.byTTY) }
        if !tty.isEmpty {
            let owners = candidates.filter { $0.ttys.contains(tty) }
            if !owners.isEmpty { return owners.map(\.id) }
        }
        return candidates.filter { eventApp.isEmpty ? $0.role == .terminal : $0.bundleID == eventApp }.map(\.id)
    }
}
