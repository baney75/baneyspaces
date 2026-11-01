import CoreGraphics
import Foundation

/// How an agent's cursor looks and moves. A theme is shape, size and motion, drawn with Core Animation layers
/// (no Lottie, no images). Colors are the cursor's own and never the palette's, so agent activity is never
/// mistaken for yours (spec/themes.md): the arrow takes its agent's status color from the Deck.
public struct CursorTheme: Equatable, Codable, Sendable {
    public enum Glyph: String, Codable, Sendable { case arrow, classic, dot, block }
    public enum BadgeShape: String, Codable, Sendable { case pill, square }
    public enum Fill: String, Codable, Sendable {
        /// The agent's status color.
        case status
        /// White with a black edge (the macOS look); the badge carries the status color.
        case light
    }

    public var name: String
    public var glyph: Glyph
    public var fill: Fill
    /// The glyph's height in points (a dot's diameter).
    public var size: Double
    /// Width of the ring in the agent's identity color around the glyph.
    public var ringWidth: Double
    public var shadowRadius: Double
    public var shadowOpacity: Double
    public var badgeShape: BadgeShape
    public var badgeRadius: Double
    public var badgeFontSize: Double
    public var badgeMonospaced: Bool
    /// Badge position from the tip, y down.
    public var badgeOffsetX: Double
    public var badgeOffsetY: Double
    public var rippleRadius: Double
    public var rippleDuration: Double
    public var rippleSquare: Bool
    /// The glyph's scale at the bottom of a press; 1 means no squish.
    public var squish: Double
    /// Fade and appear animations scale from this; 1 means fades only.
    public var appearScale: Double
    public var focusRadius: Double
    public var focusWidth: Double
    /// How many marks stay on screen, and for how long (seconds) the newest stays.
    public var markCount: Int
    public var markLife: Double

    public static let defaultName = "default"

    /// The friendly arrow.
    public static let standard = CursorTheme(
        name: "default", glyph: .arrow, fill: .status, size: 26, ringWidth: 1.5, shadowRadius: 4, shadowOpacity: 0.35,
        badgeShape: .pill, badgeRadius: 8, badgeFontSize: 11, badgeMonospaced: false, badgeOffsetX: 16, badgeOffsetY: 24,
        rippleRadius: 30, rippleDuration: 0.45, rippleSquare: false, squish: 0.8, appearScale: 0.6,
        focusRadius: 6, focusWidth: 2, markCount: 3, markLife: 1.6)

    /// A small dot and its badge.
    public static let minimal = CursorTheme(
        name: "minimal", glyph: .dot, fill: .status, size: 10, ringWidth: 1.5, shadowRadius: 2, shadowOpacity: 0.3,
        badgeShape: .pill, badgeRadius: 6, badgeFontSize: 10, badgeMonospaced: false, badgeOffsetX: 9, badgeOffsetY: 9,
        rippleRadius: 18, rippleDuration: 0.35, rippleSquare: false, squish: 0.75, appearScale: 0.5,
        focusRadius: 4, focusWidth: 1.5, markCount: 3, markLife: 1.2)

    /// The macOS arrow: white with a black edge.
    public static let classic = CursorTheme(
        name: "classic", glyph: .classic, fill: .light, size: 24, ringWidth: 0, shadowRadius: 3, shadowOpacity: 0.4,
        badgeShape: .pill, badgeRadius: 7, badgeFontSize: 11, badgeMonospaced: false, badgeOffsetX: 14, badgeOffsetY: 22,
        rippleRadius: 26, rippleDuration: 0.4, rippleSquare: false, squish: 0.85, appearScale: 0.7,
        focusRadius: 6, focusWidth: 2, markCount: 3, markLife: 1.5)

