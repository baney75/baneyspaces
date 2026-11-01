import AppKit
import BaneySpacesCore
import SwiftUI

extension TextWeight {
    var swiftUI: Font.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        }
    }
}

/// The look shared by the dock, the switcher, the launcher, the overview, the HUD and Settings.
/// All of it comes from `Appearance` (Settings › Appearance: the theme, the palette and the
/// accent), through the theme's tokens in `themes.json`. A surface asks `Chrome` for its radius,
/// border, fill, type and motion and draws no literal of its own; `ThemeConformanceTests` scans
/// the view files for one. The BaneySpaces theme's values are the ones that shipped, so that theme
/// draws what the app always drew.
enum Chrome {
    static var accent: Color { Appearance.shared.accent }

    /// One color per workspace; by default around the color wheel so neighbors never look
    /// alike. White text reads on all of them.
    static func workspace(_ n: Int) -> Color { Appearance.shared.workspace(n) }

    static func panelBackground(_ surface: Surface) -> PanelBackground { PanelBackground(surface: surface) }

    // MARK: The theme in use

    static var look: Look { Appearance.shared.look }
    static var theme: ThemeID { look.theme }
    static var spec: ThemeSpec { look.spec }
    static func style(_ s: Surface) -> SurfaceStyle { SurfaceStyle.make(s, theme: look.theme, spec: look.spec) }

    // MARK: Shape

    static func radius(_ s: Surface) -> CGFloat { CGFloat(style(s).radius) }

