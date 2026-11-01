import Foundation

// What each surface draws, resolved from a theme (spec/themes.md, "Every surface uses the theme").
// The views read these and nothing else for radius, border, fill, shadow, type, spacing and
// motion; `ThemeConformanceTests` renders every surface in all three themes and compares what they
// use with themes.json, and scans the view files for a literal that bypasses them.

/// Which of the theme's four radii a surface takes.
public enum RadiusKind: Sendable { case bar, tile, row, list }

/// Every surface that draws a corner, a border or text from the theme.
public enum Surface: String, CaseIterable, Sendable {
    // The Workspace Dock and its "+N" list and window strip.
    case dockBar, dockList, dockTile, dockButton, dockChip, dockRow
    // The ⌘Tab window bar.
    case switcherPanel, switcherTile, switcherWindow
    // The launcher.
    case launcherPanel, launcherMini, launcherRow, launcherThumb, launcherImage, launcherKey
    // The overview (the Mission Control replacement) and the workspace HUD.
    case overviewTile, overviewChip, hudPanel, hudCell
    // Settings.
    case settingsTile, settingsCallout, settingsCell

    public var kind: RadiusKind {
        switch self {
        case .dockBar, .switcherPanel, .launcherPanel, .launcherMini, .hudPanel: .bar
        case .dockList: .list
        case .dockTile, .dockButton, .switcherTile, .switcherWindow, .overviewTile, .settingsTile, .settingsCallout: .tile
        case .dockChip, .dockRow, .launcherRow, .launcherThumb, .launcherImage, .launcherKey, .overviewChip, .hudCell, .settingsCell: .row
        }
    }

    /// The corner radius this surface has always had, in the BaneySpaces theme. Other themes scale
    /// their own radius by the same proportion (so Omarchy's 0 stays square everywhere).
    public var shippedRadius: Double {
        switch self {
        case .dockBar: 24
        case .dockList: 14
        case .dockTile: 16
        case .dockButton: 10
        case .dockChip: 6
        case .dockRow: 7
        case .switcherPanel: 26
        case .switcherTile: 16
        case .switcherWindow: 14
        case .launcherPanel: 22
        case .launcherMini: 16
        case .launcherRow: 11
        case .launcherThumb: 8
        case .launcherImage: 7
        case .launcherKey: 4
        case .overviewTile: 16
        case .overviewChip: 9
        case .hudPanel: 22
        case .hudCell: 7
        case .settingsTile: 11
        case .settingsCallout: 10
        case .settingsCell: 8
        }
    }

    /// The border widths this surface has always had in the BaneySpaces theme: resting, and focused
    /// (the current workspace, the selected row, the hovered tile).
    public var shippedBorder: (rest: Double, focused: Double) {
        switch self {
        case .switcherTile, .switcherWindow, .settingsTile: (1, 2)
        case .overviewTile: (1, 3)
        case .hudCell: (1, 1)
        default: (1, 1.5)
        }
    }
}

public extension ThemeSpec.Radius {
    func value(_ k: RadiusKind) -> Double {
        switch k {
        case .bar: bar
        case .tile: tile
        case .row: row
        case .list: list
        }
    }
}

/// How a motion's length is named in the theme.
public enum MotionKind: Sendable { case panelIn, panelOut, listIn, listOut, row }

public extension ThemeSpec.Motion {
    func milliseconds(_ k: MotionKind) -> Double {
        switch k {
        case .panelIn: inMs
        case .panelOut: outMs
        case .listIn: listInMs
        case .listOut: listOutMs
        case .row: rowMs
        }
    }

    /// A duration this surface has always had (in seconds), in this theme: the BaneySpaces theme's
    /// own length gives it back unchanged, and another theme's is the same proportion of it.
    func seconds(_ shipped: Double, _ k: MotionKind) -> Double {
        let base = ThemeCatalog.shared.spec(.baneyspaces).motion.milliseconds(k)
        return shipped * (milliseconds(k) / base)
    }

    /// Whether the dock moves as it comes and goes (it only fades when nothing scales).
    var slides: Bool { scaleFrom < 1 }
}

