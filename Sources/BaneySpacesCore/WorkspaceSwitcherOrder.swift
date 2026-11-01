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

/// How many workspace tiles fit in one row of the ⌘Tab panel without clipping.
public enum SwitcherLayout: Sendable {
    public static let tileWidth: Double = 108
    public static let spacing: Double = 12
    public static let padding: Double = 28
    /// Typical smaller Mac display content width the panel must stay inside.
    public static let narrowScreen: Double = 1024

    public static func workspaceColumns(
        tileCount: Int,
        maxWidth: Double = narrowScreen,
        tileWidth: Double = tileWidth,
        spacing: Double = spacing,
        padding: Double = padding
    ) -> Int {
        let n = max(tileCount, 1)
        for cols in stride(from: n, through: 1, by: -1) {
            let width = Double(cols) * tileWidth + Double(max(cols - 1, 0)) * spacing + padding
            if width <= maxWidth { return cols }
        }
        return 1
    }

    public static func rowWidth(columns: Int, tileWidth: Double = tileWidth, spacing: Double = spacing, padding: Double = padding) -> Double {
        let cols = max(columns, 1)
        return Double(cols) * tileWidth + Double(max(cols - 1, 0)) * spacing + padding
    }
}
