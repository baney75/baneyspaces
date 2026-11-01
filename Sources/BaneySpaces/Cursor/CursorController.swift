import AppKit
import BaneySpacesCore
import BaneySpacesCursor

/// The agent cursor in the app: its settings (saved, with a `config.toml` over them), the overlay, and the director
/// that listens to the hands. Everything here runs on the main thread, and the overlay is drawn with Core Animation
/// layers only. `docs/agent-computer-use.md`, "The agent cursor".
final class CursorController: ObservableObject {
    static let shared = CursorController()

    /// What was chosen with `agent cursor`, Settings, or an older run.
    private var saved = CursorSettings.load()
    private var file = CursorConfigFile.read()
    private var fileStamp = CursorController.stamp()
    /// Saved choices with the config file's keys over them: what the cursor does.
    @Published private(set) var settings = CursorSettings()

    private var surface: OverlaySurface?
    private var director: CursorDirector?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var current: () -> Int = { 1 }
    private var agentWorkspace: () -> Int? = { nil }

    init() { settings = saved.applying(file) }

    /// Called once the app and the Deck are up. `agent` is the Deck's name and status for an agent session.
    func start(current: @escaping () -> Int, agentWorkspace: @escaping () -> Int?,
               agent: @escaping (String) -> (name: String, status: DockAgent.State), windowFrame: @escaping (UInt32) -> CGRect?) {
        guard director == nil else { return }
        self.current = current; self.agentWorkspace = agentWorkspace
        let surface = OverlaySurface(displays: CursorDisplaySpec.screens())
        var host = CursorDirector.Host()
        host.agent = agent
        host.windowFrame = windowFrame
        // The director's work is the main thread's: layers are touched there. The hands only queue to it.
        let director = CursorDirector(surface: surface, queue: .main, host: host)
        self.surface = surface; self.director = director
        HandsEvents.setListener(director)
        pushEnvironment()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let surface = self.surface else { return }
            surface.setDisplays(CursorDisplaySpec.screens())
            self.pushEnvironment(force: true)
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.pushEnvironment()
        })
        // A hand edit of config.toml is noticed within two seconds.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.reloadFileIfChanged() }
    }

    /// The workspace, a setting or a display changed: the director hides what must not be drawn any more.
    func environmentChanged() { pushEnvironment() }

    private func pushEnvironment(force: Bool = false) {
        guard let director, let surface else { return }
        var e = CursorEnvironment()
        e.settings = settings
        e.current = current()
        e.agentWorkspace = agentWorkspace()
        e.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        e.displays = surface.frames
        director.setEnvironment(e)
    }

    func mark(window: UInt32) -> CursorMark? { director?.lastMark(window: window) }

    // MARK: settings

    private static func stamp() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: CursorConfigFile.path()))?[.modificationDate] as? Date
    }

    private func reloadFileIfChanged() {
        let s = Self.stamp()
        guard s != fileStamp else { return }
        fileStamp = s
        file = CursorConfigFile.read()
        settings = saved.applying(file)
        pushEnvironment()
    }

    /// Settings' switch and picker, and `baneyspaces agent cursor`.
    func set(enabled: Bool? = nil, theme: String? = nil) {
        if let enabled { saved.enabled = enabled }
        if let theme { saved.theme = theme }
        saved.save()
        settings = saved.applying(file)
        pushEnvironment()
    }

    var themeNames: [String] { CursorTheme.names }

    /// `baneyspaces agent cursor on|off|theme <name>|status`.
    func command(_ args: [String]) -> Wire.Reply {
        func status(_ extra: [String: String] = [:]) -> Wire.Reply {
            var info = ["enabled": settings.enabled ? "on" : "off", "theme": settings.theme,
                        "themes": CursorTheme.names.joined(separator: ", "),
                        "glide": "response \(settings.spring.response) damping \(settings.spring.damping)" + (settings.spring.isInstant ? " (instant)" : "")]
            var held: [String] = []
            if file.enabled != nil { held.append("behavior.cursor.enabled") }
            if file.theme != nil { held.append("behavior.cursor.theme") }
            if !held.isEmpty { info["config_wins"] = held.joined(separator: ", ") + " in " + CursorConfigFile.path() }
            return Wire.Reply(ok: true, info: info.merging(extra) { $1 })
        }
        switch args.first ?? "status" {
        case "status": return status()
        case "on": set(enabled: true); return status()
        case "off": set(enabled: false); return status()
        case "theme":
            guard let name = args.dropFirst().first else { return status() }
            guard let theme = CursorTheme.named(name) else {
                return Wire.Reply(ok: false, error: "no cursor theme called \(name); themes: " + CursorTheme.names.joined(separator: ", "))
            }
            set(theme: theme.name)
            return status()
        default:
            return Wire.Reply(ok: false, error: "usage: baneyspaces agent cursor on|off|theme <name>|status")
        }
    }
}

/// A window's frame from the window server, in the hands' coordinates (global, y down).
enum WindowFrames {
    static func frame(of id: UInt32) -> CGRect? {
        guard let list = CGWindowListCreateDescriptionFromArray([NSNumber(value: id)] as CFArray) as? [[String: Any]],
              let b = list.first?[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: b as CFDictionary) else { return nil }
        return rect
    }
}
