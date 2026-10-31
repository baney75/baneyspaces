import Foundation

/// Which scripted apps the Deck engine reads on its own timer. Each read is an AppleScript round
/// trip that wakes the app too: Ghostty and the browser were read at least 24 times a minute
/// with nothing happening (BaneySpaces averaged 0.7% CPU over a day, 2026-10-30). Accessibility already announces
/// what's in front; the timer is only for what it doesn't: a background terminal tab whose agent
/// stops without a hook. So terminals are read often only while an agent is working, and
/// everything else waits for the slow pass or for someone to search (`Engine.refreshAll`).
public enum Sweep {
    /// How often the timer fires.
    public static let tick: TimeInterval = 5
    /// How long any scripted app goes unread at most.
    public static let everything: TimeInterval = 60

    /// Whether a sweep at `now` reads an app in `role`. `lastRead` is when it was last read, by
    /// anything; times are seconds on one clock.
    public static func reads(role: Role, agentWorking: Bool, lastRead: TimeInterval, now: TimeInterval) -> Bool {
        if now - lastRead >= everything { return true }
        return agentWorking && role == .terminal
    }

    /// The apps a sweep at `now` reads, among scripted ones. `lastRead` is the last read whose
    /// script answered: an app that only answered through Accessibility is still due.
    /// The scripted apps an agent's hook event re-reads: the app it runs under, or every terminal
    /// when it didn't say. Never the browser: no agent runs in one. Each hook read every scripted
    /// app twice, so an agent at work kept Ghostty, the browser and Terminal at about 30 reads a
    /// minute each (2026-10-30), most of them for an agent in an app with no script at all.
    public static func forHook<ID>(_ apps: [(id: ID, bundleID: String, role: Role)], eventApp: String) -> [ID] {
        apps.filter { a in
            guard a.role != .browser else { return false }
            return eventApp.isEmpty ? a.role == .terminal : a.bundleID == eventApp
        }.map(\.id)
    }

    public static func due<ID>(_ apps: [(id: ID, role: Role, lastRead: TimeInterval)], agentWorking: Bool, now: TimeInterval) -> [ID] {
        apps.filter { reads(role: $0.role, agentWorking: agentWorking, lastRead: $0.lastRead, now: now) }.map(\.id)
    }
}