    /// Blocky like Omarchy: square corners, a square badge, a monospace font, fades only.
    public static let omarchy = CursorTheme(
        name: "omarchy", glyph: .block, fill: .status, size: 24, ringWidth: 2, shadowRadius: 0, shadowOpacity: 0,
        badgeShape: .square, badgeRadius: 0, badgeFontSize: 11, badgeMonospaced: true, badgeOffsetX: 16, badgeOffsetY: 24,
        rippleRadius: 24, rippleDuration: 0.3, rippleSquare: true, squish: 1, appearScale: 1,
        focusRadius: 0, focusWidth: 2, markCount: 3, markLife: 1.2)

    public static let builtIn: [CursorTheme] = [standard, minimal, classic, omarchy]
    public static var names: [String] { builtIn.map(\.name) }

    /// A built-in theme by name, ignoring case; nil for an unknown name.
    public static func named(_ name: String) -> CursorTheme? {
        builtIn.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// The cursor's colors. Fixed, so nothing the person picks for the dock or the palette recolors an agent.
public enum CursorPalette {
    /// The Deck's status colors (working blue, asking yellow, failed red, finished orange).
    public static func status(_ s: DockAgent.State) -> RGB {
        switch s {
        case .working: return RGB(r: 0.20, g: 0.51, b: 0.97)
        case .asking: return RGB(r: 0.98, g: 0.80, b: 0.15)
        case .failed: return RGB(r: 0.93, g: 0.27, b: 0.27)
        case .done: return RGB(r: 0.96, g: 0.55, b: 0.18)
        }
    }

    /// Eight hues for telling two agents with the same status apart.
    public static let identity: [RGB] = [
        RGB(r: 1, g: 1, b: 1), RGB(r: 0.15, g: 0.15, b: 0.17), RGB(r: 0.64, g: 0.37, b: 0.87), RGB(r: 0.19, g: 0.69, b: 0.71),
        RGB(r: 0.94, g: 0.36, b: 0.62), RGB(r: 0.20, g: 0.74, b: 0.36), RGB(r: 0.55, g: 0.57, b: 0.60), RGB(r: 0.96, g: 0.78, b: 0.20),
    ]

    /// The same agent always gets the same hue (FNV-1a, not Swift's per-launch hash).
    public static func identityColor(for agent: String) -> RGB {
        var h: UInt64 = 0xcbf29ce484222325
        for b in agent.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return identity[Int(h % UInt64(identity.count))]
    }
}

/// Everything the renderer needs to draw one agent's cursor.
public struct CursorLook: Equatable, Sendable {
    public var name: String
    public var status: DockAgent.State
    public var identity: RGB
    public var theme: CursorTheme
    public init(name: String, status: DockAgent.State, identity: RGB, theme: CursorTheme) {
        self.name = name; self.status = status; self.identity = identity; self.theme = theme
    }
    public var statusColor: RGB { CursorPalette.status(status) }
}

/// The glyph outlines, tip at the origin, y pointing down (the renderer flips them for AppKit).
public enum CursorGlyphs {
    public static func path(_ glyph: CursorTheme.Glyph, size s: Double) -> CGPath {
        let p = CGMutablePath()
        func poly(_ pts: [(Double, Double)]) {
            p.move(to: CGPoint(x: pts[0].0 * s, y: pts[0].1 * s))
            for q in pts.dropFirst() { p.addLine(to: CGPoint(x: q.0 * s, y: q.1 * s)) }
            p.closeSubpath()
        }
        switch glyph {
        case .arrow: poly([(0, 0), (0, 0.92), (0.22, 0.72), (0.36, 1.0), (0.50, 0.93), (0.36, 0.66), (0.64, 0.66)])
        case .classic: poly([(0, 0), (0, 0.84), (0.19, 0.66), (0.31, 0.95), (0.43, 0.89), (0.31, 0.62), (0.56, 0.62)])
        case .block: poly([(0, 0), (0, 1.0), (0.30, 0.72), (0.52, 1.0), (0.66, 0.92), (0.44, 0.64), (0.74, 0.64)])
        case .dot: p.addEllipse(in: CGRect(x: -s / 2, y: -s / 2, width: s, height: s))
        }
        return p
    }
}
