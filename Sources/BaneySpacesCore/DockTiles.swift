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

/// A coding agent the Workspace Dock shows on a tile: one at work, or one that finished while
/// you weren't looking.
public struct DockAgent: Equatable, Sendable {
    public enum State: Equatable, Sendable { case working, done }

    /// The macOS window it runs in, 0 when the Deck doesn't know it yet.
    public let window: WindowID
    /// The Deck's workspace for it; 0 means the one you're on.
    public let workspace: Int
    public let state: State
    /// "Claude", or the app's name when no hook has named the agent.
    public let name: String
    /// What it's on: the terminal's title without Claude's spinner glyph.
    public let task: String

    public init(window: WindowID, workspace: Int, state: State, name: String, task: String) {
        self.window = window; self.workspace = workspace; self.state = state; self.name = name; self.task = task
    }

    /// "Claude working: Fix the flaky upload test", for the dock's label.
    public var summary: String {
        let verb = state == .working ? "working" : "finished"
        return task.isEmpty ? "\(name) \(verb)" : "\(name) \(verb): \(task)"
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
