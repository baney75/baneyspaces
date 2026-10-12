import Foundation

/// How well a name answers what was typed, for the launcher. Higher is better; nil is no match.
/// A name that starts with the query beats one with a word that does ("Code" for "co" beats
/// "Visual Studio Code"), which beats initials ("vsc"), which beats letters found in order.
public enum Fuzzy {
    public static func score(_ query: String, _ name: String) -> Int? {
        let q = fold(query)
        guard !q.isEmpty else { return 0 }
        let n = fold(name)
        if n == q { return 1000 }
        if n.hasPrefix(q) { return 900 - min(n.count, 99) }
        let words = n.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if words.contains(where: { $0.hasPrefix(q) }) { return 700 - min(n.count, 99) }
        let initials = String(words.compactMap(\.first))
        if initials.hasPrefix(q) { return 600 - min(n.count, 99) }
        if n.contains(q) { return 500 - min(n.count, 99) }
        // Every letter in order: "sfr" finds Safari. Letters close together score higher.
        var gaps = 0
        var i = n.startIndex
        var last: String.Index?
        for ch in q where ch != " " {
            guard let at = n[i...].firstIndex(of: ch) else { return nil }
            if let last { gaps += n.distance(from: last, to: at) - 1 }
            last = at
            i = n.index(after: at)
        }
        return max(1, 300 - gaps * 10 - min(n.count, 99))
    }

    /// Lowercased, accents dropped: "Café" matches "cafe".
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespaces)
    }
}

/// An app Homebrew can install: one entry of formulae.brew.sh's cask list, slimmed to what the
/// launcher shows.
public struct Cask: Codable, Equatable, Sendable {
    public let token: String
    public let name: String
    public let desc: String
    public let homepage: String

    public init(token: String, name: String, desc: String, homepage: String) {
        self.token = token
        self.name = name
        self.desc = desc
        self.homepage = homepage
    }

    /// Parses Homebrew's full cask list (formulae.brew.sh/api/cask.json). Deprecated and
    /// disabled casks are left out: they no longer install.
    public static func parseCatalog(_ data: Data) -> [Cask] {
        guard let all = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return all.compactMap { c in
            guard let token = c["token"] as? String, isSafeToken(token) else { return nil }
            if (c["disabled"] as? Bool) == true || (c["deprecated"] as? Bool) == true { return nil }
            let name = (c["name"] as? [String])?.first ?? token
            return Cask(token: token, name: name, desc: c["desc"] as? String ?? "", homepage: c["homepage"] as? String ?? "")
        }
    }

    /// Cask tokens are lowercase letters, digits and - @ . _ only. Anything else is dropped
    /// before it can reach brew or a Terminal script.
    public static func isSafeToken(_ token: String) -> Bool {
        !token.isEmpty && !token.hasPrefix("-") && token.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || "-@._".contains($0)) }
    }

    /// The best matches for a query: by name or token first, then by description.
    public static func search(_ query: String, in casks: [Cask], limit: Int = 30) -> [Cask] {
        guard !Fuzzy.fold(query).isEmpty else { return [] }
        // About a thousand casks are fonts; they only crowd out apps unless fonts are wanted.
        let fonts = Fuzzy.fold(query).contains("font")
        let scored = casks.compactMap { c -> (Cask, Int)? in
            if !fonts && c.token.hasPrefix("font-") { return nil }
            let byName = max(Fuzzy.score(query, c.name) ?? -1, Fuzzy.score(query, c.token) ?? -1)
            // Letters scattered through a long description match nearly anything; only a real
            // substring there counts.
            if byName >= 300 { return (c, byName) }
            if Fuzzy.fold(c.desc).contains(Fuzzy.fold(query)) { return (c, 200) }
            return byName > 0 ? (c, byName) : nil
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.token < $1.0.token }.prefix(limit).map(\.0)
    }
}

/// Apps opened from the launcher, most recent first, so the ones you use come up first.
public struct Recents: Equatable, Sendable {
    public private(set) var paths: [String]
    public static let limit = 30

