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
    /// work in its own rows. One whose script was never sent (no permission yet) stays due.
    public static func due<ID>(_ apps: [(id: ID, role: Role, lastRead: TimeInterval, agentWorking: Bool)], now: TimeInterval) -> [ID] {
        apps.filter { reads(role: $0.role, agentWorking: $0.agentWorking, lastRead: $0.lastRead, now: now) }.map(\.id)
    }

    /// The scripted apps an agent's hook event re-reads: the one whose rows carry its terminal
    /// (`tty`), else the app it runs under, else every terminal. Never the browser: no agent runs
    /// in one. Each hook read every scripted app twice, so an agent at work kept Ghostty, the
    /// browser and Terminal at about 30 reads a minute each (2026-10-30), most of them for an
    /// agent in an app with no script at all.
    public static func forHook<ID>(_ apps: [(id: ID, bundleID: String, role: Role, ttys: Set<String>)],
                                   eventApp: String, tty: String = "") -> [ID] {
        let candidates = apps.filter { $0.role != .browser }
        if !tty.isEmpty {
            let owners = candidates.filter { $0.ttys.contains(tty) }
            if !owners.isEmpty { return owners.map(\.id) }
        }
        return candidates.filter { eventApp.isEmpty ? $0.role == .terminal : $0.bundleID == eventApp }.map(\.id)
    }
}
