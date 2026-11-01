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

/// An app an agent was lent for a task.
public struct Lend: Codable, Equatable, Sendable {
    public var app: String
    public var bundle: String
    public var since: Date
    public var until: Date
    /// The agent session it belongs to ("" for none): when that session ends, the app is returned.
    public var session: String
}

/// The apps lent right now. Recorded in state.json so a check can read it; given back when the
/// agent says so, when its session ends, or when the time runs out.
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

    /// Lends (or extends) an app.
    public mutating func lend(app: String, bundle: String, session: String, now: Date, for duration: TimeInterval) {
        entries.removeAll { Self.same($0.bundle, bundle) && !bundle.isEmpty || Self.same($0.app, app) }
        entries.append(Lend(app: app, bundle: bundle, since: now, until: now.addingTimeInterval(duration), session: session))
    }

    /// Returns one app; false when it wasn't lent.
    @discardableResult
    public mutating func giveBack(_ name: String) -> Bool {
        let before = entries.count
        entries.removeAll { Self.same($0.app, name) || (!$0.bundle.isEmpty && Self.same($0.bundle, name)) }
        return entries.count != before
    }

    @discardableResult
    public mutating func giveBackAll() -> [Lend] { defer { entries = [] }; return entries }

    /// The agent session ended: everything lent to it goes back. Returns the apps returned.
    @discardableResult
    public mutating func endSession(_ session: String) -> [Lend] {
        guard !session.isEmpty else { return [] }
        let gone = entries.filter { $0.session == session }
        entries.removeAll { $0.session == session }
        return gone
    }

    /// Drops what has timed out. Returns the apps returned.
    @discardableResult
    public mutating func expire(now: Date) -> [Lend] {
        let gone = entries.filter { $0.until <= now }
        entries.removeAll { $0.until <= now }
        return gone
    }

    public func isLent(app: String, bundle: String, now: Date) -> Bool {
        entries.contains { $0.until > now && ((!bundle.isEmpty && Self.same($0.bundle, bundle)) || Self.same($0.app, app)) }
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
/// on the agent workspace, or on a window of an app that is lent right now. Everything else,
/// including a window BaneySpaces doesn't place, is refused.
public enum ScopeGuard {
    public static func check(_ w: HandsWindow, agentWorkspace: Int?, lends: LendBook, now: Date) -> ScopeDecision {
        if let agent = agentWorkspace, w.workspace == agent { return .onAgentWorkspace }
        if lends.isLent(app: w.app, bundle: w.bundle, now: now) { return .lent }
        guard agentWorkspace != nil else {
            return .denied(HandsError(.agentWorkspaceOff,
                                      "there is no agent workspace, and \(w.app) isn't lent",
                                      suggestion: "Run `baneyspaces agent on` for a workspace of your own, or `baneyspaces agent lend \(w.app)` to use this app where it is."))
        }
        let where_ = w.workspace.map { "workspace \($0)" } ?? "a place BaneySpaces doesn't manage"
        return .denied(HandsError(.outsideAgentWorkspace,
                                  "window \(w.id) of \(w.app) is on \(where_), not the agent workspace",
                                  suggestion: "Open a window of it on the agent workspace with `baneyspaces agent open \(w.app)`, or ask to use this one as it is with `baneyspaces agent lend \(w.app)` (and `agent return \(w.app)` when done)."))
    }

    /// The windows an agent may use now.
    public static func visible(_ windows: [HandsWindow], agentWorkspace: Int?, lends: LendBook, now: Date) -> [(window: HandsWindow, scope: ScopeDecision)] {
        windows.compactMap { w in
            let d = check(w, agentWorkspace: agentWorkspace, lends: lends, now: now)
            return d.allowed ? (w, d) : nil
        }
    }
}
