import Foundation

// Sites in the launcher (Donovan, 2026-11-01): "opening bookmarks that exist in the default browser or
// super frequently visited sites ... if I search X an x icon pops up and can be pressed to open it in
// helium." Three sources, one ranking (spec/launcher.md): the built-in list (spec/sites.json, with
// aliases), the default browser's bookmarks, and its most visited sites. This file is the parsing and the
// ranking, with no browser, no disk and no network, over data already in memory. Privacy: a site is a name,
// a host and the one address needed to open it; no URL is ever logged (SiteRulesTests reads the source).

/// A site the launcher can open.
public struct Site: Equatable, Sendable {
    public enum Source: Int, Equatable, Sendable { case builtIn, bookmark, frequent }
    public let id: String
    public let name: String
    /// The host without "www.", lowercased.
    public let host: String
    /// What opening it loads: the built-in address, the bookmark's, or a most-visited site's origin.
    public let url: String
    public let aliases: [String]
    /// Mac apps that do the same job (Spotify, Slack): preferred over the site, with the site one step away.
    public let nativeApps: [String]
    /// The app's name on the iPhone, if it has one, for "Open on iPhone".
    public let iphoneApp: String?
    public let source: Source
    /// Visits in the browser's history, for a most-visited site.
    public let visits: Int

    public init(id: String, name: String, host: String, url: String, aliases: [String] = [], nativeApps: [String] = [],
                iphoneApp: String? = nil, source: Source, visits: Int = 0) {
        self.id = id
        self.name = name
        self.host = host
        self.url = url
        self.aliases = aliases
        self.nativeApps = nativeApps
        self.iphoneApp = iphoneApp
        self.source = source
        self.visits = visits
    }
}

public enum SiteCatalog {
    /// One line of spec/sites.json.
    public struct Entry: Equatable, Sendable {
        public let id: String, name: String, url: String
        public let aliases: [String], native: [String]
        public let iphone: String?
        public init(id: String, name: String, url: String, aliases: [String], native: [String], iphone: String?) {
            self.id = id
            self.name = name
            self.url = url
            self.aliases = aliases
            self.native = native
            self.iphone = iphone
        }
    }

    /// The built-in list as sites.
    public static let builtIn: [Site] = entries.compactMap { e in
        guard let host = host(of: e.url) else { return nil }
        return Site(id: e.id, name: e.name, host: host, url: e.url, aliases: e.aliases, nativeApps: e.native, iphoneApp: e.iphone, source: .builtIn)
    }

    /// "https://www.GitHub.com/a/b?c" is "github.com". Nil for anything but http and https.
    public static func host(of address: String) -> String? {
        guard let c = URLComponents(string: address.trimmingCharacters(in: .whitespaces)),
              let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var h = c.host?.lowercased(), !h.isEmpty else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }
}

/// A bookmark: the title and the address.
public struct Bookmark: Equatable, Sendable {
    public let title: String
    public let url: String
    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}

public enum BookmarkParse {
    public static let limit = 20_000

    /// Chromium's `Bookmarks` file (Chrome, Helium, Brave, Edge, Arc, Vivaldi): the bookmark bar, other
    /// bookmarks and synced ones, folders flattened.
    public static func chromium(_ data: Data) -> [Bookmark] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let roots = root["roots"] as? [String: Any] else { return [] }
        var out: [Bookmark] = []
        func walk(_ node: [String: Any]) {
            guard out.count < limit else { return }
            if (node["type"] as? String) == "url", let url = node["url"] as? String, CatalogCheck.web(url) {
                out.append(Bookmark(title: node["name"] as? String ?? "", url: url))
            }
            for child in node["children"] as? [[String: Any]] ?? [] { walk(child) }
        }
        for key in roots.keys.sorted() { if let node = roots[key] as? [String: Any] { walk(node) } }
        return out
    }

    /// Safari's `Bookmarks.plist`, without the Reading List.
    public static func safari(_ data: Data) -> [Bookmark] {
        guard let root = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else { return [] }
        var out: [Bookmark] = []
        func walk(_ node: [String: Any]) {
            guard out.count < limit else { return }
            if (node["Title"] as? String) == "com.apple.ReadingList" { return }
            if (node["WebBookmarkType"] as? String) == "WebBookmarkTypeLeaf", let url = node["URLString"] as? String, CatalogCheck.web(url) {
                let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? ""
                out.append(Bookmark(title: title, url: url))
            }
            for child in node["Children"] as? [[String: Any]] ?? [] { walk(child) }
        }
        walk(root)
        return out
    }
}

enum CatalogCheck {
    static func web(_ address: String) -> Bool { SiteCatalog.host(of: address) != nil }
}

/// The sites a browser's history says are visited most, from its `urls` rows (address, visit count) and
/// nothing else: only the host and its origin are kept, summed over every page of the site.
public enum FrequentSites {
    public static let limit = 200

