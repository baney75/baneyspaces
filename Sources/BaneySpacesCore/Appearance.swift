import Foundation

/// A color as three 0...1 channels, so the look can be saved, compared and tested without AppKit.
public struct RGB: Codable, Equatable, Hashable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = RGB.clamp(r); self.g = RGB.clamp(g); self.b = RGB.clamp(b)
    }

    private static func clamp(_ v: Double) -> Double { min(1, max(0, v)) }

    private enum CodingKeys: String, CodingKey { case r, g, b }

    /// A saved color outside 0...1 is brought back in, as `init(r:g:b:)` does.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(r: try c.decode(Double.self, forKey: .r), g: try c.decode(Double.self, forKey: .g), b: try c.decode(Double.self, forKey: .b))
    }

    /// "#RRGGBB" in capitals.
    public var hex: String {
        func byte(_ v: Double) -> Int { Int((v * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }

    /// Reads "#RRGGBB" or "RRGGBB"; anything else is nil.
    public init?(hex text: String) {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, s.allSatisfy(\.isHexDigit), let v = UInt32(s, radix: 16) else { return nil }
        self.init(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255)
    }

    /// WCAG relative luminance: 0 for black, 1 for white.
    public var luminance: Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// WCAG contrast of white text on this color, from 1 (none) to 21.
    public var contrastWithWhite: Double { 1.05 / (luminance + 0.05) }

    public var hsb: HSB {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return HSB(h: h, s: mx == 0 ? 0 : d / mx, b: mx)
    }
}

/// A color as hue, saturation and brightness, the form the workspace palettes are written in.
public struct HSB: Equatable {
    public var h: Double
    public var s: Double
    public var b: Double

    public init(h: Double, s: Double, b: Double) { self.h = h; self.s = s; self.b = b }

    public var rgb: RGB {
        let hue = (h - h.rounded(.down)) * 6
        let i = Int(hue) % 6, f = hue - Double(Int(hue))
        let p = b * (1 - s), q = b * (1 - s * f), t = b * (1 - s * (1 - f))
        switch i {
        case 0: return RGB(r: b, g: t, b: p)
        case 1: return RGB(r: q, g: b, b: p)
        case 2: return RGB(r: p, g: b, b: t)
        case 3: return RGB(r: p, g: q, b: b)
        case 4: return RGB(r: t, g: p, b: b)
        default: return RGB(r: b, g: p, b: q)
        }
    }
}

public enum AccentPreset: String, Codable, CaseIterable, Equatable {
    case red, orange, yellow, green, teal, blue, purple, pink, graphite

    public var title: String { rawValue.capitalized }

    /// Red is the accent BaneySpaces has always had.
    public var rgb: RGB {
        switch self {
        case .red: RGB(r: 0.91, g: 0.26, b: 0.29)
        case .orange: RGB(r: 0.96, g: 0.55, b: 0.18)
        case .yellow: RGB(r: 0.96, g: 0.78, b: 0.20)
        case .green: RGB(r: 0.20, g: 0.74, b: 0.36)
        case .teal: RGB(r: 0.19, g: 0.69, b: 0.71)
        case .blue: RGB(r: 0.20, g: 0.51, b: 0.97)
        case .purple: RGB(r: 0.64, g: 0.37, b: 0.87)
        case .pink: RGB(r: 0.94, g: 0.36, b: 0.62)
        case .graphite: RGB(r: 0.55, g: 0.57, b: 0.60)
        }
    }
}

public enum AccentChoice: Codable, Equatable {
    case preset(AccentPreset)
    /// macOS's accent color, which follows System Settings.
    case system
    case custom(RGB)
}

public enum WorkspacePalette: String, Codable, CaseIterable, Equatable {
    case rainbow, accent, calm, mono

    public var title: String {
        switch self {
        case .rainbow: "Rainbow"
        case .accent: "Accent"
        case .calm: "Calm"
        case .mono: "Mono"
        }
    }
}

public enum PanelStyle: String, Codable, CaseIterable, Equatable {
    case glass, tinted, solid

    public var title: String { rawValue.capitalized }
}

public enum DockSize: String, Codable, CaseIterable, Equatable {
    case small, medium, large

    public var title: String { rawValue.capitalized }

    /// How much the dock's tiles and icons are scaled; Medium is the size it has always had.
    public var scale: Double {
        switch self {
        case .small: 0.85
        case .medium: 1
        case .large: 1.2
        }
    }
}

/// Everything a person can change about how BaneySpaces looks. The defaults are the look it
/// shipped with, so a fresh install is unchanged.
public struct AppearanceSettings: Codable, Equatable {
    public var accent: AccentChoice = .preset(.red)
    public var palette: WorkspacePalette = .rainbow
    /// A color picked for one workspace (1...9); it wins over the palette.
    public var overrides: [Int: RGB] = [:]
    public var panelStyle: PanelStyle = .glass
    /// How solid the panels' dark fill is. 0.88 is what they have always used.
    public var panelOpacity: Double = AppearanceSettings.defaultPanelOpacity
    public var dockSize: DockSize = .medium

    public static let defaultPanelOpacity = 0.88
    public static let panelOpacityRange: ClosedRange<Double> = 0.6...1.0
    /// How much of the accent a Tinted panel washes over its glass.
    public static let tintWash = 0.14
    public static let userDefaultsKey = "appearance"

    public init() {}

    private enum CodingKeys: String, CodingKey { case accent, palette, overrides, panelStyle, panelOpacity, dockSize }

    /// Each field on its own: one missing or unreadable (a newer build's value, an older build's
    /// blob) takes its default and leaves the rest as saved.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accent = (try? c.decodeIfPresent(AccentChoice.self, forKey: .accent)) ?? accent
        palette = (try? c.decodeIfPresent(WorkspacePalette.self, forKey: .palette)) ?? palette
        overrides = (try? c.decodeIfPresent([Int: RGB].self, forKey: .overrides)) ?? overrides
        panelStyle = (try? c.decodeIfPresent(PanelStyle.self, forKey: .panelStyle)) ?? panelStyle
        panelOpacity = (try? c.decodeIfPresent(Double.self, forKey: .panelOpacity)) ?? panelOpacity
        dockSize = (try? c.decodeIfPresent(DockSize.self, forKey: .dockSize)) ?? dockSize
    }

    // MARK: Saving

    public func encoded() -> Data? {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try? e.encode(self)
    }

    /// The saved settings; anything missing or unreadable is the default look.
    public static func decoded(_ data: Data?) -> AppearanceSettings {
        guard let data, var s = try? JSONDecoder().decode(AppearanceSettings.self, from: data) else { return AppearanceSettings() }
        s.panelOpacity = min(panelOpacityRange.upperBound, max(panelOpacityRange.lowerBound, s.panelOpacity))
        s.overrides = s.overrides.filter { (1...9).contains($0.key) }
        return s
    }

    public static func load(from defaults: UserDefaults = .standard) -> AppearanceSettings {
        decoded(defaults.data(forKey: userDefaultsKey))
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = encoded() { defaults.set(data, forKey: AppearanceSettings.userDefaultsKey) }
    }

    // MARK: Looks

    /// The accent as a color; `system` is macOS's accent, which only the app can read.
    public func accentRGB(system: RGB) -> RGB {
        switch accent {
        case .preset(let p): p.rgb
        case .system: system
        case .custom(let c): c
        }
    }

    /// Workspace `n`'s color: its own pick if there is one, else the palette's. Text is white
    /// on it, so brightness is held down.
    public func workspaceColor(_ n: Int, accent accentColor: RGB) -> HSB {
        let n = max(1, min(9, n))
        if let own = overrides[n] { return AppearanceSettings.readable(own.hsb) }
        return AppearanceSettings.paletteColor(palette, n, accent: accentColor)
    }

    /// The fill opacity of a panel: Solid is always opaque.
    public var effectivePanelOpacity: Double {
        panelStyle == .solid ? 1 : min(AppearanceSettings.panelOpacityRange.upperBound, max(AppearanceSettings.panelOpacityRange.lowerBound, panelOpacity))
    }

    /// How dark the overview's scrim over the blurred screen is. 0.35 is what it has always been
    /// at the default opacity; the opacity slider moves it from lighter to darker.
    public var overviewDim: Double {
        min(0.6, max(0.1, 0.35 + (effectivePanelOpacity - AppearanceSettings.defaultPanelOpacity) * 1.5))
    }

    public mutating func resetOverrides() { overrides = [:] }

    // MARK: Palettes

    /// Hues around the color wheel so neighbors never look alike.
    public static let rainbowHues: [Double] = [0.0, 0.07, 0.12, 0.33, 0.47, 0.55, 0.62, 0.74, 0.86]

    /// Yellow-green hues read lighter, so they get a little less brightness for white text.
    public static func isLightHue(_ h: Double) -> Bool { (0.10...0.36).contains(h) }

    /// The most light a workspace color may give off with white text on it: that of the brightest
    /// of the nine Rainbow colors, so the defaults are untouched.
    public static let maxLuminance: Double = (1...9).map { paletteColor(.rainbow, $0, accent: AccentPreset.red.rgb).rgb.luminance }.max() ?? 0.5

    /// The brightest a color of this hue and saturation may be (0...1) and stay within `maxLuminance`.
    public static func maxBrightness(hue h: Double, saturation s: Double) -> Double {
        if HSB(h: h, s: s, b: 1).rgb.luminance <= maxLuminance { return 1 }
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if HSB(h: h, s: s, b: mid).rgb.luminance <= maxLuminance { lo = mid } else { hi = mid }
        }
        return lo
    }

    /// Lowers a color's brightness until white text reads on it as well as on the brightest default.
    public static func readable(_ c: HSB) -> HSB {
        // Already as dark as the brightest default: left exactly as it is.
        if c.rgb.luminance <= maxLuminance + 1e-9 { return c }
        return HSB(h: c.h, s: c.s, b: min(c.b, maxBrightness(hue: c.h, saturation: c.s)))
    }

    public static func paletteColor(_ palette: WorkspacePalette, _ n: Int, accent: RGB) -> HSB {
        let n = max(1, min(9, n))
        let t = Double(n - 1) / 8
        let h = rainbowHues[n - 1]
        switch palette {
        case .rainbow:
            return HSB(h: h, s: 0.62, b: isLightHue(h) ? 0.68 : 0.80)
        case .calm:
            return HSB(h: h, s: 0.32, b: isLightHue(h) ? 0.56 : 0.64)
        case .mono:
            return HSB(h: 0, s: 0, b: 0.34 + t * 0.26)
        case .accent:
            // Nine steps from dark to light in the accent's own hue.
            let a = accent.hsb
            let s = a.s < 0.15 ? a.s : min(0.85, max(0.45, a.s)) - 0.2 * t
            let top = min(0.9, maxBrightness(hue: a.h, saturation: s))
            return HSB(h: a.h, s: s, b: 0.34 + t * (top - 0.34))
        }
    }
}
