#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// Pure ⌘Tab workspace order. Only workspaces with windows are listed, plus the current one
/// even when it's empty, so the panel always shows where you are (the view marks it).
///
/// The order is most recently used: current first, then `recent` (deduped, occupied only),
/// then any other occupied workspace in number order. Nothing comes from a Set's iteration
/// order, so the same input always gives the same list.
public enum WorkspaceSwitcherOrder: Sendable {
    public static func make(current: Int, recent: [Int], occupied: Set<Int>, range: [Int]) -> [Int] {
        var order: [Int] = []
        if range.contains(current) { order.append(current) }
        for n in recent where occupied.contains(n) && range.contains(n) && !order.contains(n) {
            order.append(n)
        }
        for n in range where occupied.contains(n) && !order.contains(n) {
            order.append(n)
        }
        return order
    }
}

/// What a workspace tile in ⌘Tab says under its icons.
public enum SwitcherTileText: Sendable {
    public static func caption(count: Int, isCurrent: Bool) -> String {
        let windows = count == 0 ? "empty" : count == 1 ? "1 window" : "\(count) windows"
        return isCurrent ? "Here · \(windows)" : windows
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

/// One step through the ⌘Tab list, the window bar, or the arrow keys: all share it, so the
/// highlight always moves to the next card as drawn.
public enum SwitcherSelection: Sendable {
    public static let leftArrow: Int64 = 123
    public static let rightArrow: Int64 = 124
    public static let downArrow: Int64 = 125
    public static let upArrow: Int64 = 126

    /// The index after (or before) `selected` among `count` cards, wrapping at both ends.
    public static func advance(selected: Int, count: Int, forward: Bool) -> Int {
        guard count > 0 else { return 0 }
        let from = ((selected % count) + count) % count
        return (from + (forward ? 1 : count - 1)) % count
    }

    /// Where a fresh gesture starts: the card after the current one, like the app switcher.
    public static func first(count: Int, forward: Bool) -> Int {
        advance(selected: 0, count: count, forward: forward)
    }

    /// Right and down step forward, left and up step back; any other key is not a step.
    public static func arrow(keyCode: Int64) -> Bool? {
        switch keyCode {
        case rightArrow, downArrow: return true
        case leftArrow, upArrow: return false
        default: return nil
        }
    }
}

/// How many workspace tiles fit in one row of the ⌘Tab panel without clipping, and how big
/// the panel is for them. The view draws from these numbers and the panel is framed from them.
public enum SwitcherLayout: Sendable {
    public static let tileWidth: Double = 108
    public static let tileHeight: Double = 128
    public static let spacing: Double = 12
    /// Both sides together: the view pads 14 pt on each.
    public static let padding: Double = 28
    /// Typical smaller Mac display content width the panel must stay inside.
    public static let narrowScreen: Double = 1024

    /// As many columns as fit in `maxWidth`, up to one per tile, so a few tiles stay on one row.
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

    public static func rowCount(tileCount: Int, columns: Int) -> Int {
        let cols = max(columns, 1)
        return max((tileCount + cols - 1) / cols, 1)
    }

    public static func height(rows: Int, tileHeight: Double = tileHeight, spacing: Double = spacing, padding: Double = padding) -> Double {
        let r = max(rows, 1)
        return Double(r) * tileHeight + Double(r - 1) * spacing + padding
    }

    /// The tile indices on each row, in order.
    public static func rows(tileCount: Int, columns: Int) -> [Range<Int>] {
        let cols = max(columns, 1)
        return stride(from: 0, to: tileCount, by: cols).map { $0..<min($0 + cols, tileCount) }
    }

    /// The whole panel for `tileCount` workspace tiles laid out inside `maxWidth`.
    public static func panelSize(tileCount: Int, maxWidth: Double = narrowScreen) -> CGSize {
        let cols = workspaceColumns(tileCount: tileCount, maxWidth: maxWidth)
        return CGSize(width: rowWidth(columns: cols),
                      height: height(rows: rowCount(tileCount: tileCount, columns: cols)))
    }
}

/// Where the ⌘Tab panel goes: centered on the display you're using and never past its edges.
public enum SwitcherPanelFrame: Sendable {
    /// The visible frame of the display under the pointer, else of `main`, else the first one.
    public static func activeVisibleFrame(pointer: CGPoint, screens: [(frame: CGRect, visible: CGRect)], main: Int? = nil) -> CGRect? {
        if let s = screens.first(where: { $0.frame.contains(pointer) }) { return s.visible }
        if let main, screens.indices.contains(main) { return screens[main].visible }
        return screens.first?.visible
    }

    /// `content` centered in `visibleFrame`, shrunk to fit if it's bigger, and kept fully inside.
    public static func center(content: CGSize, visibleFrame v: CGRect) -> CGRect {
        let w = min(max(content.width, 0), v.width)
        let h = min(max(content.height, 0), v.height)
        let x = min(max((v.midX - w / 2).rounded(.down), v.minX), v.maxX - w)
        let y = min(max((v.midY - h / 2).rounded(.down), v.minY), v.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
