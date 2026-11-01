import Foundation

// Shared themes and palettes (spec/themes.md). A theme is shape, type and motion; a palette is
// color. Both come from the spec files, embedded as `ThemeData` so the app needs no resource
// bundle; `ThemeDataTests` fails when the embedded copy and spec/ differ.

public enum ThemeID: String, Codable, CaseIterable, Equatable, Sendable {
    case baneyspaces, omarchy, minimal

    /// What macOS draws without being asked: the look it has always had.
    public static let macDefault: ThemeID = .baneyspaces

    public var title: String { ThemeCatalog.shared.spec(self).label }
}

public enum ThemeIndicator: String, Decodable, Equatable, Sendable {
    case dot, bar
    case numberBlock = "number-block"
}

/// One theme as written in themes.json: the values every surface reads.
public struct ThemeSpec: Decodable, Equatable, Sendable {
    public struct Radius: Decodable, Equatable, Sendable { public let bar, tile, row, list: Double }
    public struct Border: Decodable, Equatable, Sendable {
        public let width: Double
        public let role: String
        /// The role's opacity, when the border has one flat opacity.
        public let opacity: Double?
        /// Opacity at the top and at the bottom, for a border that fades.
        public let gradient: [Double]?
        public let focusedRole: String
        public let focusedWidth: Double
    }
    public struct Fill: Decodable, Equatable, Sendable {
        /// `ultra-thin` is macOS's `.ultraThinMaterial`; nil is an opaque fill.
        public let material: String?
        public let tintRole: String
        public let tintOpacity: Double
        public let opacity: Double
        public let adjustable: Bool
        public var blur: Bool { material != nil }
    }
    public struct Shadow: Decodable, Equatable, Sendable { public let radius, y, opacity: Double }
    public struct Font: Decodable, Equatable, Sendable {
        public let family: String
        public let size: Double
        public let weight: String
    }
    public struct Space: Decodable, Equatable, Sendable { public let gap, padding, tile: Double }
    public struct Motion: Decodable, Equatable, Sendable {
        public let inMs, outMs, listInMs, listOutMs, rowMs: Double
        public let scaleFrom, lift: Double
    }

    public let label: String
    public let radius: Radius
    public let border: Border
    public let fill: Fill
    public let shadow: Shadow?
    public let font: Font
    public let space: Space
    public let indicator: ThemeIndicator
    public let motion: Motion
}

public struct ThemeCatalog: Sendable {
    public let themes: [String: ThemeSpec]
    /// font key -> platform -> families, in order of preference.
    public let fonts: [String: [String: [String]]]

    private struct File: Decodable {
        let version: Int
        let themes: [String: ThemeSpec]
        let fonts: [String: [String: [String]]]
    }

    /// Nil when the text isn't a themes.json this build understands.
    public static func parse(_ text: String) -> ThemeCatalog? {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        guard let f = try? d.decode(File.self, from: Data(text.utf8)), f.version == 1,
              ThemeID.allCases.allSatisfy({ f.themes[$0.rawValue] != nil }) else { return nil }
        return ThemeCatalog(themes: f.themes, fonts: f.fonts)
    }

    public static let shared: ThemeCatalog = {
        guard let c = parse(ThemeData.themesJSON) else { fatalError("the embedded themes.json is unreadable") }
        return c
    }()

    public func spec(_ id: ThemeID) -> ThemeSpec { themes[id.rawValue]! }

    public func fontFamilies(_ key: String, platform: String = "macos") -> [String] { fonts[key]?[platform] ?? [] }
}

// MARK: Palettes

/// A palette: one color for each role (background, surface, sunken, foreground, strong, muted,
/// border, accent, selection, urgent, working, done).
public struct Palette: Equatable, Sendable, Identifiable {
    public let name: String
    public let isDark: Bool
    public let colors: [String: RGB]
    public var id: String { name }

    public static let roles = ["background", "surface", "sunken", "foreground", "strong", "muted",
                               "border", "accent", "selection", "urgent", "working", "done"]

