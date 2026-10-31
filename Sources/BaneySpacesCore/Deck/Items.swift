import Foundation

/// What an app is to Ghostdeck. The role picks the kind of row; the adapter picks how deep
/// Ghostdeck can see into it.
public enum Role: String, Codable, Sendable, CaseIterable {
    case terminal, agent, browser, device, other

    public var title: String {
        switch self {
        case .terminal: return "Terminals"
        case .agent: return "Agents"
        case .browser: return "Browser"
        case .device: return "Phones"
        case .other: return "Apps"
        }
    }
}

/// How Ghostdeck reads an app. Scripted adapters see tabs and splits; `.windows` sees only windows,
/// through Accessibility, and works for any app at all.
public enum Adapter: String, Codable, Sendable {
    /// Ghostty's AppleScript dictionary (1.3+): windows, tabs, splits, folders.
    case ghostty
    /// Chromium's AppleScript dictionary: every tab with its title and URL. Helium, Chrome, Brave, Arc, Edge, Vivaldi.
    case chromium
    /// Terminal.app: tabs with their tty.
    case terminalApp
    /// iTerm2: sessions with their tty.
    case iterm
    /// Any app: its windows and their titles.
    case windows
}

public struct AppSpec: Equatable, Sendable, Codable {
    public let bundleID: String
    public let name: String
    public let role: Role
    public let adapter: Adapter

    public init(bundleID: String, name: String, role: Role, adapter: Adapter) {
        self.bundleID = bundleID; self.name = name; self.role = role; self.adapter = adapter
    }
}