    public static func top(_ rows: [(url: String, visits: Int)], limit: Int = FrequentSites.limit) -> [Site] {
        var visits: [String: Int] = [:]
        var origin: [String: String] = [:]
        for r in rows {
            guard let c = URLComponents(string: r.url), let host = SiteCatalog.host(of: r.url), isSite(host) else { continue }
            visits[host, default: 0] += max(r.visits, 0)
            if origin[host] == nil { origin[host] = "\(c.scheme ?? "https")://\(c.host ?? host)" + (c.port.map { ":\($0)" } ?? "") }
        }
        return visits.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map { host, n in
            Site(id: host, name: host, host: host, url: origin[host] ?? "https://\(host)", source: .frequent, visits: n)
        }
    }

    /// A real site: a dotted name, not an address or a local one.
    static func isSite(_ host: String) -> Bool {
        guard host.contains("."), !host.hasSuffix(".local"), !host.hasSuffix(".localhost") else { return false }
        return !host.allSatisfy { $0.isNumber || $0 == "." || $0 == ":" }
    }
}

/// What a query found.
public struct SiteHit: Equatable, Sendable {
    public let site: Site
    public let score: Int
    /// Typed exactly as one of its names ("x", "yt").
    public let exactAlias: Bool
}

/// The three sources folded once, so a keystroke ranks them from memory.
public struct SiteIndex: Sendable {
    /// A class, so ranking thousands of bookmarks reads each one in place instead of copying it.
    private final class Entry: Sendable {
        let site: Site
        let aliases: [String]
        let name: String
        let nameWords: [String]
        let labels: [String]
        init(site: Site, aliases: [String], name: String, nameWords: [String], labels: [String]) {
            self.site = site
            self.aliases = aliases
            self.name = name
            self.nameWords = nameWords
            self.labels = labels
        }
    }
    private let entries: [Entry]
    private let builtInHosts: Set<String>

    public init(builtIn: [Site] = SiteCatalog.builtIn, bookmarks: [Bookmark] = [], frequent: [Site] = []) {
        var all: [Entry] = []
        func add(_ site: Site) {
            let name = Fuzzy.fold(site.name)
            let labels = site.host.split(separator: ".").dropLast().map(String.init)
            all.append(Entry(site: site, aliases: site.aliases.map(Fuzzy.fold), name: name,
                             nameWords: name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init),
                             labels: labels.map(Fuzzy.fold)))
        }
        builtIn.forEach(add)
        for b in bookmarks {
            guard let host = SiteCatalog.host(of: b.url) else { continue }
            let name = b.title.trimmingCharacters(in: .whitespaces)
            add(Site(id: b.url, name: name.isEmpty ? host : name, host: host, url: b.url, source: .bookmark))
        }
        frequent.forEach(add)
        entries = all
        builtInHosts = Set(builtIn.map(\.host))
    }

    public var count: Int { entries.count }

    /// The most-visited sites this index was built with, to carry over while history isn't read again.
    public var frequentSites: [Site] { entries.map(\.site).filter { $0.source == .frequent } }

    /// Sites for what was typed, best first. One letter matches only an exact alias ("x" is X, never every
    /// site with an x); longer text matches the start of a name, an alias, a word of the name or the
    /// domain's name (never the middle of a word: that is slow over thousands of bookmarks and rarely meant). A most-visited site the built-in list already names is not listed twice.
    public func rank(_ typed: String, limit: Int = 3) -> [SiteHit] {
        let q = Fuzzy.fold(typed)
        guard !q.isEmpty else { return [] }
        var best: [String: SiteHit] = [:]
        for e in entries {
            let exact = e.aliases.contains(q) || e.name == q
            var score = 0
            if exact { score = 2000 }
            else if q.count >= 2 {
                if e.aliases.contains(where: { $0.hasPrefix(q) }) { score = 1500 }
                else if e.name.hasPrefix(q) { score = 1400 }
                else if e.labels.contains(where: { $0.hasPrefix(q) }) { score = 1300 }
                else if e.nameWords.contains(where: { $0.hasPrefix(q) }) { score = 1100 }
            }
            guard score > 0 else { continue }
            // Shorter names first among equals; your own bookmarks a little over the rest; visits a little more.
            score -= min(e.name.count, 60)
            if e.site.source == .bookmark { score += 40 }
            if e.site.source == .frequent { score += min(Int(log2(Double(e.site.visits + 1)) * 4), 60) }
            // The built-in row stands for its host: a most-visited site it already names is not listed twice.
            if e.site.source == .frequent, builtInHosts.contains(e.site.host) { continue }
            let key: String
            switch e.site.source {
            case .builtIn: key = "b:" + e.site.id
            case .bookmark: key = "m:" + e.site.url
            case .frequent: key = "f:" + e.site.host
            }
            if let old = best[key], old.score >= score { continue }
            best[key] = SiteHit(site: e.site, score: score, exactAlias: exact)
        }
        return best.values.sorted { $0.score != $1.score ? $0.score > $1.score : $0.site.name < $1.site.name }.prefix(limit).map { $0 }
    }
}
