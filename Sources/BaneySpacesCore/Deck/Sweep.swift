import Foundation

/// Which scripted apps the Deck engine reads on its own timer. Each read is an AppleScript round
/// trip that wakes the app too, and reading Ghostty and the browser every 5 s kept BaneySpaces at
/// 3 to 4% CPU on battery with nothing happening (2026-10-30). Accessibility already announces
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
}
