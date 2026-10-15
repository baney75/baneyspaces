import Foundation

/// What a terminal is doing, read from its title. Claude Code puts a spinner glyph at the front of
/// the title while it works and ✳ while it waits for you.
public enum Activity: Equatable, Sendable {
    case working
    case waiting
    case shell

    static let spinners: Set<Character> = ["◐", "◓", "◑", "◒", "·", "✢", "✶", "✻", "✽"]

    public static func of(title: String) -> Activity {
        guard let first = title.first else { return .shell }
        if first == "✳" { return .waiting }
        if spinners.contains(first) { return .working }
        if let s = first.unicodeScalars.first, (0x2800...0x28FF).contains(s.value) { return .working }
        return .shell
    }

    /// The title without the status glyph, which the sidebar shows as an icon instead.
    public static func label(of title: String) -> String {
        guard Activity.of(title: title) != .shell else { return title }
        return String(title.dropFirst()).trimmingCharacters(in: .whitespaces)
    }
}

/// One terminal surface in Ghostty, as its AppleScript dictionary reports it.
public struct Terminal: Equatable, Sendable, Identifiable {
    public let windowID: String
    public let tabID: String
    public let tabIndex: Int
    /// The tab is the one showing in its window.
    public let tabSelected: Bool
    /// The terminal has focus inside its tab.
    public let focusedInTab: Bool
    public let id: String
    public let title: String
    public let directory: String

    public init(windowID: String, tabID: String, tabIndex: Int, tabSelected: Bool, focusedInTab: Bool,
                id: String, title: String, directory: String) {
        self.windowID = windowID; self.tabID = tabID; self.tabIndex = tabIndex; self.tabSelected = tabSelected
        self.focusedInTab = focusedInTab; self.id = id; self.title = title; self.directory = directory
    }

    public var activity: Activity { Activity.of(title: title) }
    public var label: String {
        let l = Activity.label(of: title)
        return l.isEmpty ? Snapshot.shortPath(directory) : l
    }
}

/// Everything Ghostty has open at one moment.
public struct Snapshot: Equatable, Sendable {
    public var frontWindowID: String
    public var terminals: [Terminal]
    /// Each window's title, front to back. Ghostty's window IDs aren't macOS window numbers, so
    /// these titles are how a Ghostty window is matched to the window Accessibility sees.
    public var windowTitles: [(id: String, title: String)]

    public init(frontWindowID: String = "", terminals: [Terminal] = [], windowTitles: [(id: String, title: String)] = []) {
        self.frontWindowID = frontWindowID; self.terminals = terminals; self.windowTitles = windowTitles
    }

    public static func == (a: Snapshot, b: Snapshot) -> Bool {
        a.frontWindowID == b.frontWindowID && a.terminals == b.terminals
            && a.windowTitles.map(\.id) == b.windowTitles.map(\.id) && a.windowTitles.map(\.title) == b.windowTitles.map(\.title)
    }

    /// Fields are split by ASCII unit separators and records by record separators, so titles with
    /// tabs or new lines can't break a row. The first record is the front window's ID.
    public static let fieldSeparator: Character = "\u{1F}"
    public static let recordSeparator: Character = "\u{1E}"

    public static func parse(_ raw: String) -> Snapshot {
        var records = raw.trimmingCharacters(in: .newlines).split(separator: recordSeparator, omittingEmptySubsequences: false)
        guard !records.isEmpty else { return Snapshot() }
        let front = String(records.removeFirst())
        var titles: [(id: String, title: String)] = []
        let terminals = records.compactMap { r -> Terminal? in
            let f = r.split(separator: fieldSeparator, omittingEmptySubsequences: false).map(String.init)
            if f.count == 3, f[0] == "W" { titles.append((f[1], f[2])); return nil }
            guard f.count == 8 else { return nil }
            return Terminal(windowID: f[0], tabID: f[1], tabIndex: Int(f[2]) ?? 0, tabSelected: f[3] == "true",
                            focusedInTab: f[4] == "true", id: f[5], title: f[6], directory: f[7])
        }
        return Snapshot(frontWindowID: front, terminals: terminals, windowTitles: titles)
    }

    /// The terminal you're typing into, if Ghostty is in front.
    public var focusedID: String? {
        terminals.first { $0.windowID == frontWindowID && $0.tabSelected && $0.focusedInTab }?.id
    }

    /// Window IDs in Ghostty's order (front first), each with its terminals in tab order.
    public var windows: [(id: String, terminals: [Terminal])] {
        var order: [String] = []
        var byWindow: [String: [Terminal]] = [:]
        for t in terminals {
            if byWindow[t.windowID] == nil { order.append(t.windowID) }
            byWindow[t.windowID, default: []].append(t)
        }
        return order.map { ($0, byWindow[$0]!) }
    }

    public static func shortPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !path.isEmpty else { return "" }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

/// Remembers which terminals finished a Claude turn while you were looking elsewhere, newest first,
/// until you look at them. That's the list the sidebar lights up and ⌘⇧U jumps through.
public struct Attention: Equatable, Sendable {
    public private(set) var unseen: [String] = []
    private var last: [String: Activity] = [:]

    public init() {}

    /// `focused` is the terminal you're looking at right now: Ghostty in front and that terminal
    /// focused. Nil when another app is in front.
    public mutating func update(_ snapshot: Snapshot, focused: String?) {
        update(snapshot.terminals.map { ($0.id, $0.activity) }, focused: focused)
    }

    /// The same rule for any rows: each row's ID and what it's doing now.
    public mutating func update(_ rows: [(id: String, activity: Activity)], focused: String?) {
        var now: [String: Activity] = [:]
        for r in rows {
            now[r.id] = r.activity
            if last[r.id] == .working, r.activity == .waiting, r.id != focused {
                unseen.removeAll { $0 == r.id }
                unseen.insert(r.id, at: 0)
            }
        }
        // Started working again, closed, or looked at: no longer waiting on you.
        unseen.removeAll { now[$0] == nil || now[$0] == .working || $0 == focused }
        last = now
    }

    public mutating func seen(_ id: String) { unseen.removeAll { $0 == id } }

    /// Lights a row up directly, for `ghostdeck notify`: it needs you whatever its title says.
    public mutating func flag(_ id: String) {
        unseen.removeAll { $0 == id }
        unseen.insert(id, at: 0)
    }
}
