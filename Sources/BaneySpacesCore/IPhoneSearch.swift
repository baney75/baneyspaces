import Foundation

// The launcher and the iPhone's apps (Donovan, 2026-11-01, a 12:25 recording): "include in the search
// things like snapchat and have it open in the mirroring view." Typing "snapchat" gave web and install
// rows only. The Mac keeps no list of the phone's apps anyone can read here: no stubs on disk, nothing
// in Spotlight, and iPhone Mirroring's cache sits in its own protected container. So every search gets
// one row that asks iPhone Mirroring's own Spotlight (`IPhoneSearch.rows`), and apps come from a
// pluggable `IPhoneAppProvider`, empty today, that a cache parser fills later with "Snapchat · iPhone"
// rows. This file is the logic with no AppKit and no Accessibility: rows, ranking, the state
// Mirroring reports, and the open sequence, driven through a protocol so a fake Mirroring tests it.

/// An app on the phone, as a provider knows it.
public struct IPhoneApp: Equatable, Sendable {
    public let name: String
    public let bundleID: String?
    /// The app's icon as image data (PNG, JPEG, HEIC), when the source has one.
    public let icon: Data?
    public init(name: String, bundleID: String? = nil, icon: Data? = nil) {
        self.name = name
        self.bundleID = bundleID
        self.icon = icon
    }
}

/// Where the phone's apps come from. Today `NoIPhoneApps`; the cache parser (name, bundle id) plugs in here.
public protocol IPhoneAppProvider: Sendable {
    func apps() -> [IPhoneApp]
}

public struct NoIPhoneApps: IPhoneAppProvider {
    public init() {}
    public func apps() -> [IPhoneApp] { [] }
}

/// What iPhone Mirroring's window says about the connection, from the text it shows.
public enum IPhoneState: Equatable, Sendable {
    /// Connected, showing the phone's screen.
    case ready
    /// "Unlock Your iPhone".
    case needsUnlock
    /// "Unable to Connect to iPhone": not nearby, off, or its radios are off.
    case unavailable
    /// "Mac Locked".
    case macLocked
    /// "Connecting to …".
    case connecting
    /// Not running, or nothing readable.
    case unknown

    /// Mirroring's own titles for these states (its `Localizable.loctable`, in the Mac's language when the
    /// app can read them). English is the fallback.
    public struct Phrases: Equatable, Sendable {
        public var needsUnlock: String
        public var unavailable: String
        public var macLocked: String
        /// The words before "%@" in "Connecting to %@".
        public var connecting: String
        public init(needsUnlock: String = "Unlock Your iPhone", unavailable: String = "Unable to Connect to iPhone",
                    macLocked: String = "Mac Locked", connecting: String = "Connecting to") {
            self.needsUnlock = needsUnlock
            self.unavailable = unavailable
            self.macLocked = macLocked
            self.connecting = connecting
        }
        public static let english = Phrases()
    }

    /// The state the texts in Mirroring's window add up to, and the phrase Mirroring used for it.
    /// A state beats "connecting": "Unlock Your iPhone" shows while a connection is under way.
    public static func classify(_ texts: [String], phrases: Phrases = .english) -> (state: IPhoneState, phrase: String?) {
        func has(_ p: String) -> String? {
            texts.first { $0.range(of: p, options: [.caseInsensitive, .diacriticInsensitive]) != nil }.map { _ in p }
        }
        if let p = has(phrases.needsUnlock) { return (.needsUnlock, p) }
        if let p = has(phrases.unavailable) { return (.unavailable, p) }
        if let p = has(phrases.macLocked) { return (.macLocked, p) }
        if let p = has(phrases.connecting) { return (.connecting, p) }
        return texts.isEmpty ? (.unknown, nil) : (.ready, nil)
    }

    /// Whether a search can be typed into Mirroring now. An unreadable window is tried anyway: the
    /// phone's screen is video, and Accessibility shows no text for it.
    public var canSearch: Bool { self == .ready || self == .unknown }
}

/// A row the launcher shows for the phone.
public struct IPhoneRow: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// "Snapchat · iPhone", from a provider.
        case app(IPhoneApp)
        /// "Search iPhone for “…”".
        case search(String)
    }
    public let kind: Kind
    public let title: String
    public let subtitle: String
}

public enum IPhoneSearch {
    /// The most provider apps shown beside the search row.
    public static let appLimit = 3

