/// What the Workspace Dock shows: one tile per workspace in use, in number order, plus the
/// workspace you're on even when it's empty. Each tile lists its apps once, in the order their
/// windows sit on the workspace, with how many windows each has there.
public struct DockTile: Equatable, Sendable {
    public struct App: Equatable, Sendable {
        public let key: String
        public let windows: Int
    }

    public let workspace: Int
    public let apps: [App]
    public let isCurrent: Bool

    public var windowCount: Int { apps.reduce(0) { $0 + $1.windows } }
}

public enum DockTiles {
    /// `windows[n]` is the app of each window on workspace `n`, in order (any stable key, such as
    /// a bundle identifier or process id).
    public static func make(current: Int, windows: [Int: [String]]) -> [DockTile] {
        let used = Set(windows.filter { !$0.value.isEmpty }.keys)
        return Workspaces.range.filter { used.contains($0) || $0 == current }.map { n in
            var order: [String] = []
            var counts: [String: Int] = [:]
            for key in windows[n] ?? [] {
                if counts[key] == nil { order.append(key) }
                counts[key, default: 0] += 1
            }
            return DockTile(workspace: n, apps: order.map { DockTile.App(key: $0, windows: counts[$0]!) }, isCurrent: n == current)
        }
    }
}

/// A coding agent the Workspace Dock shows on a tile: one at work, one asking you something or
/// stopped on an error, or one that finished while you weren't looking.
public struct DockAgent: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case working
        /// Finished while you weren't looking.
        case done
        /// Stopped to ask you something: a permission, a question, `baneyspaces notify`.
        case asking
        /// Stopped on an error.
        case failed

        /// What a Deck row shows on the dock: `unseen` is the Deck's "finished while you were
        /// away", `notice` what the agent last said. Asking and failed stay until the agent moves
        /// on, since they wait on you; a plain finish goes once you've looked. Nil for none.
        public static func of(activity: Activity, unseen: Bool, notice: String) -> State? {
            if activity == .working { return .working }
            if notice == AgentEvent.failedMessage { return .failed }
            // A notice only outlives the wait it came with when it's `baneyspaces notify`'s,
            // which also needs you.
            if !notice.isEmpty { return .asking }
            return unseen ? .done : nil
        }

        /// Which one an app or tile shows when it has several: what needs you most comes first.
        public var urgency: Int {
            switch self {
            case .asking: 3
            case .failed: 2
            case .done: 1
            case .working: 0
            }
        }

        /// Not working: it's stopped and waiting on you, so a click goes to it.
        public var needsYou: Bool { self != .working }
    }

    /// The Deck row it runs in, so a click can go to its very tab or split.
    public let id: String
    /// The macOS window it runs in, 0 when the Deck doesn't know it yet.
    public let window: WindowID
    /// The Deck's workspace for it; 0 means the one you're on.
    public let workspace: Int
    public let state: State
    /// "Claude", or the app's name when no hook has named the agent.
    public let name: String
    /// What it's on: the terminal's title without Claude's spinner glyph.
    public let task: String

    public init(id: String = "", window: WindowID, workspace: Int, state: State, name: String, task: String) {
        self.id = id; self.window = window; self.workspace = workspace; self.state = state; self.name = name; self.task = task
    }

    /// The longest task the label shows; a terminal title can run on, and the label doesn't wrap.
    public static let taskLimit = 48

    /// "Claude working: Fix the flaky upload test", for the dock's label.
    public var summary: String {
        let verb = switch state {
        case .working: "working"
        case .done: "finished"
        case .asking: "needs you"
        case .failed: "stopped on an error"
        }
        guard !task.isEmpty else { return "\(name) \(verb)" }
        let short = task.count > Self.taskLimit ? task.prefix(Self.taskLimit - 1).trimmingCharacters(in: .whitespaces) + "…" : task
        return "\(name) \(verb): \(short)"
    }
}

extension DockTiles {
    /// Each agent's workspace: the one holding its window, else the Deck's own (0 being the one
    /// you're on). `windows[n]` is every window on workspace `n`.
    public static func place(_ agents: [DockAgent], windows: [Int: [WindowID]], current: Int) -> [Int: [DockAgent]] {
        var home: [WindowID: Int] = [:]
        for (n, ids) in windows { for id in ids { home[id] = n } }
        var out: [Int: [DockAgent]] = [:]
        for a in agents {
            let n = (a.window != 0 ? home[a.window] : nil) ?? (a.workspace == 0 ? current : a.workspace)
            out[n, default: []].append(a)
        }
        return out
    }

    /// A tile with more apps than it has room for shows the first `shown` and a "+N". An app
    /// with an agent on it takes the place of the last plain app in view, so the agent's badge
    /// is never hidden behind the "+N". The rest keep their order.
    public static func agentsInView(_ keys: [String], flagged: Set<String>, shown: Int) -> [String] {
        guard keys.count > shown + 1 else { return keys }
        var visible = Array(keys.prefix(shown))
        for key in keys.dropFirst(shown) where flagged.contains(key) {
            guard let i = visible.lastIndex(where: { !flagged.contains($0) }) else { break }
            visible[i] = key
        }
        return visible + keys.filter { !visible.contains($0) }
    }
}
