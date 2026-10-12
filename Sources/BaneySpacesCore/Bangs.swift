import Foundation

/// A shortcut to search one site, typed with a "!": "!yt cats" searches YouTube for cats. The
/// same idea, and mostly the same triggers, as DuckDuckGo's bangs.
public struct Bang: Codable, Equatable, Sendable {
    public let trigger: String
    public let name: String
    /// The search address with `{q}` where the words go.
    public let url: String
    /// Where a bang with no words goes. Defaults to the search address's site.
    public var home: String?
    /// An AI agent: the words are a question, asked in a new chat.
    public var agent: Bool?

    public var isAgent: Bool { agent == true }

    public init(trigger: String, name: String, url: String, home: String? = nil, agent: Bool = false) {
        self.trigger = trigger
        self.name = name
        self.url = url
        self.home = home
        self.agent = agent ? true : nil
    }

    /// The address for these words, or the site itself when there are none.
    public func address(for terms: String) -> URL? {
        let t = terms.trimmingCharacters(in: .whitespaces)
        if t.isEmpty {
            if let home, let u = Bangs.safeURL(home) { return u }
            // The site itself: scheme, host and port kept, path and search dropped.
            guard var c = URLComponents(string: url.replacingOccurrences(of: "{q}", with: "")), c.host != nil else {
                return Bangs.safeURL(url.replacingOccurrences(of: "{q}", with: ""))
            }
            c.path = "/"
            c.query = nil
            c.fragment = nil
            return c.string.flatMap(Bangs.safeURL)
        }
        return Bangs.safeURL(url.replacingOccurrences(of: "{q}", with: Bangs.encode(t)))
    }
}

public enum Bangs {
    /// A query split into its bang and its words: "!yt cats" and "cats !yt" both give ("yt", "cats").
    public struct Parsed: Equatable, Sendable {
        public let trigger: String
        public let terms: String
    }

