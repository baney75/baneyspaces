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
            message = failedMessage
        case "Notification", "notification":
            message = json["message"] as? String ?? ""
            // Only a question waits on you. The rest (Claude's "waiting for your input" a minute
            // after it finished, a sign-in that worked) say nothing new, and passing one on would
            // wipe the question it may be reminding you of.
            let type = json["notification_type"] as? String ?? json["notificationType"] as? String ?? ""
            guard type.isEmpty ? !message.localizedCaseInsensitiveContains("waiting for your input") : asking.contains(type) else { return nil }
            state = .waiting
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

    /// Notification types that ask you something; an older Claude sends none.
    public static let asking: Set<String> = ["permission_prompt", "elicitation_dialog"]

    /// The notice a session that stopped on an API error carries.
    public static let failedMessage = "Stopped on an API error"

    public static func claude(_ json: [String: Any], tty: String, at: Double) -> AgentEvent? {
        hook(json, agent: "claude", tty: tty, at: at)
    }
}

/// Live agent sessions and which Deck row each one runs in.
///
/// Exact evidence binds at once: the session's tty (Terminal, iTerm) or its folder. Ghostty
/// reports neither while Claude runs, so the rest bind by correlation: after each hook event
/// settles, the terminals whose title glyph agrees with it (◐ for working, ✳ for waiting) stay
/// candidates. Two or three events narrow that to one terminal, even with several sessions
/// running, and the binding then sticks for as long as the row exists.
public struct AgentSessions: Equatable, Sendable {
    public private(set) var sessions: [String: AgentEvent] = [:]
    public private(set) var binding: [String: String] = [:]
    /// Rows still in the running for an unbound session, and the event they were last narrowed by.
    public private(set) var candidates: [String: Set<String>] = [:]
    /// The question each session last showed on an app's window while you were looking at it.
    private var answered: [String: Double] = [:]
    private var narrowedBy: [String: Double] = [:]
    /// How long a title takes to catch up with a hook event before it's compared.
    public static let settle = 0.5

    public init() {}

    public mutating func apply(_ e: AgentEvent) {
        let key = e.agent + ":" + e.session
        if e.state == .end {
            forget(key)
        } else {
            sessions[key] = e
        }
    }

    private mutating func forget(_ key: String) {
        sessions[key] = nil; binding[key] = nil; candidates[key] = nil; narrowedBy[key] = nil; answered[key] = nil
    }

    /// Forgets sessions silent for longer than `maxAge` seconds (an agent killed without SessionEnd).
    /// Whether it forgot any.
    @discardableResult
    public mutating func expire(now: Double, maxAge: Double = 6 * 3600) -> Bool {
        let old = sessions.filter { now - $0.value.at > maxAge }.keys
        for k in old { forget(k) }
        return !old.isEmpty
    }