    /// Rows for a query: matching provider apps first (ranked as apps are), then the search row, which is
    /// always there while iPhone Mirroring is installed and something is typed. `state` is what Mirroring
    /// last reported; a blocked state is shown on the rows instead of failing silently when one is pressed.
    public static func rows(_ typed: String, apps: [IPhoneApp], installed: Bool, state: IPhoneState = .unknown,
                            phrase: String? = nil) -> [IPhoneRow] {
        let q = typed.trimmingCharacters(in: .whitespaces)
        guard installed, !q.isEmpty else { return [] }
        let note = note(for: state, phrase: phrase)
        let matches = apps.compactMap { a -> (IPhoneApp, Int)? in Fuzzy.score(q, a.name).map { (a, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name < $1.0.name }
            .prefix(appLimit)
        var out = matches.map { m in
            IPhoneRow(kind: .app(m.0), title: "\(m.0.name) · iPhone", subtitle: note ?? "Opens it in iPhone Mirroring")
        }
        out.append(IPhoneRow(kind: .search(q), title: "Search iPhone for “\(q)”", subtitle: note ?? "Asks iPhone Mirroring's Spotlight"))
        return out
    }

    /// What to say on a row when Mirroring can't take a search: its own words for the state.
    public static func note(for state: IPhoneState, phrase: String?) -> String? {
        switch state {
        case .ready, .unknown: return nil
        case .needsUnlock: return phrase ?? IPhoneState.Phrases.english.needsUnlock
        case .unavailable: return phrase ?? IPhoneState.Phrases.english.unavailable
        case .macLocked: return phrase ?? IPhoneState.Phrases.english.macLocked
        case .connecting: return phrase ?? IPhoneState.Phrases.english.connecting
        }
    }

    /// Whether a menu item is Mirroring's Spotlight. `known` are its own titles for it (read from its
    /// resources, in the Mac's language); "Spotlight" is the word in every language that has the feature,
    /// so the title containing it counts too. Never a title that also holds another menu's word.
    public static func isSpotlightItem(_ title: String, known: [String]) -> Bool {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        if known.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) { return true }
        return t.range(of: "spotlight", options: .caseInsensitive) != nil && t.count <= 40
    }
}

/// iPhone Mirroring, as the open sequence needs it. The live one is Accessibility and keys posted to
/// Mirroring's own pid; tests use a fake.
public protocol MirroringDriver: AnyObject {
    /// Starts or comes to the front for the target workspace (open here), and waits for its window.
    /// False when no window appeared.
    func bringUp() -> Bool
    /// What the window says about the connection.
    func state() -> IPhoneState
    /// Opens Mirroring's Spotlight through its menu bar. False when the menu has no such item.
    func openSpotlight() -> Bool
    /// Types into the window: the Accessibility value of a field it exposes, else keys posted to
    /// Mirroring's pid only, never to the system. False when nothing was sent.
    func type(_ text: String) -> Bool
}

public enum IPhoneOpen {
    public enum Outcome: Equatable, Sendable {
        /// Typed into Mirroring's Spotlight. What the phone then shows is video: it can't be checked.
        case asked(String)
        /// Mirroring says it can't (locked, not nearby, Mac locked, still connecting); nothing was typed.
        case blocked(IPhoneState)
        case noWindow
        case noSpotlightItem
        case typingFailed
    }

    /// The sequence: bring Mirroring up for the target, read its state, open its Spotlight, type the query.
    public static func run(_ query: String, driver: MirroringDriver) -> Outcome {
        guard driver.bringUp() else { return .noWindow }
        let state = driver.state()
        guard state.canSearch else { return .blocked(state) }
        guard driver.openSpotlight() else { return .noSpotlightItem }
        return driver.type(query) ? .asked(query) : .typingFailed
    }

    /// What the launcher says when it's over. An opened search is "asked", never "opened": the phone's
    /// screen can't be read, so whether Snapchat opened isn't known.
    public static func message(_ outcome: Outcome, phrase: String? = nil) -> String {
        switch outcome {
        case .asked(let q): return "Opened iPhone Mirroring and asked for “\(q)”"
        case .blocked(let s): return IPhoneSearch.note(for: s, phrase: phrase) ?? "iPhone Mirroring can't search now"
        case .noWindow: return "iPhone Mirroring didn't open a window"
        case .noSpotlightItem: return "iPhone Mirroring has no Spotlight menu item"
        case .typingFailed: return "Couldn't type into iPhone Mirroring"
        }
    }
}

/// Finding the phone's apps in whatever iPhone Mirroring keeps, without knowing its format. The container
/// can only be read by BaneySpaces after macOS asks you (nobody could read it first), so this tolerates
/// shapes it has never seen: it walks any property list or JSON for dictionaries that pair a name with a
/// bundle identifier, and `shape(of:)` describes a structure by its key names and types only, never a
/// value, so a diagnostic can say what the format is without leaving anything personal in a log.
public enum IPhoneAppParse {
    static let nameKeys = ["CFBundleDisplayName", "displayName", "localizedName", "appName", "applicationName", "name", "title", "CFBundleName", "label"]
    static let bundleKeys = ["bundleIdentifier", "bundleID", "bundleId", "CFBundleIdentifier", "appBundleIdentifier", "applicationIdentifier", "appID", "identifier"]
    static let iconKeys = ["iconData", "icon", "iconImage", "iconImageData", "appIcon", "image", "imageData"]

