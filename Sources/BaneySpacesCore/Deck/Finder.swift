import CoreGraphics
import Foundation

/// Ranks deck rows for the launcher with the launcher's own matcher, so both search alike.
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