    /// Binds sessions to `items` and returns each bound item's state, keyed by item ID.
    public mutating func resolve(_ items: [Item], now: Double = .infinity) -> [String: AgentEvent] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [String: AgentEvent] = [:]
        var taken = Set<String>()
        // An agent app's window is shared: every session in the app reports to it (T3 Code runs a
        // dozen in one window), so it never counts as taken.
        func show(_ e: AgentEvent, on item: Item) {
            if Self.shared(item), let other = out[item.id], !outranks(e, other, now: now) { return }
            if !Self.shared(item) { taken.insert(item.id) }
            out[item.id] = e
        }
        for (key, itemID) in binding {
            guard let e = sessions[key], let item = byID[itemID], Self.compatible(item, e) else { binding[key] = nil; continue }
            show(e, on: item)
        }
        for (key, e) in sessions.sorted(by: { $0.value.at > $1.value.at }) where binding[key] == nil {
            let inApp = items.filter { e.app.isEmpty || $0.bundleID == e.app }
            let pool = inApp.filter { $0.kind == .terminal && !taken.contains($0.id) && Self.compatible($0, e) }
            var pick: Item?
            let exact = pool.filter { Self.exact($0, e) }
            if exact.count == 1 { pick = exact[0] }
            else if pool.count == 1 && (exact.count == 1 || !e.cwd.isEmpty || !e.tty.isEmpty) && Self.known(pool[0]) { pick = pool[0] }
            else if now - e.at >= Self.settle, narrowedBy[key] != e.at {
                // Correlate: keep the rows whose title agrees with what the hook just said.
                let agreeing = Set((exact.isEmpty ? pool : exact).filter { $0.activity != .shell && Self.agrees($0.activity, e.state) }.map(\.id))
                let narrowed = (candidates[key] ?? agreeing).intersection(agreeing)
                candidates[key] = narrowed.isEmpty ? agreeing : narrowed
                narrowedBy[key] = e.at
                if candidates[key]?.count == 1, let id = candidates[key]?.first { pick = byID[id] }
            } else if let c = candidates[key], c.count == 1, let id = c.first, !taken.contains(id) {
                pick = byID[id]
            }
            // An agent inside a desktop app (Grok Bot, say) has no terminal: its app's window stands in.
            if pick == nil, !e.app.isEmpty, pool.isEmpty {
                let windows = inApp.filter { $0.kind == .window && !taken.contains($0.id) }
                pick = windows.first { $0.focused } ?? (windows.count == 1 ? windows[0] : nil)
            }
            guard let p = pick else { continue }
            binding[key] = p.id
            candidates[key] = nil
            show(e, on: p)
        }
        // A question on a window you're looking at is answered, or let be: it stops outranking work.
        for (id, e) in out where e.state == .waiting && !e.message.isEmpty {
            if let item = byID[id], Self.shared(item), item.focused { answered[e.agent + ":" + e.session] = e.at }
        }
        return out
    }

    /// A window that stands in for every session of an agent app (T3 Code, Grok Bot). Any other
    /// app's window, a terminal's above all, holds one session, like a terminal row.
    static func shared(_ item: Item) -> Bool { item.kind == .window && item.role == .agent }

    /// A working report with nothing after it for this long no longer counts on a row whose title
    /// can't say otherwise (an agent app's window, a terminal without Claude's status glyph). A turn stopped from T3 Code or with Esc sends no hook, and
    /// its spinner stayed on the dock for hours (Donovan, 2026-10-28). Long enough for a slow tool:
    /// a foreground Bash call times out at ten minutes.
    public static let stale: Double = 15 * 60
    /// How long a terminal's title must keep saying Claude is idle (✳), with no report since, before
    /// it wins over a working report. Claude retitles the moment it stops, so an idle title that
    /// lasts means a turn that ended without a hook.
    public static let titleWins: Double = 5

    /// Which of two sessions sharing an app's window it shows: a question you haven't looked at,
    /// then work that isn't stale, then the latest report.
    func outranks(_ a: AgentEvent, _ b: AgentEvent, now: Double) -> Bool {
        func weight(_ e: AgentEvent) -> Int {
            if e.state == .waiting && !e.message.isEmpty { return answered[e.agent + ":" + e.session] == e.at ? 0 : 2 }
            return e.state == .working && now - e.at <= Self.stale ? 1 : 0
        }
        let wa = weight(a), wb = weight(b)
        return wa != wb ? wa > wb : a.at > b.at
    }

    /// What row `item` shows for its session's latest report `e`: what the report says, unless the
    /// row shows the work stopped since. `item.activity` is what its title says; `idleSince` is when
    /// the title last started saying Claude is idle.
    public static func activity(_ item: Item, _ e: AgentEvent, now: Double, idleSince: Double? = nil) -> Activity {
        guard e.state == .working else { return Activity(e.state) }
        switch item.activity {
        case .waiting:
            if let since = idleSince, now - since > titleWins, now - e.at > titleWins { return .waiting }
        case .shell:
            if now - e.at > stale { return .shell }
        case .working:
            break
        }
        return .working
    }

    /// What "finished while you were away" should take a row's activity as. Work that only went
    /// stale is still work, so a turn that does end later counts as a finish. A stop only Claude's
    /// title saw isn't one: it was interrupted, or a background agent's late hook keeps reporting
    /// work after the turn ended, and each would flag the row (and toast) again.
    public static func forAttention(_ shown: Activity, _ e: AgentEvent?) -> Activity {
        guard e?.state == .working else { return shown }
        switch shown {
        case .shell: return .working
        case .waiting: return .shell
        case .working: return .working
        }
    }


    /// Nothing known about the row rules the session out: same app, and the same tty and folder
    /// wherever both sides know them.
    static func compatible(_ item: Item, _ e: AgentEvent) -> Bool {
        if !e.app.isEmpty && item.bundleID != e.app { return false }
        if item.kind == .window { return true }
        if !e.tty.isEmpty && !item.tty.isEmpty && item.tty != e.tty { return false }
        if !e.cwd.isEmpty && !item.directory.isEmpty && item.directory != e.cwd { return false }
        return true
    }

    /// The row's own tty or folder says it's this session's.
    public static func exact(_ item: Item, _ e: AgentEvent) -> Bool {
        if !e.tty.isEmpty && item.tty == e.tty { return true }
        return item.tty.isEmpty && !e.cwd.isEmpty && item.directory == e.cwd
    }

    static func known(_ item: Item) -> Bool { !item.tty.isEmpty || !item.directory.isEmpty }

    static func agrees(_ a: Activity, _ s: AgentEvent.State) -> Bool {
        switch s {
        case .working: return a == .working
        case .waiting, .idle: return a == .waiting
        case .end: return false
        }
    }
}