    public func color(_ role: String) -> RGB? { colors[role] }

    /// "auto" on macOS: the BaneySpaces defaults the panels have always drawn (near-black, white
    /// text) with the accent chosen in Settings. Dark in light mode too, as the panels always were.
    public static func auto(accent: RGB) -> Palette {
        func g(_ v: Double) -> RGB { RGB(r: v, g: v, b: v) }
        return Palette(name: "auto", isDark: true, colors: [
            "background": g(0.07), "surface": g(0.13), "sunken": g(0),
            "foreground": g(1), "strong": g(1), "muted": g(0.55),
            "border": g(0.30), "accent": accent, "selection": g(0.19),
            "urgent": AccentPreset.red.rgb, "working": AccentPreset.yellow.rgb, "done": AccentPreset.green.rgb,
        ])
    }
}

public struct PaletteCatalog: Sendable {
    /// In name order.
    public let palettes: [Palette]

    private struct File: Decodable {
        let roles: [String]
        let palettes: [String: [String: String]]
    }

    public static func parse(_ text: String) -> PaletteCatalog? {
        guard let f = try? JSONDecoder().decode(File.self, from: Data(text.utf8)), f.roles == Palette.roles else { return nil }
        var list: [Palette] = []
        for (name, entry) in f.palettes {
            var colors: [String: RGB] = [:]
            for role in f.roles {
                guard let hex = entry[role], let c = RGB(hex: hex) else { return nil }
                colors[role] = c
            }
            list.append(Palette(name: name, isDark: entry["mode"] != "light", colors: colors))
        }
        return PaletteCatalog(palettes: list.sorted { $0.name < $1.name })
    }

    public static let shared: PaletteCatalog = {
        guard let c = parse(ThemeData.palettesJSON) else { fatalError("the embedded palettes.json is unreadable") }
        return c
    }()

    public var names: [String] { palettes.map(\.name) }
    public func named(_ name: String) -> Palette? { palettes.first { $0.name == name } }
}

// MARK: Look

/// A theme and a palette together: what every surface draws from.
public struct Look: Equatable, Sendable {
    public var theme: ThemeID
    public var spec: ThemeSpec
    public var palette: Palette
    /// The palette is `auto`.
    public var isAuto: Bool

    public init(theme: ThemeID, palette name: String, accent: RGB) {
        self.theme = theme
        spec = ThemeCatalog.shared.spec(theme)
        if let p = PaletteCatalog.shared.named(name) {
            palette = p; isAuto = false
        } else {
            palette = Palette.auto(accent: accent); isAuto = true
        }
    }

    /// A role's color. `light` is plain white and `workspace` the workspace's own tint (the accent
    /// where there is none); every other role is the palette's.
    public func color(_ role: String, workspace: RGB? = nil) -> RGB {
        switch role {
        case "light": return RGB(r: 1, g: 1, b: 1)
        case "workspace": return workspace ?? palette.color("accent") ?? RGB(r: 1, g: 1, b: 1)
        default: return palette.color(role) ?? palette.color("foreground") ?? RGB(r: 1, g: 1, b: 1)
        }
    }
}

// MARK: The theme in use

/// The theme drawn right now, for code (like `DockMotion`) that has no view to ask. The app sets it
/// when Settings, the CLI or a saved setting changes the theme; it is the BaneySpaces theme until
/// then, so everything that reads it matches what shipped.
public enum ThemeCenter {
    private static let lock = NSLock()
    private static var currentID: ThemeID = .macDefault
    private static var currentSpec = ThemeCatalog.shared.spec(.macDefault)

    public static var id: ThemeID { lock.lock(); defer { lock.unlock() }; return currentID }
    public static var spec: ThemeSpec { lock.lock(); defer { lock.unlock() }; return currentSpec }

    public static func use(_ id: ThemeID) {
        lock.lock(); defer { lock.unlock() }
        currentID = id
        currentSpec = ThemeCatalog.shared.spec(id)
    }
}
