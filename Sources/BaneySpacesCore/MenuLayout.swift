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

/// A release waiting to be installed, or installing, as the menu bar menu and Settings word it.
public struct UpdateNotice: Equatable, Sendable {
    public let name: String
    public let isNightly: Bool
    public let installing: Bool

    public init(name: String, isNightly: Bool, installing: Bool) {
        self.name = name
        self.isNightly = isNightly
        self.installing = installing
    }

    /// "Update to BaneySpaces 0.3.1…" or "Update to the Nightly Build…"; "Updating to …" while it installs.
    public var menuTitle: String {
        installing ? "Updating to \(isNightly ? "the Nightly Build" : name)…" : "Update to \(isNightly ? "the Nightly Build" : name)…"
    }

    /// A sentence of its own: "BaneySpaces 0.3.1 is available." / "The nightly build is available."
    public var sentence: String {
        isNightly ? "The nightly build is available." : "\(name) is available."
    }
}

/// The menu bar menu, as a list of what it holds. The app builds exactly these and nothing else, so
/// a test can read what a person would see (Donovan, 2026-10-31: five kinds of rows). A row for
/// finished agents or a waiting update is there only while there is something to act on.
public enum MenuEntry: Equatable, Sendable {
    case workspace(MenuLayout.Row)
    case showAll, find, settings, quit
    /// "Turn Off Workspace Dock" / "Turn On Workspace Dock": the dock switch (`dock.enabled`).
    case dock(on: Bool)
    /// "N agents finished while you were away", a submenu listing them.
    case finished(count: Int)
    case update(UpdateNotice)
    case separator
}

extension MenuLayout {
    public static func entries(rows: [Row], finished: Int, update: UpdateNotice?, dockOn: Bool? = nil) -> [MenuEntry] {
        var out = rows.map(MenuEntry.workspace)
        out += [.separator, .showAll, .find]
        if let dockOn { out.append(.dock(on: dockOn)) }
        var pending: [MenuEntry] = []
        if finished > 0 { pending.append(.finished(count: finished)) }
        if let update { pending.append(.update(update)) }
        if !pending.isEmpty { out.append(.separator); out += pending }
        out += [.separator, .settings, .quit]
        return out
    }

    /// "1 Agent Finished While You Were Away" / "3 Agents Finished While You Were Away".
    public static func finishedTitle(_ count: Int) -> String {
        "\(count) \(count == 1 ? "Agent Finished" : "Agents Finished") While You Were Away"
    }
}