/// When each row's title started saying Claude is idle (✳), to tell a title that stayed idle from
/// one read that hadn't caught up.
public struct IdleTitles: Equatable, Sendable {
    private var since: [String: Double] = [:]

    public init() {}

    /// `rows` with their title's activity, before any hook speaks for them.
    public mutating func update(_ rows: [Item], now: Double) {
        var next: [String: Double] = [:]
        for r in rows where r.activity == .waiting { next[r.id] = since[r.id] ?? now }
        since = next
    }

    public func since(_ id: String) -> Double? { since[id] }
}

/// Which session each agent app's window showed at the last merge. A window that changes to
/// another session (one went stale, a newer one reported) hasn't seen anyone finish: the session it
/// now shows may have stopped long ago, so for that merge Attention sees no change of state.
public struct ShownSessions: Equatable, Sendable {
    private var shown: [String: String] = [:]

    public init() {}

    /// `activity` as Attention should take it for row `id`, now showing report `e`.
    public mutating func attention(_ id: String, _ e: AgentEvent?, _ activity: Activity) -> Activity {
        guard let e else { shown[id] = nil; return activity }
        let key = e.agent + ":" + e.session
        defer { shown[id] = key }
        guard let before = shown[id], before != key else { return activity }
        return .shell
    }

    public mutating func keep(_ ids: Set<String>) { shown = shown.filter { ids.contains($0.key) } }
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

/// What a row's agent is asking, until you've looked at it. Looking means you answered, or chose
/// not to; either way the dock stops asking. An interrupted turn sends no hook, so without this a
/// "?" could stay up for good (r1 F3).
public struct AnsweredQuestions: Equatable, Sendable {
    private var seen: [String: Double] = [:]

    public init() {}

    /// The notice row `id` shows for its session's latest event `e`.
    /// Kept per session as well as row: an agent app's window shows several sessions in turn.
    public mutating func notice(for id: String, _ e: AgentEvent, focused: Bool) -> String {
        guard e.state == .waiting, !e.message.isEmpty else { return "" }
        let key = id + "|" + e.agent + ":" + e.session
        if focused { seen[key] = e.at }
        return seen[key] == e.at ? "" : e.message
    }

    /// Forgets rows no session is bound to any more.
    public mutating func keep(_ ids: Set<String>) {
        seen = seen.filter { k, _ in ids.contains(String(k.prefix { $0 != "|" })) }
    }
}
