import Foundation

/// Which agent actions are running, or just finished, so BaneySpaces' follow-the-focus logic can tell an
/// activation an action caused from the user picking an app. An action holds its mark from before it
/// is queued until a short tail after it ends; the mark is for one window of one process, so the user's
/// own windows of the same app are never ignored. An app the agent launched itself is marked for the
/// whole process (every window it makes at launch is the agent's).
public struct FocusGuard: Equatable, Sendable {
    /// How long a mark outlasts the action that set it.
    public static let tail: TimeInterval = 1.5

    struct Key: Hashable, Sendable { var pid: Int32; var window: UInt32 }
    private var running: [Int: Key] = [:]
    private var tailUntil: [Key: Date] = [:]
    private var launchPid: [Int32: Date] = [:]
    struct LaunchMark: Equatable, Sendable { var until: Date; var excluding: Set<Int32> }
    private var launchBundle: [String: LaunchMark] = [:]
    private var nextToken = 1

    public init() {}

    /// An action on `window` of `pid` is starting (before it waits for the engine).
    public mutating func begin(pid: Int32, window: UInt32) -> Int {
        let t = nextToken; nextToken += 1
        running[t] = Key(pid: pid, window: window)
        return t
    }

    /// The action ended: its mark lasts `tail` longer.
    public mutating func end(_ token: Int, now: Date, tail: TimeInterval = FocusGuard.tail) {
        guard let k = running.removeValue(forKey: token) else { return }
        let until = now.addingTimeInterval(tail)
        if (tailUntil[k] ?? .distantPast) < until { tailUntil[k] = until }
    }

    /// The agent started this process (or is about to start this bundle): all its windows are the agent's for a while.
    public mutating func markLaunch(pid: Int32, now: Date, for window: TimeInterval) {
        launchPid[pid] = max(launchPid[pid] ?? .distantPast, now.addingTimeInterval(window))
    }
    /// Until the launch's own process is known (`markLaunch(pid:)` then `clearLaunch(bundle:)`): any process of the
    /// bundle except the ones already running, which are Donovan's.
    public mutating func markLaunch(bundle: String, excluding running: Set<Int32>, now: Date, for window: TimeInterval) {
        launchBundle[bundle] = LaunchMark(until: now.addingTimeInterval(window), excluding: running)
    }
    public mutating func clearLaunch(bundle: String) { launchBundle[bundle] = nil }

    /// Whether an activation of `pid` that put `window` in focus is the agent's doing.
    public func caused(pid: Int32, window: UInt32?, bundle: String?, now: Date) -> Bool {
        if (launchPid[pid] ?? .distantPast) > now { return true }
        if let b = bundle, let l = launchBundle[b], l.until > now, !l.excluding.contains(pid) { return true }
        guard let window else { return false }
        let k = Key(pid: pid, window: window)
        return running.values.contains(k) || (tailUntil[k] ?? .distantPast) > now
    }

    public mutating func prune(now: Date) {
        tailUntil = tailUntil.filter { $0.value > now }
        launchPid = launchPid.filter { $0.value > now }
        launchBundle = launchBundle.filter { $0.value.until > now }
    }
    public var activeCount: Int { running.count }
}

/// The shared guard: the hands begin and end every action here, the focus logic asks.
public final class AgentActivity: @unchecked Sendable {
    public static let shared = AgentActivity()
    private let lock = NSLock()
    private var guardrail = FocusGuard()
    private let clock: () -> Date

    public init(clock: @escaping () -> Date = Date.init) { self.clock = clock }

    /// Holds the mark for the whole action. Always pair with `end`.
    public func begin(pid: Int32, window: UInt32) -> Int {
        lock.lock(); defer { lock.unlock() }
        guardrail.prune(now: clock())
        return guardrail.begin(pid: pid, window: window)
    }

    public func end(_ token: Int) {
        lock.lock(); defer { lock.unlock() }
        guardrail.end(token, now: clock())
    }

    /// The agent is launching this process or bundle.
    public func markLaunch(pid: Int32, for window: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guardrail.markLaunch(pid: pid, now: clock(), for: window)
    }
    public func markLaunch(bundle: String, excluding running: Set<Int32>, for window: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guardrail.markLaunch(bundle: bundle, excluding: running, now: clock(), for: window)
    }
    public func clearLaunch(bundle: String) {
        lock.lock(); defer { lock.unlock() }
        guardrail.clearLaunch(bundle: bundle)
    }

    /// Whether this activation is an agent's: false for any window the agent isn't working on.
    public func caused(pid: Int32, window: UInt32?, bundle: String? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return guardrail.caused(pid: pid, window: window, bundle: bundle, now: clock())
    }
}