    /// The surface's corners. `continuous` is the superellipse macOS draws; a few shapes always used the plain arc.
    static func shape(_ s: Surface, continuous: Bool = true) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius(s), style: continuous ? .continuous : .circular)
    }

    /// A pill in the BaneySpaces and Minimal themes; square wherever the theme's corners are.
    static func pill() -> ThemedPill { ThemedPill() }

    /// A round mark (a workspace dot); a square block where the theme's corners are square.
    static func mark() -> ThemedMark { ThemedMark() }

    /// A hover or drag growth of `shipped` times the size: none where the theme only fades.
    static func grow(_ shipped: CGFloat) -> CGFloat { spec.motion.lift == 1 ? 1 : shipped }

    /// The tile size the dock's own measurements were written for; the theme's tile is scaled against it.
    static var tileBase: CGFloat { CGFloat(ThemeCatalog.shared.spec(.baneyspaces).space.tile) }
    static var tileScale: CGFloat { CGFloat(style(.dockTile).tile) / tileBase }

    // MARK: Color

    /// The palette's text color at `opacity`: white, in the default palette.
    static func wash(_ opacity: Double = 1) -> Color { Appearance.color(look.color("foreground")).opacity(opacity) }

    /// Plain white at `opacity`: text on a workspace's own tint, which is dark enough for it in every palette.
    static func light(_ opacity: Double = 1) -> Color { Appearance.color(look.color("light")).opacity(opacity) }

    /// The palette's darkest color at `opacity`: shadows and the tooltip's backing. Black, in the default palette.
    static func shade(_ opacity: Double) -> Color { Appearance.color(look.color("sunken")).opacity(opacity) }

    /// The panel's own color, for text drawn on the accent or a workspace tint.
    static func panel(_ opacity: Double = 1) -> Color { Appearance.color(look.color("background")).opacity(opacity) }

    /// A resting border. BaneySpaces: white at the opacity this surface has always used; the other
    /// themes: the palette's `border` role at the theme's one opacity.
    static func edge(_ shipped: Double) -> Color {
        let b = spec.border
        if look.theme == .baneyspaces { return Appearance.color(look.color(b.role)).opacity(shipped) }
        return Appearance.color(look.color(b.role)).opacity(b.opacity ?? 1)
    }

    /// The border of what is current, selected or hovered. BaneySpaces: the workspace's tint; the
    /// others: the palette's accent (Omarchy's active-window border).
    static func focusEdge(_ tint: Color) -> Color {
        look.spec.border.focusedRole == "workspace" ? tint : Appearance.color(look.color(look.spec.border.focusedRole))
    }

    /// A resting tile or row fill. BaneySpaces: white at the opacity it has always used; the other
    /// themes: the palette's `surface` (and `selection` for a lit one), opaque.
    static func cell(_ shipped: Double) -> Color {
        if look.theme == .baneyspaces { return wash(shipped) }
        return Appearance.color(look.color(shipped >= 0.1 ? "selection" : "surface"))
    }

    /// The fill of the current workspace's tile or the selected row. BaneySpaces: its tint at
    /// the opacity it has always used; the others: the palette's `selection`.
    static func lit(_ tint: Color, _ shipped: Double) -> Color {
        look.theme == .baneyspaces ? tint.opacity(shipped) : Appearance.color(look.color("selection"))
    }

    /// The overview's tile fill: the BaneySpaces theme's two grays, the palette's `surface` and `selection` elsewhere.
    static func tileFill(target: Bool) -> Color {
        look.theme == .baneyspaces ? Color(white: target ? 0.19 : 0.13) : Appearance.color(look.color(target ? "selection" : "surface"))
    }

    /// The overview's card while it is carried.
    static var liftedFill: Color {
        look.theme == .baneyspaces ? Color(white: 0.26) : Appearance.color(look.color("selection"))
    }

    /// The overview's backdrop when it can't blur the screen (a rendered still, or a theme with no blur).
    static var stillBackdrop: LinearGradient {
        if look.theme == .baneyspaces && look.isAuto {
            return LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.11), Color(red: 0.11, green: 0.07, blue: 0.13)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        return LinearGradient(colors: [panel(), Appearance.color(look.color("sunken"))], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: AppKit
    //
    // The same tokens for the few places AppKit draws text itself.

    static func nsFont(_ size: Double, _ weight: TextWeight = .regular) -> NSFont {
        let f = look.spec.font
        let pt = CGFloat(f.size(size))
        let w: NSFont.Weight = switch f.weight(weight) {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        }
        if let name = family, let base = NSFont(name: name, size: pt) {
            return NSFontManager.shared.convertWeight(w.rawValue >= NSFont.Weight.semibold.rawValue, of: base)
        }
        return f.family == "system-sans" ? .systemFont(ofSize: pt, weight: w) : .monospacedSystemFont(ofSize: pt, weight: w)
    }

    static func nsWash(_ opacity: Double = 1) -> NSColor {
        look.color("foreground").nsColor.withAlphaComponent(opacity)
    }

    // MARK: Border width

    static func width(_ s: Surface, focused: Bool = false) -> CGFloat {
        let st = style(s)
        return CGFloat(focused ? st.focusedBorderWidth : st.borderWidth)
    }

    // MARK: Type

    private static let installed: Set<String> = Set(NSFontManager.shared.availableFontFamilies)

    /// The first family of the theme's font that is installed; nil for the system font.
    static var family: String? {
        guard look.spec.font.family != "system-sans" else { return nil }
        return ThemeCatalog.shared.fontFamilies(look.spec.font.family).first { installed.contains($0) }
    }

    /// Text at a size written for the 12 pt base, in the theme's family and weight.
    static func font(_ size: Double, _ weight: TextWeight = .regular, rounded: Bool = false) -> Font {
        let f = look.spec.font
        let pt = CGFloat(f.size(size)), w = f.weight(weight).swiftUI
        if f.family == "system-sans" { return .system(size: pt, weight: w, design: rounded ? .rounded : .default) }
        if let name = family { return .custom(name, size: pt).weight(w) }
        return .system(size: pt, weight: w, design: .monospaced)
    }

    // MARK: Motion

    /// A length this surface has always animated for, in the theme. Reduce Motion is the caller's.
    static func seconds(_ shipped: Double, _ k: MotionKind) -> Double { spec.motion.seconds(shipped, k) }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// A fade or slide of `shipped` seconds as the theme times it: zero under Reduce Motion.
    static func duration(_ shipped: Double, _ k: MotionKind) -> Double {
        DockMotion.duration(seconds(shipped, k), reduceMotion: reduceMotion)
    }

    /// An ease-out animation of that length, or none under Reduce Motion.
    static func ease(_ shipped: Double, _ k: MotionKind = .panelIn) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: seconds(shipped, k))
    }

    /// The scale a picked-up tile grows to (1 where the theme only fades).
    static var lift: CGFloat { DockMotion.lift }
}

extension Appearance {
    /// The color `Chrome.wash` would draw for a role, for a swatch.
    static func swatch(_ c: RGB) -> Color { color(c) }
}

/// A workspace's number in the theme's indicator: a dot with its number, a number in a square
/// block, or the number over a bar in the workspace's color.
struct WorkspaceMark: View {
    let n: Int
    let tint: Color
    /// Lit: the workspace you're on.
    var current = false
    var size: CGFloat = 20

