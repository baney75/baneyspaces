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
    private var shownWorkspaces: () -> Set<Int> = { [1] }
    private var agentWorkspace: () -> Int? = { nil }

    init() { settings = saved.applying(file) }

    /// Called once the app and the Deck are up. `agent` is the Deck's name and status for an agent session.
    func start(shown: @escaping () -> Set<Int>, agentWorkspace: @escaping () -> Int?,
               agent: @escaping (String) -> (name: String, status: DockAgent.State), windowFrame: @escaping (UInt32) -> CGRect?) {
        guard director == nil else { return }
        self.shownWorkspaces = shown; self.agentWorkspace = agentWorkspace
        let surface = OverlaySurface(displays: CursorDisplaySpec.screens())
        var host = CursorDirector.Host()
        host.agent = agent
        host.windowFrame = windowFrame
        // The director's work is the main thread's: layers are touched there. The hands only queue to it.
        let director = CursorDirector(surface: surface, queue: .main, host: host)
        self.surface = surface; self.director = director
        HandsEvents.setListener(director)
        // An off state in the saved settings is visible in the log: Settings is the only thing here that writes it, but
        // the defaults file is the user's and any process of the user can edit it.
        if !saved.enabled { Trace.log("agent cursor is off in the saved settings (turned off in Settings, or the defaults were edited)") }
        pushEnvironment()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let surface = self.surface else { return }
            surface.setDisplays(CursorDisplaySpec.screens())
            self.pushEnvironment()
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.pushEnvironment()
        })
        // A hand edit of config.toml is noticed within two seconds.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.reloadFileIfChanged() }
    }

    /// The workspace, a setting or a display changed: the director hides what must not be drawn any more.
    func environmentChanged() { pushEnvironment() }

    private func pushEnvironment() {
        guard let director, let surface else { return }
        var e = CursorEnvironment()
        e.settings = settings
        e.shownWorkspaces = shownWorkspaces()
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

    /// The switch is Donovan's: this is called by Settings only (the socket refuses `agent cursor off`, see
    /// `SocketPolicy`, and `command` below refuses it again).
    func setEnabled(_ on: Bool) {
        saved.enabled = on
        saved.save()
        settings = saved.applying(file)
        pushEnvironment()
    }

    /// Settings' picker and `agent cursor theme`. False when `config.toml` holds the theme: it wins, so a change here
    /// would snap back.
    @discardableResult
    func setTheme(_ theme: String) -> Bool {
        guard file.theme == nil else { return false }
        saved.theme = theme
        saved.save()
        settings = saved.applying(file)
        pushEnvironment()
        return true
    }

    /// Whether `config.toml` sets the theme (Settings shows the picker as set there).
    var themeSetInFile: Bool { file.theme != nil }

    var themeNames: [String] { CursorTheme.names }

    /// `baneyspaces agent cursor on|theme <name>|status`. `off` is refused, whoever sends it: the socket cannot tell
    /// Donovan from an agent, and the cursor is how he sees agents work. Settings turns it off.
    func command(_ args: [String]) -> Wire.Reply {
        func status() -> Wire.Reply {
            var info = ["enabled": settings.enabled ? "on" : "off", "theme": settings.theme,
                        "themes": CursorTheme.names.joined(separator: ", "),
                        "glide": "response \(settings.spring.response) damping \(settings.spring.damping)" + (settings.spring.isInstant ? " (instant)" : "")]
            if file.theme != nil { info["config_wins"] = "behavior.cursor.theme in " + CursorConfigFile.path() }
            if !file.ignored.isEmpty { info["config_ignored"] = file.ignored.joined(separator: ", ") + " (only Settings turns the cursor off)" }
            return Wire.Reply(ok: true, info: info)
        }
        switch args.first ?? "status" {
        case "status": return status()
        case "on":
            setEnabled(true)
            return status()
        case "off":
            Trace.log("cursor off refused: asked on the command line")
            return Wire.Reply(ok: false, error: "turning the agent cursor off is Donovan's to do, in BaneySpaces Settings")
        case "theme":
            guard let name = args.dropFirst().first else { return status() }
            guard let theme = CursorTheme.named(name) else {
                return Wire.Reply(ok: false, error: "no cursor theme called \(name); themes: " + CursorTheme.names.joined(separator: ", "))
            }
            guard setTheme(theme.name) else {
                return Wire.Reply(ok: false, error: "config.toml sets behavior.cursor.theme, which wins; change it there")
            }
            return status()
        default:
            return Wire.Reply(ok: false, error: "usage: baneyspaces agent cursor on|theme <name>|status")
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