    public static func parse(_ query: String) -> Parsed? {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return nil }
        func trigger(_ w: String) -> String? {
            guard w.count > 1, w.hasPrefix("!") else { return nil }
            return String(w.dropFirst()).lowercased()
        }
        if let t = trigger(words[0]) { return Parsed(trigger: t, terms: words.dropFirst().joined(separator: " ")) }
        if words.count > 1, let t = trigger(words[words.count - 1]) {
            return Parsed(trigger: t, terms: words.dropLast().joined(separator: " "))
        }
        return nil
    }

    /// Everything but letters, digits and - . _ ~ is percent-encoded, so words can never break
    /// out of the address (an "&" or "#" in a search stays part of the search).
    public static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// Only web addresses and Apple's Maps open; a bang can't run anything else.
    static func safeURL(_ s: String) -> URL? {
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(), ["https", "http", "maps"].contains(scheme) else { return nil }
        return u
    }

    /// DuckDuckGo resolves the thousands of bangs not listed here.
    public static let fallback = Bang(trigger: "ddg", name: "DuckDuckGo", url: "https://duckduckgo.com/?q={q}")

    /// AI agents that take a question in their address: each opens a new chat that asks it.
    public static let agents: [Bang] = [
        Bang(trigger: "claude", name: "Claude", url: "https://claude.ai/new?q={q}", home: "https://claude.ai/new", agent: true),
        Bang(trigger: "chatgpt", name: "ChatGPT", url: "https://chatgpt.com/?q={q}", home: "https://chatgpt.com/", agent: true),
        Bang(trigger: "pplx", name: "Perplexity", url: "https://www.perplexity.ai/search?q={q}", home: "https://www.perplexity.ai/", agent: true),
        Bang(trigger: "grok", name: "Grok", url: "https://grok.com/?q={q}", home: "https://grok.com/", agent: true),
        Bang(trigger: "copilot", name: "Microsoft Copilot", url: "https://copilot.microsoft.com/?q={q}", home: "https://copilot.microsoft.com/", agent: true),
        Bang(trigger: "lechat", name: "Le Chat", url: "https://chat.mistral.ai/chat?q={q}", home: "https://chat.mistral.ai/chat", agent: true),
    ]

    /// Search engines a plain search can go to.
    public static var engines: [Bang] { ["g", "ddg", "b", "pplx"].compactMap { t in (builtIn + agents).first { $0.trigger == t } } }

    public static let builtIn: [Bang] = agents + [
        Bang(trigger: "g", name: "Google", url: "https://www.google.com/search?q={q}"),
        Bang(trigger: "ddg", name: "DuckDuckGo", url: "https://duckduckgo.com/?q={q}"),
        Bang(trigger: "b", name: "Bing", url: "https://www.bing.com/search?q={q}"),
        Bang(trigger: "yt", name: "YouTube", url: "https://www.youtube.com/results?search_query={q}"),
        Bang(trigger: "w", name: "Wikipedia", url: "https://en.wikipedia.org/wiki/Special:Search?search={q}"),
        Bang(trigger: "gi", name: "Google Images", url: "https://www.google.com/search?tbm=isch&q={q}", home: "https://images.google.com/"),
        Bang(trigger: "i", name: "Images", url: "https://www.google.com/search?tbm=isch&q={q}", home: "https://images.google.com/"),
        Bang(trigger: "img", name: "Images", url: "https://www.google.com/search?tbm=isch&q={q}", home: "https://images.google.com/"),
        Bang(trigger: "ddgi", name: "DuckDuckGo Images", url: "https://duckduckgo.com/?ia=images&iax=images&q={q}"),
        Bang(trigger: "v", name: "Videos", url: "https://www.google.com/search?tbm=vid&q={q}"),
        Bang(trigger: "maps", name: "Google Maps", url: "https://www.google.com/maps/search/{q}", home: "https://www.google.com/maps"),
        Bang(trigger: "am", name: "Apple Maps", url: "maps://?q={q}", home: "maps://"),
        Bang(trigger: "gh", name: "GitHub", url: "https://github.com/search?q={q}"),
        Bang(trigger: "r", name: "Reddit", url: "https://www.reddit.com/search/?q={q}"),
        Bang(trigger: "x", name: "X", url: "https://x.com/search?q={q}"),
        Bang(trigger: "a", name: "Amazon", url: "https://www.amazon.com/s?k={q}"),
        Bang(trigger: "ebay", name: "eBay", url: "https://www.ebay.com/sch/i.html?_nkw={q}"),
        Bang(trigger: "so", name: "Stack Overflow", url: "https://stackoverflow.com/search?q={q}"),
        Bang(trigger: "mdn", name: "MDN Web Docs", url: "https://developer.mozilla.org/en-US/search?q={q}"),
        Bang(trigger: "npm", name: "npm", url: "https://www.npmjs.com/search?q={q}"),
        Bang(trigger: "pypi", name: "PyPI", url: "https://pypi.org/search/?q={q}"),
        Bang(trigger: "hf", name: "Hugging Face", url: "https://huggingface.co/models?search={q}"),
        Bang(trigger: "apple", name: "Apple Developer", url: "https://developer.apple.com/search/?q={q}"),
        Bang(trigger: "scholar", name: "Google Scholar", url: "https://scholar.google.com/scholar?q={q}"),
        Bang(trigger: "t", name: "Google Translate", url: "https://translate.google.com/?text={q}"),
        Bang(trigger: "d", name: "Merriam-Webster", url: "https://www.merriam-webster.com/dictionary/{q}"),
        Bang(trigger: "bible", name: "Bible Gateway", url: "https://www.biblegateway.com/quicksearch/?quicksearch={q}"),
        Bang(trigger: "esv", name: "ESV Bible", url: "https://www.esv.org/search/?q={q}"),
        Bang(trigger: "imdb", name: "IMDb", url: "https://www.imdb.com/find/?q={q}"),
        Bang(trigger: "spotify", name: "Spotify", url: "https://open.spotify.com/search/{q}"),

        Bang(trigger: "news", name: "Google News", url: "https://news.google.com/search?q={q}"),
        Bang(trigger: "wa", name: "Wolfram Alpha", url: "https://www.wolframalpha.com/input?i={q}"),
        Bang(trigger: "brew", name: "Homebrew", url: "https://duckduckgo.com/?q=site%3Aformulae.brew.sh+{q}", home: "https://formulae.brew.sh/"),
    ]

    /// Custom bangs first, so one can replace a built-in; then the built-ins.
    public static func all(custom: [Bang]) -> [Bang] {
        let mine = normalize(custom).bangs
        let taken = Set(mine.map(\.trigger))
        return mine + builtIn.filter { !taken.contains($0.trigger) }
    }

    /// A trigger as stored: trimmed, without a leading "!", lowercased.
    static func canonical(_ trigger: String) -> String {
        var t = trigger.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while t.hasPrefix("!") { t.removeFirst() }
        return t
    }

    /// Valid bangs with canonical triggers, the first of each trigger kept; and why any were left out.
    public static func normalize(_ list: [Bang]) -> (bangs: [Bang], problems: [String]) {
        var seen = Set<String>()
        var out: [Bang] = []
        var problems: [String] = []
        for b in list {
            let t = canonical(b.trigger)
            if let why = problem(trigger: t, name: b.name, url: b.url) {
                problems.append("!\(t.isEmpty ? "?" : t): \(why)")
                continue
            }
            guard seen.insert(t).inserted else {
                problems.append("!\(t) is listed twice; the first one is used.")
                continue
            }
            out.append(Bang(trigger: t, name: b.name.trimmingCharacters(in: .whitespaces), url: b.url.trimmingCharacters(in: .whitespaces),
                            home: b.home, agent: b.isAgent))
        }
        return (out, problems)
    }

    /// Reads a bangs.json. Entries are read one by one, so a bad one costs only itself; `readable`
    /// is false when the file as a whole isn't a JSON list, and then it must not be written over.
    public static func decodeCustom(_ data: Data) -> (bangs: [Bang], problems: [String], readable: Bool) {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return ([], ["bangs.json isn't a list of bangs. (TextEdit's curly quotes are a common cause.)"], false)
        }
        var bangs: [Bang] = []
        var problems: [String] = []
        for (i, entry) in raw.enumerated() {
            guard JSONSerialization.isValidJSONObject(entry as? [String: Any] ?? [:]),
                  let d = try? JSONSerialization.data(withJSONObject: entry as? [String: Any] ?? [:]),
                  let b = try? JSONDecoder().decode(Bang.self, from: d) else {
                problems.append("Entry \(i + 1) needs a trigger, a name and a url.")
                continue
            }
            bangs.append(b)
        }
        let n = normalize(bangs)
        return (n.bangs, problems + n.problems, true)
    }

    /// Why a new bang can't be saved, in a sentence for the person, or nil if it can.
    public static func problem(trigger: String, name: String, url: String) -> String? {
        let t = trigger.trimmingCharacters(in: .whitespaces).lowercased()
        let t2 = t.hasPrefix("!") ? String(t.dropFirst()) : t
        if t2.isEmpty { return "Give it a trigger, like jira for !jira." }
        if !t2.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) {
            return "A trigger is letters and numbers only, with no spaces."
        }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give it a name, like Jira." }
        if !url.contains("{q}") { return "Put {q} in the address where the search words go." }
        if safeURL(url.replacingOccurrences(of: "{q}", with: "x")) == nil { return "The address must start with https:// (or http://)." }
        return nil
    }

    /// A list with `bang` added (replacing any with its trigger) or nil if it isn't valid.
    public static func adding(_ bang: Bang, to list: [Bang]) -> [Bang]? {
        guard problem(trigger: bang.trigger, name: bang.name, url: bang.url) == nil else { return nil }
        let t = canonical(bang.trigger)
        let clean = Bang(trigger: t, name: bang.name.trimmingCharacters(in: .whitespaces),
                         url: bang.url.trimmingCharacters(in: .whitespaces), home: bang.home, agent: bang.isAgent)
        return list.filter { $0.trigger != t } + [clean]
    }

    /// The bang for a trigger, or nil if only DuckDuckGo would know it.
    public static func find(_ trigger: String, in list: [Bang]) -> Bang? {
        list.first { $0.trigger == trigger.lowercased() }
    }

    /// Bangs whose trigger starts with what's typed (or whose name matches), shortest trigger first.
    public static func suggest(_ partial: String, in list: [Bang], limit: Int = 12) -> [Bang] {
        let p = partial.lowercased()
        if p.isEmpty { return Array(list.prefix(limit)) }
        let byTrigger = list.filter { $0.trigger.hasPrefix(p) }.sorted { $0.trigger.count < $1.trigger.count }
        let byName = list.filter { !$0.trigger.hasPrefix(p) && Fuzzy.score(p, $0.name).map { $0 >= 500 } == true }
        return Array((byTrigger + byName).prefix(limit))
    }

    /// What DuckDuckGo should get for a bang it has to resolve: the bang and the words, as typed.
    public static func fallbackAddress(trigger: String, terms: String) -> URL? {
        fallback.address(for: "!\(trigger) \(terms)".trimmingCharacters(in: .whitespaces))
    }
}
