/// Which workspaces the menu bar menu lists, and how. Nine rows, most of them empty, buried the
/// rest of the menu (Donovan, 2026-10-14), so it lists the workspaces in use, the one you're on,
/// and one empty workspace to start fresh on. ⌘1–⌘9 still reach every one of them.
public enum MenuLayout {
    public struct Row: Equatable, Sendable {
        public let workspace: Int
        public let title: String
        /// Every app on it, for the tooltip, when the title had to shorten the list.
        public let fullList: String?
        public let isCurrent: Bool
    }

    /// `apps` is each workspace's app names in order; a workspace missing from it is empty.
    public static func rows(current: Int, apps: [Int: [String]], range: ClosedRange<Int> = 1...9) -> [Row] {
        var out: [Row] = []
        for n in range {
            let names = apps[n] ?? []
            guard !names.isEmpty || n == current else { continue }
            let short = summary(names)
            out.append(Row(workspace: n,
                           title: names.isEmpty ? "Workspace \(n)" : "Workspace \(n)  ·  \(short)",
                           fullList: names.count > shownApps ? names.joined(separator: ", ") : nil,
                           isCurrent: n == current))
        }
        if let empty = range.first(where: { (apps[$0] ?? []).isEmpty && $0 != current }) {
            out.append(Row(workspace: empty, title: "Empty Workspace \(empty)", fullList: nil, isCurrent: false))
        }
        return out
    }

    public static let shownApps = 3

    /// "Helium, Ghostty, Obsidian +2": a long list stays one short line.
    public static func summary(_ names: [String]) -> String {
        guard names.count > shownApps else { return names.joined(separator: ", ") }
        return names.prefix(shownApps).joined(separator: ", ") + " +\(names.count - shownApps)"
    }
}
