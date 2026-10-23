import CoreGraphics
import Foundation

/// Ranks deck rows for the switcher with the launcher's own matcher, so both search alike.
public enum DeckRank {
    /// `items` best first, dropping the ones that don't match. Ties keep their order.
    public static func rank<T>(_ query: String, _ items: [T], text: (T) -> [String]) -> [T] {
        guard !Fuzzy.fold(query).isEmpty else { return items }
        return items.enumerated()
            .compactMap { i, x in text(x).compactMap { Fuzzy.score(query, $0) }.max().map { (i, x, $0) } }
            .sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }
            .map(\.1)
    }
}

/// Deck layout: the pinned sidebar takes a strip on the left and every wrapped window shares the
/// rest, so picking a row is like picking a tab. Coordinates are Accessibility's (y down).
public enum Deck {
    public enum Layout: String, Codable, Sendable, CaseIterable {
        /// Windows stay where you put them; picking a row raises it.
        case free
        /// Every wrapped window fills the same frame beside the sidebar; picking a row brings that one up.
        case stack
        /// The picked window on the right half, the one before it on the left.
        case split
    }

    /// The frame wrapped windows share: the visible screen minus the sidebar strip and a margin.
    public static func content(visible: CGRect, sidebar: CGFloat, gap: CGFloat = 6) -> CGRect {
        CGRect(x: visible.minX + sidebar + gap, y: visible.minY + gap,
               width: visible.width - sidebar - 2 * gap, height: visible.height - 2 * gap).integral
    }

    /// Where a device's window (iPhone Mirroring, Device Hub) goes when picked from the sidebar:
    /// its own size, just right of the sidebar, centered top to bottom, kept on the visible screen.
    public static func docked(_ size: CGSize, visible: CGRect, sidebar: CGFloat, gap: CGFloat = 6) -> CGRect {
        let c = content(visible: visible, sidebar: sidebar, gap: gap)
        let w = min(size.width, c.width), h = min(size.height, c.height)
        return CGRect(x: c.minX, y: (c.midY - h / 2).rounded(), width: w, height: h)
    }

    /// Left and right halves of `content`.
    public static func halves(_ content: CGRect, gap: CGFloat = 6) -> (CGRect, CGRect) {
        let w = ((content.width - gap) / 2).rounded(.down)
        return (CGRect(x: content.minX, y: content.minY, width: w, height: content.height),
                CGRect(x: content.maxX - w, y: content.minY, width: w, height: content.height))
    }
}

/// Pairs Ghostty's windows (AppleScript IDs) with macOS windows (Accessibility, CGWindowID) by title.
/// Both lists come front to back, so equal titles pair up in order.
public enum WindowMatch {
    public static func pair(scripted: [(id: String, title: String)], native: [(number: UInt32, title: String)]) -> [String: UInt32] {
        var left = native
        var out: [String: UInt32] = [:]
        // Exact titles first, then titles the app extended: Chromium browsers append
        // " - High memory usage - 1.0 GB - Helium" or " - Part of group Work - Helium".
        for exact in [true, false] {
            for s in scripted where out[s.id] == nil {
                let hit = left.firstIndex { exact ? $0.title == s.title : (!s.title.isEmpty && $0.title.hasPrefix(s.title + " - ")) }
                if let i = hit {
                    out[s.id] = left[i].number
                    left.remove(at: i)
                }
            }
        }
        // One window each left over: they're the same window with a title that moved between reads.
        let unmatched = scripted.filter { out[$0.id] == nil }
        if unmatched.count == 1, left.count == 1 { out[unmatched[0].id] = left[0].number }
        return out
    }
}

/// Rows you've been to, for ⌃⌘[ and ⌃⌘], like a browser's back and forward. Going back and
/// then visiting something new drops the forward part. Rows that closed are skipped.
public struct DeckHistory: Equatable, Sendable {
    public private(set) var stack: [String] = []
    public private(set) var index = -1
    private var moving = false
    public let limit: Int

    public init(limit: Int = 50) { self.limit = limit }

    public mutating func visit(_ id: String) {
        if moving { moving = false; if index >= 0 && stack[index] == id { return } }
        if index >= 0 && stack[index] == id { return }
        stack = Array(stack.prefix(index + 1))
        stack.removeAll { $0 == id }
        stack.append(id)
        if stack.count > limit { stack.removeFirst(stack.count - limit) }
        index = stack.count - 1
    }

    public mutating func back(alive: Set<String>) -> String? { step(-1, alive) }
    public mutating func forward(alive: Set<String>) -> String? { step(1, alive) }

    private mutating func step(_ d: Int, _ alive: Set<String>) -> String? {
        var i = index + d
        while stack.indices.contains(i) {
            if alive.contains(stack[i]) {
                index = i
                moving = true
                return stack[i]
            }
            i += d
        }
        return nil
    }
}
