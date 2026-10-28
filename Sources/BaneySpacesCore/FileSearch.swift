import Foundation

/// Finding files and folders by name for the launcher, through Spotlight's index of your home
/// folder. This half builds the query and ranks what comes back; the app runs the query.
public enum FileSearch {
    /// Fewer letters match half the home folder and say nothing about what's wanted.
    public static let minimumQuery = 2

    /// A file Spotlight found: its file name, its path, when it was last opened and last
    /// changed (nil if unknown).
    public struct Hit: Equatable, Sendable {
        public let name: String
        public let path: String
        public let lastUsed: Date?
        public let modified: Date?
        public init(name: String, path: String, lastUsed: Date? = nil, modified: Date? = nil) {
            self.name = name
            self.path = path
            self.lastUsed = lastUsed
            self.modified = modified
        }
    }

    /// The Spotlight query for what was typed: every word must start a word of the name, case
    /// and accents ignored ("tax 2025" finds "2025 Tax Return.pdf"). Apps are left out; the
    /// launcher lists those already. Nil when there's too little to search for.
    public static func spotlightQuery(_ typed: String) -> String? {
        let words = typed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.joined().count >= minimumQuery else { return nil }
        let terms = words.map { "kMDItemFSName == \"\(escape($0))*\"cdw" }
        return "(" + terms.joined(separator: " && ") + ") && kMDItemContentType != \"com.apple.application-bundle\""
    }

    /// What was typed, safe inside a quoted Spotlight value: a backslash, quote or wildcard is
    /// matched as itself, never read as query syntax.
    public static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "\\\"*?".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// Places nobody means when they search for a file by name: inside Library (except iCloud
    /// Drive and other cloud drives, which live there), an app or package, a hidden folder, or a
    /// dependency or build folder.
    public static func isNoise(_ path: String, home: String) -> Bool {
        let rel = path.hasPrefix(home + "/") ? String(path.dropFirst(home.count + 1)) : path
        let parts = rel.split(separator: "/").map(String.init)
        if parts.first == "Library", !(parts.count > 2 && cloudFolders.contains(parts[1])) { return true }
        let skipped: Set<String> = ["node_modules", ".build", "DerivedData", "__pycache__", ".venv", "venv", "Pods"]
        for p in parts.dropLast() {
            if p.hasPrefix(".") || skipped.contains(p) { return true }
            if p.hasSuffix(".app") || p.hasSuffix(".bundle") || p.hasSuffix(".framework") || p.hasSuffix(".photoslibrary") { return true }
        }
        return parts.last?.hasPrefix(".") ?? false
    }

    /// The best `limit` hits for what was typed: the better name match first, then the one opened
    /// (or, counting half, changed) more recently, then the one nearer the home folder.
    public static func rank(_ typed: String, _ hits: [Hit], home: String, now: Date = Date(), limit: Int) -> [Hit] {
        let q = typed.trimmingCharacters(in: .whitespaces)
        let scored = hits.compactMap { h -> (Hit, Int)? in
            guard !isNoise(h.path, home: home) else { return nil }
            // Spotlight matched every word already; a name Fuzzy can't place still counts, low.
            let name = Fuzzy.score(q, h.name) ?? Fuzzy.score(q, (h.name as NSString).deletingPathExtension) ?? 100
            let depth: Int = h.path.split(separator: "/").count - home.split(separator: "/").count
            let recent: Int = max(recency(h.lastUsed, now: now), recency(h.modified, now: now) / 2)
            let score: Int = name + recent - min(max(depth, 0), 10) * 3
            return (h, score)
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.path < $1.0.path }.prefix(limit).map(\.0)
    }

    /// Library's folders that hold your own files: iCloud Drive and apps' iCloud folders, and the
    /// cloud drives (Google Drive, Dropbox, OneDrive, Proton Drive).
    static let cloudFolders: Set<String> = ["Mobile Documents", "CloudStorage"]

    /// A lift for a file opened lately: enough to beat a near-tie, never a much better name.
    static func recency(_ used: Date?, now: Date) -> Int {
        guard let used else { return 0 }
        let days = now.timeIntervalSince(used) / 86_400
        if days < 1 { return 60 }
        if days < 7 { return 40 }
        if days < 30 { return 20 }
        return days < 365 ? 5 : 0
    }

    /// Where the launcher says a file is: "~/Documents/School", "iCloud Drive/Taxes",
    /// "Obsidian/BaneyVault/Notes" for an app's iCloud folder.
    public static func folder(of path: String, home: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        if dir == home { return "~" }
        guard dir.hasPrefix(home + "/") else { return dir }
        let rel = dir.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        if rel.count >= 3, rel[0] == "Library", rel[1] == "Mobile Documents" {
            // com~apple~CloudDocs is iCloud Drive itself; iCloud~md~obsidian/Documents is Obsidian's.
            let rest = rel.dropFirst(3)
            if rel[2] == "com~apple~CloudDocs" { return (["iCloud Drive"] + rest).joined(separator: "/") }
            let app = rel[2].split(separator: "~").last.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? rel[2]
            return ([app] + (rest.first == "Documents" ? rest.dropFirst() : rest)).joined(separator: "/")
        }
        if rel.count >= 3, rel[0] == "Library", rel[1] == "CloudStorage" {
            return rel.dropFirst(2).joined(separator: "/")
        }
        return "~/" + rel.joined(separator: "/")
    }
}