    /// "com.toyopagroup.picaboo": reverse-DNS, at least two dots, letters, digits, `-` and `_`.
    public static func looksLikeBundleID(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 3 && s.count <= 155 && parts.allSatisfy { p in
            !p.isEmpty && p.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }

    private static func string(_ d: [String: Any], _ keys: [String]) -> String? {
        for k in keys {
            if let hit = d.first(where: { $0.key.caseInsensitiveCompare(k) == .orderedSame }), let v = hit.value as? String,
               !v.trimmingCharacters(in: .whitespaces).isEmpty { return v }
        }
        return nil
    }

    private static func data(_ d: [String: Any]) -> Data? {
        for k in iconKeys {
            if let hit = d.first(where: { $0.key.caseInsensitiveCompare(k) == .orderedSame }), let v = hit.value as? Data, v.count > 16 { return v }
        }
        return nil
    }

    /// Every app found anywhere in a property list or JSON object: a dictionary with a name and a bundle id,
    /// or a dictionary keyed by bundle ids whose values carry a name. First sighting of a bundle id wins.
    public static func apps(in object: Any) -> [IPhoneApp] {
        var found: [IPhoneApp] = []
        var seen = Set<String>()
        func add(_ name: String, _ id: String?, _ icon: Data?) {
            let key = (id ?? name).lowercased()
            guard seen.insert(key).inserted else { return }
            found.append(IPhoneApp(name: name.trimmingCharacters(in: .whitespaces), bundleID: id, icon: icon))
        }
        func walk(_ o: Any, depth: Int) {
            guard depth < 12 else { return }
            if let d = o as? [String: Any] {
                if let id = string(d, bundleKeys), looksLikeBundleID(id), let name = string(d, nameKeys) {
                    add(name, id, data(d))
                } else {
                    for (k, v) in d {
                        if looksLikeBundleID(k), let inner = v as? [String: Any], let name = string(inner, nameKeys) {
                            add(name, k, data(inner))
                        }
                    }
                }
                for v in d.values { walk(v, depth: depth + 1) }
            } else if let a = o as? [Any] {
                for v in a { walk(v, depth: depth + 1) }
            }
        }
        walk(object, depth: 0)
        return found
    }

    /// The structure of an object by key names and types: no strings, numbers or data. A key that is a
    /// bundle id is shown as `<bundle-id>`. Arrays show their count and the shape of their first element.
    public static func shape(of object: Any, depth: Int = 0, maxDepth: Int = 6) -> String {
        let pad = String(repeating: "  ", count: depth)
        if depth > maxDepth { return pad + "…\n" }
        if let d = object as? [String: Any] {
            var out = pad + "dict(\(d.count))\n"
            let keys = d.keys.sorted()
            let ids = keys.filter(looksLikeBundleID)
            for k in keys where !looksLikeBundleID(k) {
                out += pad + "  \(k):\n" + shape(of: d[k]!, depth: depth + 2, maxDepth: maxDepth)
            }
            if let first = ids.first {
                out += pad + "  <bundle-id> × \(ids.count):\n" + shape(of: d[first]!, depth: depth + 2, maxDepth: maxDepth)
            }
            return out
        }
        if let a = object as? [Any] {
            var out = pad + "array(\(a.count))\n"
            if let first = a.first { out += shape(of: first, depth: depth + 1, maxDepth: maxDepth) }
            return out
        }
        if object is Data { return pad + "data\n" }
        if object is Date { return pad + "date\n" }
        if let n = object as? NSNumber { return pad + (CFGetTypeID(n) == CFBooleanGetTypeID() ? "bool\n" : "number\n") }
        if object is String { return pad + "string\n" }
        return pad + "\(type(of: object))\n"
    }

    /// A table's columns that hold a name and a bundle id, if it has both: what to select to get apps.
    public static func appColumns(_ columns: [String]) -> (name: String, bundle: String, icon: String?)? {
        func pick(_ keys: [String]) -> String? {
            for k in keys { if let c = columns.first(where: { $0.caseInsensitiveCompare(k) == .orderedSame || $0.lowercased().replacingOccurrences(of: "_", with: "") == k.lowercased() || $0.lowercased() == "z" + k.lowercased() }) { return c } }
            return nil
        }
        guard let b = pick(bundleKeys), let n = pick(nameKeys), n != b else { return nil }
        return (n, b, pick(iconKeys))
    }
}