    var body: some View {
        let theme = Chrome.spec
        switch theme.indicator {
        case .dot:
            Text("\(n)").font(Chrome.font(size * 0.55, .bold, rounded: true)).foregroundStyle(Chrome.light())
                .frame(minWidth: size, minHeight: size)
                .background(Circle().fill(tint))
                .overlay(Circle().strokeBorder(Chrome.shade(0.25), lineWidth: Chrome.width(.dockTile)))
        case .numberBlock:
            Text("\(n)").font(Chrome.font(size * 0.55, .bold))
                .foregroundStyle(current ? Chrome.panel() : tint)
                .frame(minWidth: size, minHeight: size)
                .background(Rectangle().fill(current ? tint : Color.clear))
                .overlay(Rectangle().strokeBorder(tint, lineWidth: Chrome.width(.dockTile, focused: current)))
        case .bar:
            VStack(spacing: 2) {
                Text("\(n)").font(Chrome.font(size * 0.55, .bold)).foregroundStyle(current ? Chrome.wash() : tint)
                Rectangle().fill(tint.opacity(current ? 1 : 0.5)).frame(width: size * 0.8, height: 2)
            }
            .frame(minWidth: size, minHeight: size)
        }
    }
}

/// A capsule, or a rectangle where the theme's corners are square.
struct ThemedPill: InsettableShape {
    var inset: CGFloat = 0
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        return Chrome.spec.radius.row == 0 ? Rectangle().path(in: r) : Capsule().path(in: r)
    }
    func inset(by amount: CGFloat) -> ThemedPill { ThemedPill(inset: inset + amount) }
}

/// A circle, or a square where the theme's corners are square.
struct ThemedMark: InsettableShape {
    var inset: CGFloat = 0
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        return Chrome.spec.radius.row == 0 ? Rectangle().path(in: r) : Circle().path(in: r)
    }
    func inset(by amount: CGFloat) -> ThemedMark { ThemedMark(inset: inset + amount) }
}

/// The number under a dock tile, lit for the workspace you're on, like the key that gets there:
/// a number on a pill (BaneySpaces), in a bordered block (Omarchy) or over a bar (Minimal).
struct TileNumber: View {
    let n: Int
    let tint: Color
    let current: Bool
    let hovered: Bool

    var body: some View {
        switch Chrome.spec.indicator {
        case .dot:
            Text("\(n)")
                .font(Chrome.font(10.5, .bold, rounded: true))
                .foregroundStyle(current ? Chrome.light() : tint.opacity(hovered ? 1 : 0.85))
                .frame(minWidth: 18, minHeight: 15)
                .background(Chrome.pill().fill(current ? tint : Color.clear))
        case .numberBlock:
            Text("\(n)")
                .font(Chrome.font(10.5, .bold))
                .foregroundStyle(current ? Chrome.panel() : tint)
                .frame(minWidth: 18, minHeight: 15)
                .background(Rectangle().fill(current ? tint : Color.clear))
                .overlay(Rectangle().strokeBorder(hovered || current ? Chrome.focusEdge(tint) : Chrome.edge(1),
                                                  lineWidth: Chrome.width(.dockTile, focused: current)))
        case .bar:
            VStack(spacing: 1) {
                Text("\(n)").font(Chrome.font(10.5, .bold)).foregroundStyle(current ? Chrome.wash() : tint.opacity(hovered ? 1 : 0.85))
                Rectangle().fill(current ? tint : Color.clear).frame(width: 14, height: Chrome.width(.dockTile, focused: true))
            }
            .frame(minWidth: 18, minHeight: 15)
        }
    }
}

extension RGB {
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}

/// The menu bar's workspace indicator in the theme's own form. The BaneySpaces theme keeps the numbered
/// square symbol the menu bar has always shown (nil here); Omarchy draws a numbered block, Minimal a number over a bar.
enum MenuBarMark {
    static func image(workspace n: Int, description: String) -> NSImage? {
        let spec = Chrome.spec
        guard Chrome.theme != .baneyspaces else { return nil }
        let size = NSSize(width: 18, height: 18)
        let line = CGFloat(spec.border.width) * 0.75
        let image = NSImage(size: size, flipped: false) { rect in
            let text = NSAttributedString(string: "\(n)", attributes: [.font: Chrome.nsFont(11, .bold), .foregroundColor: NSColor.black])
            let t = text.size()
            switch spec.indicator {
            case .bar:
                text.draw(at: NSPoint(x: rect.midX - t.width / 2, y: rect.midY - t.height / 2 + 2))
                NSColor.black.setFill()
                NSRect(x: rect.minX + 3, y: rect.minY + 2, width: rect.width - 6, height: line).fill()
            default:
                NSColor.black.setStroke()
                let box = NSBezierPath(rect: rect.insetBy(dx: 1 + line / 2, dy: 1 + line / 2))
                box.lineWidth = line
                box.stroke()
                text.draw(at: NSPoint(x: rect.midX - t.width / 2, y: rect.midY - t.height / 2))
            }
            return true
        }
        image.accessibilityDescription = description
        return image
    }
}

