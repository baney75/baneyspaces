import Foundation

/// A short list of apps an agent action is touching right now. While an app is marked, an
/// activation or focus change from it is the agent's doing, not the user's, so BaneySpaces'
/// follow-the-focus logic leaves it alone instead of switching the user's workspace.
public struct FocusGuard: Equatable, Sendable {
    /// How long a mark lasts after the action that set it.
    public static let window: TimeInterval = 1.0

    private var until: [Int32: Date] = [:]
    public init() {}

    /// Marks `pid` until `now + window`. Marking again only ever extends.
    public mutating func mark(pid: Int32, now: Date, for window: TimeInterval = FocusGuard.window) {
        let end = now.addingTimeInterval(window)
        if let old = until[pid], old > end { return }
        until[pid] = end
    }

    public func isMarked(pid: Int32, now: Date) -> Bool { (until[pid] ?? .distantPast) > now }

    public mutating func prune(now: Date) { until = until.filter { $0.value > now } }
    public var count: Int { until.count }
}

/// The shared guard: the hands mark it on both sides of every action, the focus logic asks it.
public final class AgentActivity: @unchecked Sendable {
    public static let shared = AgentActivity()
    private let lock = NSLock()
    private var guardrail = FocusGuard()
    private let clock: () -> Date

    public init(clock: @escaping () -> Date = Date.init) { self.clock = clock }

    public func mark(pid: Int32, for window: TimeInterval = FocusGuard.window) {
        lock.lock(); defer { lock.unlock() }
        guardrail.prune(now: clock())
        guardrail.mark(pid: pid, now: clock(), for: window)
    }

    /// Whether an agent action touched this app within the last second.
    public func caused(pid: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return guardrail.isMarked(pid: pid, now: clock())
    }
}