/// The apps Ghostdeck wraps without being told. Anything else can be added by bundle ID in
/// `~/.config/ghostdeck/config.json`, and the default browser joins automatically.
public enum Catalog {
    public static let known: [AppSpec] = [
        AppSpec(bundleID: "com.mitchellh.ghostty", name: "Ghostty", role: .terminal, adapter: .ghostty),
        AppSpec(bundleID: "com.apple.Terminal", name: "Terminal", role: .terminal, adapter: .terminalApp),
        AppSpec(bundleID: "com.googlecode.iterm2", name: "iTerm", role: .terminal, adapter: .iterm),
        AppSpec(bundleID: "com.github.wez.wezterm", name: "WezTerm", role: .terminal, adapter: .windows),
        AppSpec(bundleID: "net.kovidgoyal.kitty", name: "kitty", role: .terminal, adapter: .windows),
        AppSpec(bundleID: "org.alacritty", name: "Alacritty", role: .terminal, adapter: .windows),
        AppSpec(bundleID: "dev.warp.Warp-Stable", name: "Warp", role: .terminal, adapter: .windows),
        AppSpec(bundleID: "com.cmuxterm.app", name: "cmux", role: .terminal, adapter: .windows),
        AppSpec(bundleID: "com.anthropic.claudefordesktop", name: "Claude", role: .agent, adapter: .windows),
        AppSpec(bundleID: "com.openai.codex", name: "ChatGPT", role: .agent, adapter: .windows),
        AppSpec(bundleID: "com.openai.chat", name: "ChatGPT", role: .agent, adapter: .windows),
        AppSpec(bundleID: "com.t3tools.t3code", name: "T3 Code", role: .agent, adapter: .windows),
        AppSpec(bundleID: "com.anysphere.sand", name: "Grok Bot", role: .agent, adapter: .windows),
        AppSpec(bundleID: "com.apple.ScreenContinuity", name: "iPhone Mirroring", role: .device, adapter: .windows),
        AppSpec(bundleID: "com.apple.dt.Devices", name: "Device Hub", role: .device, adapter: .windows),
        AppSpec(bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor", role: .agent, adapter: .windows),
        AppSpec(bundleID: "com.microsoft.VSCode", name: "VS Code", role: .agent, adapter: .windows),
        AppSpec(bundleID: "dev.zed.Zed", name: "Zed", role: .agent, adapter: .windows),
        AppSpec(bundleID: "net.imput.helium", name: "Helium", role: .browser, adapter: .chromium),
        AppSpec(bundleID: "com.google.Chrome", name: "Chrome", role: .browser, adapter: .chromium),
        AppSpec(bundleID: "com.brave.Browser", name: "Brave", role: .browser, adapter: .chromium),
        AppSpec(bundleID: "company.thebrowser.Browser", name: "Arc", role: .browser, adapter: .chromium),
        AppSpec(bundleID: "com.microsoft.edgemac", name: "Edge", role: .browser, adapter: .chromium),
        AppSpec(bundleID: "com.vivaldi.Vivaldi", name: "Vivaldi", role: .browser, adapter: .chromium),
        AppSpec(bundleID: "com.apple.Safari", name: "Safari", role: .browser, adapter: .windows),
        AppSpec(bundleID: "org.mozilla.firefox", name: "Firefox", role: .browser, adapter: .windows),
    ]

    /// The apps to wrap: every terminal and agent app Ghostdeck knows, only the default browser
    /// (so a second installed browser doesn't crowd the list), then whatever the config adds.
    public static func wrapped(defaultBrowser: String?, extra: [AppSpec] = [], excluded: Set<String> = []) -> [AppSpec] {
        var out = known.filter { $0.role != .browser || $0.bundleID == defaultBrowser }
        if let b = defaultBrowser, !out.contains(where: { $0.bundleID == b }) {
            out.append(AppSpec(bundleID: b, name: b.split(separator: ".").last.map(String.init) ?? b, role: .browser, adapter: .windows))
        }
        for e in extra {
            out.removeAll { $0.bundleID == e.bundleID }
            out.append(e)
        }
        return out.filter { !excluded.contains($0.bundleID) }
    }
}

/// One thing the Deck lists: a terminal split, a browser tab, or a whole window.
public struct Item: Identifiable, Equatable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case terminal, tab, window, device }

    /// Stable while the thing exists: `ghostty:<terminal>`, `tab:<bundle>:<tab id>`, `win:<CGWindowID>`.
    public var id: String
    public var bundleID: String
    public var appName: String
    public var role: Role
    public var kind: Kind
    /// The macOS window it lives in, 0 when not known yet.
    public var windowNumber: UInt32
    /// Groups rows under one window header: the app's own window ID, or the CGWindowID.
    public var group: String
    public var title: String
    /// A folder for terminals, a host for browser tabs, empty for windows.
    public var detail: String
    public var directory: String
    public var tty: String
    public var activity: Activity
    /// The one you're typing into (its app is in front and this is its focused tab or split).
    public var focused: Bool
    /// A split under its tab's first terminal.
    public var nested: Bool
    /// The BaneySpaces workspace it's on when that isn't the current one; 0 when it's here.
    public var workspace: Int = 0
    /// Set by an agent hook: "claude", say, when a hook reports for this row.
    public var agent: String = ""
    /// What the agent said it's waiting for ("Claude needs your permission to use Bash").
    public var notice: String = ""

    public init(id: String, bundleID: String, appName: String, role: Role, kind: Kind, windowNumber: UInt32 = 0,
                group: String, title: String, detail: String = "", directory: String = "", tty: String = "",
                activity: Activity = .shell, focused: Bool = false, nested: Bool = false) {
        self.id = id; self.bundleID = bundleID; self.appName = appName; self.role = role; self.kind = kind
        self.windowNumber = windowNumber; self.group = group; self.title = title; self.detail = detail
        self.directory = directory; self.tty = tty; self.activity = activity; self.focused = focused; self.nested = nested
    }

    /// The title without Claude's status glyph, or the folder when there's no title.
    public var label: String {
        let l = Activity.label(of: title)
        if !l.isEmpty { return l }
        return directory.isEmpty ? appName : Snapshot.shortPath(directory)
    }
}

extension Activity: Codable {
    public init(from decoder: Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "working": self = .working
        case "waiting": self = .waiting
        default: self = .shell
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode("\(self)")
    }
}

public enum URLDisplay {
    /// "github.com/baney75" for a URL, the input when it isn't one.
    public static func short(_ url: String) -> String {
        guard let u = URL(string: url), let host = u.host else { return url }
        let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = u.path == "/" ? "" : u.path
        let s = h + path
        return s.count > 60 ? String(s.prefix(59)) + "…" : s
    }
}
