import Foundation

/// Pure ⌘Tab workspace order: current first, then recent, then the rest of the range.
/// Empty workspaces stay in the list so workspaces-mode ⌘Tab can land on them.
public enum WorkspaceSwitcherOrder: Sendable {
    public static func make(current: Int, recent: [Int], range: [Int]) -> [Int] {
        var order: [Int] = []
        if range.contains(current) { order.append(current) }
        for n in recent where n != current && range.contains(n) && !order.contains(n) {
            order.append(n)
        }
        for n in range where !order.contains(n) {
            order.append(n)
        }
        return order
    }
}

/// Whether holding Tab should open the ⌘Tab window bar for the highlighted app.
public enum WindowBarGate: Sendable {
    /// Sum windows across every switcher tile that shares the app's pid (one tile per workspace).
    public static func windowCount(pid: Int32, tiles: [(pid: Int32, windows: Int)]) -> Int {
        tiles.reduce(0) { $0 + ($1.pid == pid ? $1.windows : 0) }
    }

    public static func shouldOpen(windowCount: Int) -> Bool { windowCount > 1 }
}
