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
