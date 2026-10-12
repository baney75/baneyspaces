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
            guard let token = c["token"] as? String else { return nil }
            if (c["disabled"] as? Bool) == true || (c["deprecated"] as? Bool) == true { return nil }
            let name = (c["name"] as? [String])?.first ?? token
            return Cask(token: token, name: name, desc: c["desc"] as? String ?? "", homepage: c["homepage"] as? String ?? "")
        }
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
