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
    public init(name: String, bundleID: String? = nil) {
        self.name = name
        self.bundleID = bundleID
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