/// A weight, as the views ask for it.
public enum TextWeight: Int, Sendable { case regular, medium, semibold, bold, heavy }

public extension ThemeSpec.Font {
    /// Sizes are written for the 12 pt base; a theme with another size scales them all.
    func size(_ shipped: Double) -> Double { shipped * (size / 12) }

    /// A theme whose weight is `regular` draws medium and semibold text regular; bold stays bold.
    func weight(_ requested: TextWeight) -> TextWeight {
        weight == "regular" && (requested == .medium || requested == .semibold) ? .regular : requested
    }
}

/// One surface in one theme: every value its view uses.
public struct SurfaceStyle: Equatable, Sendable {
    public let surface: Surface
    public let theme: ThemeID
    public let radius: Double
    public let borderWidth: Double
    public let focusedBorderWidth: Double
    public let borderRole: String
    public let focusedBorderRole: String
    public let borderOpacity: Double?
    public let borderGradient: [Double]?
    public let fill: ThemeSpec.Fill
    public let shadow: ThemeSpec.Shadow?
    public let font: ThemeSpec.Font
    public let gap: Double
    public let padding: Double
    public let tile: Double
    public let indicator: ThemeIndicator
    public let motion: ThemeSpec.Motion

    public static func make(_ s: Surface, theme: ThemeID, spec: ThemeSpec) -> SurfaceStyle {
        let base = ThemeCatalog.shared.spec(.baneyspaces).radius.value(s.kind)
        // Proportional, so 0 stays 0 and the BaneySpaces theme gives back exactly what it drew.
        let radius = s.shippedRadius * (spec.radius.value(s.kind) / base)
        // The BaneySpaces theme keeps the widths each surface has always had; the others draw
        // their one width (2 px solid for Omarchy) on every surface.
        let widths: (rest: Double, focused: Double) = theme == .baneyspaces
            ? s.shippedBorder : (rest: spec.border.width, focused: spec.border.focusedWidth)
        return SurfaceStyle(
            surface: s, theme: theme, radius: radius,
            borderWidth: widths.rest, focusedBorderWidth: widths.focused,
            borderRole: spec.border.role, focusedBorderRole: spec.border.focusedRole,
            borderOpacity: spec.border.opacity, borderGradient: spec.border.gradient,
            fill: spec.fill, shadow: spec.shadow, font: spec.font,
            gap: spec.space.gap, padding: spec.space.padding, tile: spec.space.tile,
            indicator: spec.indicator, motion: spec.motion)
    }
}

/// The panel behind the dock, ⌘Tab, the launcher and the HUD, resolved for a look and the person's
/// panel settings (Settings › Appearance).
public struct PanelLook: Equatable, Sendable {
    public struct Border: Equatable, Sendable {
        public var width: Double
        public var color: RGB
        /// Opacity at the top and at the bottom (equal for a flat border).
        public var top: Double
        public var bottom: Double
    }
    /// Blur behind the panel (`.ultraThinMaterial`); off means the fill is opaque.
    public var blur: Bool
    public var fill: RGB
    public var fillOpacity: Double
    /// The accent washed over the glass: the Tinted panel style.
    public var wash: RGB?
    public var washOpacity: Double
    public var border: Border
    public var shadow: ThemeSpec.Shadow?
    public var radius: Double

    public static func make(_ s: Surface, look: Look, settings: AppearanceSettings, accent: RGB) -> PanelLook {
        let style = SurfaceStyle.make(s, theme: look.theme, spec: look.spec)
        let f = style.fill
        let opacity = f.adjustable ? settings.effectivePanelOpacity : f.tintOpacity * f.opacity
        let borderColor = look.color(style.borderRole)
        let gradient = style.borderGradient
        return PanelLook(
            blur: f.blur, fill: look.color(f.tintRole), fillOpacity: opacity,
            wash: f.adjustable && settings.panelStyle == .tinted ? accent : nil,
            washOpacity: AppearanceSettings.tintWash,
            border: Border(width: style.borderWidth, color: borderColor,
                           top: gradient?.first ?? style.borderOpacity ?? 1,
                           bottom: gradient?.last ?? style.borderOpacity ?? 1),
            shadow: style.shadow, radius: style.radius)
    }
}
