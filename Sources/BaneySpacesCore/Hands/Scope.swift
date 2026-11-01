import Foundation

/// A real window as the scope guard sees it.
public struct HandsWindow: Equatable, Codable, Sendable {
    public var id: UInt32
    public var pid: Int32
    public var app: String
    public var bundle: String
    public var title: String
    /// The BaneySpaces workspace it lives on; nil for a window BaneySpaces doesn't place
    /// (a menu, a panel, a window it hasn't seen).
    public var workspace: Int?

    public init(id: UInt32, pid: Int32, app: String, bundle: String = "", title: String = "", workspace: Int?) {
        self.id = id; self.pid = pid; self.app = app; self.bundle = bundle; self.title = title; self.workspace = workspace
    }
}

/// An app lent to agents. Named by process and window ids at lend time, not by name, so a second
/// instance of the same app, or a window it opens later, can't be taken for it.
public struct Lend: Codable, Equatable, Sendable {
    public var app: String
    public var bundle: String
    public var pid: Int32
    public var windows: [UInt32]
    public var since: Date
    public var until: Date
    /// The agent session it belongs to ("" for none): when that session ends, the app is returned.
    public var session: String
}

/// The apps lent right now. Only Donovan lends (the menu, the launcher, or a terminal he types in); the book
/// is recorded in state.json, and an app goes back when he returns it, when its session ends, or when
/// the time runs out.
public struct LendBook: Equatable, Sendable {
    public static let defaultDuration: TimeInterval = 30 * 60
    public static let maxDuration: TimeInterval = 8 * 60 * 60

    public private(set) var entries: [Lend] = []
    public init() {}

    /// "10m", "2h", "90s", or a bare number of minutes. Nil when it isn't one; clamped to 8 hours.
    public static func duration(_ text: String?) -> TimeInterval? {
        guard let t = text?.trimmingCharacters(in: .whitespaces).lowercased(), !t.isEmpty else { return defaultDuration }
        let (digits, unit) = (t.prefix { $0.isNumber || $0 == "." }, t.drop { $0.isNumber || $0 == "." })
        guard let n = Double(digits), n > 0 else { return nil }
        let scale: Double
        switch unit {
        case "", "m", "min": scale = 60
        case "s", "sec": scale = 1
        case "h", "hr": scale = 3600
        default: return nil
        }
        return min(n * scale, maxDuration)
    }

    static func same(_ a: String, _ b: String) -> Bool { a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }

    /// Lends (or renews) one process and the windows it has now.
    public mutating func lend(app: String, bundle: String, pid: Int32, windows: [UInt32], session: String, now: Date, for duration: TimeInterval) {
        entries.removeAll { $0.pid == pid }
        entries.append(Lend(app: app, bundle: bundle, pid: pid, windows: windows.sorted(), since: now, until: now.addingTimeInterval(min(duration, Self.maxDuration)), session: session))
    }

    /// Returns what was lent under this name or bundle id (all its processes); false when nothing was.
    @discardableResult
    public mutating func giveBack(_ name: String) -> Bool {
        let before = entries.count
        entries.removeAll { Self.same($0.app, name) || (!$0.bundle.isEmpty && Self.same($0.bundle, name)) }
        return entries.count != before
    }

    @discardableResult
    public mutating func giveBackAll() -> [Lend] { defer { entries = [] }; return entries }

    /// The agent session ended: everything lent to it goes back. Returns what was returned.
    @discardableResult
    public mutating func endSession(_ session: String) -> [Lend] {
        guard !session.isEmpty else { return [] }
        let gone = entries.filter { $0.session == session }
        entries.removeAll { $0.session == session }
        return gone
    }

    /// Drops what has timed out and returns it. The caller that gets a non-empty answer is the one that
    /// announces the change, so it is announced once whichever path noticed first.
    @discardableResult
    public mutating func expire(now: Date) -> [Lend] {
        let gone = entries.filter { $0.until <= now }
        entries.removeAll { $0.until <= now }
        return gone
    }

    /// What is lent at `now`, without changing the book.
    public func active(now: Date) -> [Lend] { entries.filter { $0.until > now } }

    /// Whether this exact window, of this exact process, is lent.
    public func isLent(_ w: HandsWindow, now: Date) -> Bool {
        entries.contains { $0.until > now && $0.pid == w.pid && $0.windows.contains(w.id) }
    }
}

public enum ScopeDecision: Equatable, Sendable {
    case onAgentWorkspace
    case lent
    case denied(HandsError)

    public var allowed: Bool { if case .denied = self { return false }; return true }
    public var reason: String {
        switch self {
        case .onAgentWorkspace: return "agent_workspace"
        case .lent: return "lent"
        case .denied(let e): return e.code.rawValue
        }
    }
}

/// The one rule that keeps agents off the user's screen: an agent may read or act only on a window
/// on the agent workspace, or on a window that is lent right now and that the user isn't using.
/// Everything else, including a window BaneySpaces doesn't place, is refused.
public enum ScopeGuard {
    public static func check(_ w: HandsWindow, agentWorkspace: Int?, lends: LendBook, now: Date, inUse: Bool = false) -> ScopeDecision {
        if let agent = agentWorkspace, w.workspace == agent {
            // His hands are on this app (in front, or used in the last 30 s): the agent waits, even here.
            if inUse {
                return .denied(HandsError(.inUse, "\(w.app) is in front or was used in the last 30 s",
                                          suggestion: "Wait until Donovan has been away from \(w.app) for 30 seconds.", retry: .safe))
            }
            return .onAgentWorkspace
        }
        if lends.isLent(w, now: now) {
            if inUse {
                return .denied(HandsError(.inUse, "\(w.app) is lent, but you are using it right now",
                                          suggestion: "Wait until Donovan has been away from \(w.app) for 30 seconds, or work on the agent workspace with `baneyspaces agent open \(w.app)`.",
                                          retry: .safe))
            }
            return .lent
        }
        guard agentWorkspace != nil else {
            return .denied(HandsError(.agentWorkspaceOff,
                                      "there is no agent workspace, and \(w.app) isn't lent",
                                      suggestion: "Ask Donovan to run `baneyspaces agent on`, or to lend \(w.app) (the BaneySpaces menu, Lend to Agents)."))
        }
        let where_ = w.workspace.map { "workspace \($0)" } ?? "a place BaneySpaces doesn't manage"
        return .denied(HandsError(.outsideAgentWorkspace,
                                  "window \(w.id) of \(w.app) is on \(where_), not the agent workspace",
                                  suggestion: "Open a window of it on the agent workspace with `baneyspaces agent open \(w.app)`, or ask Donovan to lend this one (you can't lend: he runs `baneyspaces agent lend \(w.app)` or uses the BaneySpaces menu)."))
    }

    /// The windows an agent may use now.
    public static func visible(_ windows: [HandsWindow], agentWorkspace: Int?, lends: LendBook, now: Date, inUse: (Int32) -> Bool = { _ in false }) -> [(window: HandsWindow, scope: ScopeDecision)] {
        windows.compactMap { w in
            let d = check(w, agentWorkspace: agentWorkspace, lends: lends, now: now, inUse: inUse(w.pid))
            return d.allowed ? (w, d) : nil
        }
    }
}