    public init(_ paths: [String] = []) { self.paths = Array(paths.prefix(Self.limit)) }

    public mutating func used(_ path: String) {
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > Self.limit { paths.removeLast(paths.count - Self.limit) }
    }

    /// A small lift for recent apps: enough to break near-ties, never enough to beat a better match.
    public func boost(_ path: String) -> Int {
        guard let i = paths.firstIndex(of: path) else { return 0 }
        return 60 - i * 2
    }
}

/// The ⌘Tab app list. An app split across workspaces gets one entry per workspace, so two
/// Ghostty windows on 1 and 4 are two choices, not one that guesses. Entries go most recently
/// used app first; within an app, the workspace it was last used on first, then the others in
/// the order they were last visited.
public enum AppSwitchList {
    public struct Entry: Equatable, Sendable {
        public let app: Int32
        public let workspace: Int
        public let windows: Int
        /// The app has windows on other workspaces too.
        public let isSplit: Bool
    }

    /// `windows` is (app, workspace) for every window. `appOrder` and `workspaceOrder` are most
    /// recent first; `lastWorkspace[app]` is where that app was last in front.
    public static func make(windows: [(app: Int32, workspace: Int)], appOrder: [Int32], workspaceOrder: [Int],
                            lastWorkspace: [Int32: Int]) -> [Entry] {
        var counts: [Int32: [Int: Int]] = [:]
        var seen: [Int32] = []
        for w in windows {
            if counts[w.app] == nil { seen.append(w.app) }
            counts[w.app, default: [:]][w.workspace, default: 0] += 1
        }
        let apps = appOrder.filter { counts[$0] != nil } + seen.filter { !appOrder.contains($0) }
        func rank(_ n: Int) -> Int { workspaceOrder.firstIndex(of: n) ?? (100 + n) }
        let grouped = apps.map { app -> [Entry] in
            let byWorkspace = counts[app]!
            let order = byWorkspace.keys.sorted { a, b in
                if a == lastWorkspace[app] { return true }
                if b == lastWorkspace[app] { return false }
                return rank(a) < rank(b)
            }
            return order.map { Entry(app: app, workspace: $0, windows: byWorkspace[$0]!, isSplit: byWorkspace.count > 1) }
        }
        // One tap of ⌘Tab goes back to the previous app, as on macOS: the front app's copies on
        // other workspaces wait until after that app instead of sitting between them.
        guard grouped.count > 1, grouped[0].count > 1 else { return grouped.flatMap { $0 } }
        return [grouped[0][0]] + grouped[1] + grouped[0].dropFirst() + grouped.dropFirst(2).flatMap { $0 }
    }
}

/// Clicking an app in the dock again steps to its next window on that workspace.
public enum WindowCycle {
    /// The window to focus among `windows` (in a stable order) when `focused` is in front.
    public static func next<ID: Equatable>(_ windows: [ID], after focused: ID?) -> ID? {
        guard !windows.isEmpty else { return nil }
        guard let focused, let i = windows.firstIndex(of: focused) else { return windows[0] }
        return windows[(i + 1) % windows.count]
    }
}

/// Holding Tab in the ⌘Tab switcher (instead of tapping it) opens or closes the window bar.
/// macOS sends repeats while a key is held, after the person's own repeat delay, which can be
/// very short; a hold counts only once the key has been down `threshold` seconds, and only
/// once per press.
public struct TabHold: Sendable {
    public static let threshold: Double = 0.35
    private var pressedAt: Double?
    private var fired = false

    public init() {}

    /// A fresh Tab press (not a repeat).
    public mutating func press(at t: Double) {
        pressedAt = t
        fired = false
    }

    /// A repeat of the held Tab. True exactly once per press, when it has been held long enough.
    public mutating func repeated(at t: Double) -> Bool {
        guard let pressedAt, !fired, t - pressedAt >= Self.threshold else { return false }
        fired = true
        return true
    }
}