/// A palette as a strip of its colors: background, surface, accent and text.
enum PaletteSwatch {
    static func image(_ p: Palette) -> NSImage {
        let roles = ["background", "surface", "accent", "foreground"]
        let img = NSImage(size: NSSize(width: 44, height: 14), flipped: false) { rect in
            let w = rect.width / CGFloat(roles.count)
            for (i, role) in roles.enumerated() {
                (p.color(role) ?? RGB(r: 0.5, g: 0.5, b: 0.5)).nsColor.setFill()
                NSRect(x: CGFloat(i) * w, y: 0, width: w, height: rect.height).fill()
            }
            NSColor.separatorColor.setStroke()
            NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            return true
        }
        return img
    }
}

/// One theme, drawn small in its own shape and type, in the palette now chosen. Click to use it.
struct ThemeCard: View {
    let theme: ThemeID
    let selected: Bool
    let action: () -> Void
    @ObservedObject private var appearance = Appearance.shared

    var body: some View {
        let look = Look(theme: theme, palette: appearance.settings.colorPalette, accent: appearance.accentRGB)
        let bar = SurfaceStyle.make(.dockBar, theme: theme, spec: look.spec)
        let tile = SurfaceStyle.make(.dockTile, theme: theme, spec: look.spec)
        // A fifth of the real dock, which is 64 pt tiles in the BaneySpaces theme.
        let s: CGFloat = 0.42
        Button(action: action) {
            VStack(spacing: 6) {
                HStack(spacing: CGFloat(bar.gap) * s) {
                    ForEach(1...3, id: \.self) { n in
                        let current = n == 2
                        let tint = Appearance.color(look.color("workspace", workspace: Appearance.shared.settings.workspaceColor(n, accent: appearance.accentRGB).rgb))
                        let edge = Appearance.color(look.color(current ? tile.focusedBorderRole : tile.borderRole, workspace: Appearance.shared.settings.workspaceColor(n, accent: appearance.accentRGB).rgb))
                        let shape = RoundedRectangle(cornerRadius: CGFloat(tile.radius) * s, style: .continuous)
                        shape.fill(current ? tint.opacity(0.35) : Appearance.color(look.color("foreground")).opacity(0.08))
                            .overlay(shape.strokeBorder(edge.opacity(current ? 1 : (tile.borderOpacity ?? 0.2)),
                                                        lineWidth: CGFloat(current ? tile.focusedBorderWidth : tile.borderWidth) * s * 1.6))
                            .overlay(mark(n, look: look, tint: tint, current: current))
                            .frame(width: CGFloat(tile.tile) * s, height: CGFloat(tile.tile) * s)
                    }
                }
                .padding(CGFloat(bar.padding) * s)
                .background(PanelBackground(surface: .dockBar, look: look, scale: s))
                Text(look.spec.label).font(Chrome.font(11, selected ? .semibold : .regular))
            }
            .padding(6)
            .frame(maxWidth: .infinity)
            .overlay(Chrome.shape(.settingsCallout).strokeBorder(selected ? Chrome.accent : Chrome.edge(0.1), lineWidth: Chrome.width(.settingsTile, focused: selected)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(look.spec.label) theme\(selected ? ", selected" : "")")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private func mark(_ n: Int, look: Look, tint: Color, current: Bool) -> some View {
        let fg = Appearance.color(look.color("foreground"))
        switch look.spec.indicator {
        case .dot:
            Text("\(n)").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(fg)
        case .numberBlock:
            Text("\(n)").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(current ? tint : fg)
        case .bar:
            VStack(spacing: 1) {
                Text("\(n)").font(.system(size: 9, weight: .regular)).foregroundStyle(fg)
                Rectangle().fill(tint).frame(width: 10, height: 1.5)
            }
        }
    }
}
