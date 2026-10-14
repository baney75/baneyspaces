import Foundation

/// One report from a coding agent's hook. Claude Code sends its hook JSON on stdin; `ghostdeck hook`
/// adds the tty it ran under and forwards it here. Any other agent can send the same shape with
/// `ghostdeck event --state working|waiting|idle|end`.
public struct AgentEvent: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case working, waiting, idle, end }

    public var agent: String
    public var session: String
    public var cwd: String
    public var tty: String
    /// The app the agent runs under, from `__CFBundleIdentifier` (Ghostty, Terminal, Grok Bot…).
    /// Narrows which rows it can be, so two terminals in one folder in different apps can't mix up.
    public var app: String
    public var state: State
    /// Why it's waiting ("Claude needs your permission to use Bash"), when the agent says.
    public var message: String
    public var at: Double

    public init(agent: String, session: String, cwd: String, tty: String, app: String = "", state: State, message: String = "", at: Double) {
        self.agent = agent; self.session = session; self.cwd = cwd; self.tty = tty; self.app = app; self.state = state
        self.message = message; self.at = at
    }

    /// Reads a hook payload from Claude Code or Grok (which sends Claude's event names in
    /// `hook_event_name` and camelCase keys elsewhere). Nil for events that don't change what the
    /// session is doing.
    public static func hook(_ json: [String: Any], agent: String, tty: String, app: String = "", at: Double) -> AgentEvent? {
        guard let name = json["hook_event_name"] as? String ?? json["hookEventName"] as? String else { return nil }
        let state: State
        var message = ""
        switch name {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "user_prompt_submit", "post_tool_use": state = .working
        case "Stop", "StopCancelled", "stop", "stop_cancelled": state = .waiting
        case "StopFailure", "stop_failure":
            state = .waiting
            message = "Stopped on an API error"
        case "Notification", "notification":
            state = .waiting
            message = json["message"] as? String ?? ""
        case "SessionStart", "session_start": state = .idle
        case "SessionEnd", "session_end":
            // A Grok subagent's own teardown isn't the session ending.
            if json["subagentType"] != nil { return nil }
            state = .end
        default: return nil
        }
        let session = json["session_id"] as? String ?? json["sessionId"] as? String ?? ""
        return AgentEvent(agent: agent, session: session, cwd: json["cwd"] as? String ?? "", tty: tty, app: app,
                          state: state, message: message, at: at)
    }

    public static func claude(_ json: [String: Any], tty: String, at: Double) -> AgentEvent? {
        hook(json, agent: "claude", tty: tty, at: at)
    }
}

/// Live agent sessions and which sidebar row each one runs in. A tty match is exact (Terminal,
/// iTerm). Ghostty doesn't report ttys, so a session binds to the one terminal in its folder; when
/// several share the folder, the one whose title agrees with the session's state wins, and the
/// binding sticks once made.
public struct AgentSessions: Equatable, Sendable {
    public private(set) var sessions: [String: AgentEvent] = [:]
    public private(set) var binding: [String: String] = [:]

    public init() {}

    public mutating func apply(_ e: AgentEvent) {
        let key = e.agent + ":" + e.session
        if e.state == .end {
            sessions[key] = nil
            binding[key] = nil
        } else {
            sessions[key] = e
        }
    }

    /// Forgets sessions silent for longer than `maxAge` seconds (an agent killed without SessionEnd).
    public mutating func expire(now: Double, maxAge: Double = 6 * 3600) {
        for (k, e) in sessions where now - e.at > maxAge { sessions[k] = nil; binding[k] = nil }
    }

    /// Binds sessions to `items` and returns each bound item's state, keyed by item ID.
    public mutating func resolve(_ items: [Item]) -> [String: AgentEvent] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [String: AgentEvent] = [:]
        var taken = Set<String>()
        // Keep bindings whose row still exists, in the same folder or tty.
        for (key, itemID) in binding {
            guard let e = sessions[key], let item = byID[itemID], Self.matches(item, e) else { binding[key] = nil; continue }
            taken.insert(itemID)
            out[itemID] = e
        }
        for (key, e) in sessions.sorted(by: { $0.value.at > $1.value.at }) where binding[key] == nil {
            let inApp = items.filter { e.app.isEmpty || $0.bundleID == e.app }
            let candidates = inApp.filter { $0.kind == .terminal && !taken.contains($0.id) && Self.matches($0, e) }
            let exact = candidates.filter { !e.tty.isEmpty && $0.tty == e.tty }
            var pick: Item?
            if exact.count == 1 { pick = exact[0] }
            else if candidates.count == 1 { pick = candidates[0] }
            else {
                let agreeing = candidates.filter { Self.agrees($0.activity, e.state) && $0.activity != .shell }
                if agreeing.count == 1 { pick = agreeing[0] }
            }
            // An agent inside a desktop app (Grok Bot, say) has no terminal: its app's window stands in.
            if pick == nil, !e.app.isEmpty, candidates.isEmpty {
                let windows = inApp.filter { $0.kind == .window && !taken.contains($0.id) }
                pick = windows.first { $0.focused } ?? (windows.count == 1 ? windows[0] : nil)
            }
            guard let p = pick else { continue }
            binding[key] = p.id
            taken.insert(p.id)
            out[p.id] = e
        }
        return out
    }

    static func matches(_ item: Item, _ e: AgentEvent) -> Bool {
        if !e.app.isEmpty && item.bundleID != e.app { return false }
        if item.kind == .window { return true }
        if !e.tty.isEmpty && !item.tty.isEmpty { return item.tty == e.tty }
        guard !e.cwd.isEmpty else { return false }
        return item.directory == e.cwd
    }

    static func agrees(_ a: Activity, _ s: AgentEvent.State) -> Bool {
        switch s {
        case .working: return a == .working
        case .waiting, .idle: return a == .waiting
        case .end: return false
        }
    }
}

extension Activity {
    /// What a row shows when a hook has spoken for it.
    public init(_ s: AgentEvent.State) {
        switch s {
        case .working: self = .working
        case .waiting, .idle: self = .waiting
        case .end: self = .shell
        }
    }
}
