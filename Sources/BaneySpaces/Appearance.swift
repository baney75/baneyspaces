import AppKit
import BaneySpacesCore
import SwiftUI

/// The look the person picked in Settings › Appearance. Every panel reads its colors from here
/// (through `Chrome`) and observes it, so a change redraws the open panels at once. The model is
/// pure and tested in BaneySpacesCore; this holds it, saves it and tells the panels.
final class Appearance: ObservableObject {
    static let shared = Appearance()
    /// Posted after every change, for AppKit code that can't observe a SwiftUI object (the dock's
    /// panel re-frames itself on it).
    static let didChange = Notification.Name("BaneySpacesAppearanceDidChange")

    @Published var settings: AppearanceSettings {
        didSet {
            guard settings != oldValue else { return }
            cachedLook = nil
            if settings.theme != oldValue.theme { ThemeCenter.use(settings.theme) }
            if persists { scheduleSave() }
            // A theme sets the tile size, gap and padding as well as the dock's size, so it re-frames the dock too.
            NotificationCenter.default.post(name: Appearance.didChange, object: nil,
                                            userInfo: [Appearance.dockSizeChangedKey: settings.dockSize != oldValue.dockSize || settings.theme != oldValue.theme])
        }
    }

    /// The theme and palette every surface draws from, kept until the settings or the system accent change.
    private var cachedLook: Look?
    var look: Look {
        if let cachedLook { return cachedLook }
        let l = settings.look(systemAccent: Appearance.systemAccent)
        cachedLook = l
        return l
    }

    /// A slider drag changes the settings many times a second; they're written once it settles.
    private var saveWork: DispatchWorkItem?
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.persists else { return }
            self.saveWork = nil
            self.settings.save()
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Off for `--render`, whose shots must show the default look and never touch saved settings.
    private var persists = true
    private var systemObserver: NSObjectProtocol?

    /// A change still waiting to be saved is written as BaneySpaces quits.
    private var quitObserver: NSObjectProtocol?

    /// `didChange`'s userInfo key: true when the dock size changed, so the dock re-frames.
    static let dockSizeChangedKey = "dockSizeChanged"

    private init() {
        settings = AppearanceSettings.load()
        ThemeCenter.use(settings.theme)
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
            guard let self, let work = self.saveWork else { return }
            work.cancel()
            self.saveWork = nil
            if self.persists { self.settings.save() }
        }
        // "System" follows the accent color chosen in System Settings.
        systemObserver = NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            // The Settings tab draws its System swatch from the live color, whatever is chosen.
            self.cachedLook = nil
            self.objectWillChange.send()
            if case .system = self.settings.accent { NotificationCenter.default.post(name: Appearance.didChange, object: nil) }
        }
    }

    /// The default look for this run only, saved nowhere.
    func useDefaultLookWithoutSaving() {
        saveWork?.cancel()
        saveWork = nil
        persists = false
        settings = AppearanceSettings()
        ThemeCenter.use(settings.theme)
    }

    /// macOS's accent color as RGB.
    static var systemAccent: RGB {
        let c = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? NSColor.systemBlue.usingColorSpace(.sRGB) ?? .blue
        return RGB(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent))
    }

    var accentRGB: RGB { settings.accentRGB(system: Appearance.systemAccent) }
    var accent: Color { Appearance.color(accentRGB) }

    func workspace(_ n: Int) -> Color {
        let c = settings.workspaceColor(n, accent: accentRGB)
        return Color(hue: c.h, saturation: c.s, brightness: c.b)
    }

    static func color(_ c: RGB) -> Color { Color(red: c.r, green: c.g, blue: c.b) }

    /// Nil for a color with no sRGB form (a pattern): nothing is saved for it. Reading the
    /// components of a color that isn't RGB raises.
    static func rgb(_ color: Color) -> RGB? {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return RGB(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent))
    }
}

/// The panel behind the dock, ⌘Tab, the launcher and the HUD, in the theme and palette Settings
/// picked (and, in the BaneySpaces theme, its panel style). It watches `Appearance` itself, so it
/// redraws even when its parent doesn't.
struct PanelBackground: View {
    let surface: Surface
    @ObservedObject private var appearance = Appearance.shared

    var body: some View {
        let look = appearance.look
        let p = PanelLook.make(surface, look: look, settings: appearance.settings, accent: appearance.accentRGB)
        let shape = RoundedRectangle(cornerRadius: CGFloat(p.radius), style: .continuous)
        let border = Appearance.color(p.border.color)
        shape.fill(p.blur ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.clear))
            // Dark enough that text in the windows behind never reads through (Omarchy: fully opaque).
            .overlay(shape.fill(Appearance.color(p.fill).opacity(p.fillOpacity)))
            .overlay {
                if let wash = p.wash { shape.fill(Appearance.color(wash).opacity(p.washOpacity)) }
            }
            // BaneySpaces: a light top edge and a faint outline, like glass catching light. Others: one solid line.
            .overlay(shape.strokeBorder(LinearGradient(colors: [border.opacity(p.border.top), border.opacity(p.border.bottom)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: CGFloat(p.border.width)))
            .shadow(color: Chrome.shade(p.shadow?.opacity ?? 0), radius: CGFloat(p.shadow?.radius ?? 0), y: CGFloat(p.shadow?.y ?? 0))
    }
}
