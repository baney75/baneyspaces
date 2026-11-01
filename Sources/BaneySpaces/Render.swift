import AppKit
import BaneySpacesCore
import SwiftUI

/// `BaneySpaces --render <folder>` draws the overview, still and mid-drag, with sample windows
/// into PNGs, for the README and the website. It never touches real windows.
@MainActor
enum Render {
    static func run(into folder: URL) -> Int32 {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Run from `swift build` rather than the app bundle, macOS hands out a generic folder for
        // the app icon; settings would show that. Use the repo's icon when it's there.
        if Bundle.main.bundleURL.pathExtension != "app", let icon = NSImage(contentsOfFile: "docs/icon.png") {
            NSApp.applicationIconImage = icon
        }
        var sample: [Int: [(String, String, String)]] = [
            1: [("Safari", "/Applications/Safari.app", "Swift documentation"),
                ("Notes", "/System/Applications/Notes.app", "Launch checklist"),
                ("Terminal", "/System/Applications/Utilities/Terminal.app", "~/Projects/baneyspaces")],
            2: [("Mail", "/System/Applications/Mail.app", "Inbox"),
                ("Calendar", "/System/Applications/Calendar.app", "October 2026")],
            3: [("Music", "/System/Applications/Music.app", "Deep Focus")],
            4: [("Messages", "/System/Applications/Messages.app", "Messages")],
            5: [("Photos", "/System/Applications/Photos.app", "Library"),
                ("Preview", "/System/Applications/Preview.app", "Field notes.pdf")],
            7: [("Maps", "/System/Applications/Maps.app", "Erie, Pennsylvania")],
            9: [("System Settings", "/System/Applications/System Settings.app", "Keyboard")],
        ]
        // Where the sample windows are on a 1512 x 945 screen: two sit side by side, the rest overlap.
        var frames: [String: CGRect] = [
            "Mail": CGRect(x: 0, y: 38, width: 756, height: 907), "Calendar": CGRect(x: 756, y: 38, width: 756, height: 907),
            "Safari": CGRect(x: 120, y: 80, width: 1100, height: 760), "Notes": CGRect(x: 300, y: 140, width: 800, height: 600),
            "Terminal": CGRect(x: 560, y: 360, width: 760, height: 480),
        ]
        // BANEYSPACES_RENDER_SAMPLE=reported: Donovan's load of 2026-11-01, workspace 1 holding seven windows, the rest empty.
        if ProcessInfo.processInfo.environment["BANEYSPACES_RENDER_SAMPLE"] == "reported" {
            sample = [1: [("Microsoft Word", "/Applications/Microsoft Word.app", "Document1"),
                          ("Helium", "/Applications/Helium.app", "Quiz question 1 of 13 - Helium"),
                          ("Obsidian", "/Applications/Obsidian.app", "Dashboard - Notes - Obsidian"),
                          ("T3 Code (Nightly)", "/Applications/T3 Code (Nightly).app", ""),
                          ("Microsoft Excel", "/Applications/Microsoft Excel.app", "Lab_results_B_and_C"),
                          ("Grok Bot", "/Applications/Grok Bot.app", ""),
                          ("Terminal", "/System/Applications/Utilities/Terminal.app", "")]]
            frames = ["Microsoft Word": CGRect(x: 40, y: 60, width: 1100, height: 760), "Helium": CGRect(x: 0, y: 38, width: 1512, height: 907),
                      "Obsidian": CGRect(x: 120, y: 90, width: 1180, height: 800), "T3 Code (Nightly)": CGRect(x: 60, y: 60, width: 1300, height: 840),
                      "Microsoft Excel": CGRect(x: 200, y: 120, width: 1100, height: 700), "Grok Bot": CGRect(x: 300, y: 150, width: 900, height: 640),
                      "Terminal": CGRect(x: 520, y: 380, width: 760, height: 480)]
        }
        // Product shots always show the default look, whatever this Mac has picked.
        Appearance.shared.useDefaultLookWithoutSaving()
        // BANEYSPACES_RENDER_THEME=omarchy|minimal draws the same shots in that theme (a check, saved nowhere).
        if let t = ProcessInfo.processInfo.environment["BANEYSPACES_RENDER_THEME"], let id = ThemeID(rawValue: t) {
            Appearance.shared.settings.theme = id
        }
        // BANEYSPACES_RENDER_PALETTE=<name> likewise picks a palette.
        if let p = ProcessInfo.processInfo.environment["BANEYSPACES_RENDER_PALETTE"], PaletteCatalog.shared.named(p) != nil {
            Appearance.shared.settings.colorPalette = p
        }
        let model = ViewerModel()
        model.current = 1
        var id: WindowID = 100
        for (n, windows) in sample {
            model.tiles[n] = windows.map { app, path, title in
                id += 1
                model.icons[id] = NSWorkspace.shared.icon(forFile: path)
                return Spaces.Entry(id: id, pid: 0, app: app, title: title, frame: frames[app])
            }
        }
        for n in 1...9 where model.tiles[n] == nil { model.tiles[n] = [] }
        let size = CGSize(width: 1512, height: 945)
        // Drawn by AppKit in an offscreen window (never shown), so colors match the live app.
        func save(_ view: some View, _ name: String, _ size: CGSize) -> Bool {
            let height: CGFloat? = size.height == 0 ? nil : size.height
            let framed = view.frame(width: size.width, height: height).environment(\.colorScheme, .dark)
            let host = NSHostingView(rootView: framed)
            // Height 0 means "as tall as the content".
            let size = size.height == 0 ? CGSize(width: size.width, height: host.fittingSize.height) : size
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = rep.representation(using: .png, properties: [:])
            return (try? png?.write(to: folder.appendingPathComponent(name))) != nil
        }
        guard save(ViewerView(model: model, stillBackdrop: true), "overview.png", size) else { return 1 }

        // The same overview mid-drag: a window on its way to workspace 6, which opens from the strip to a full tile.
        let mover = (model.tiles[2]?.first ?? model.tiles[1]?.first)!
        let from = model.tiles[2]?.isEmpty == false ? 2 : 1
        _ = model.layout(for: size)
        let slot6 = model.lastLayout?.slot(6)?.frame ?? model.lastLayout?.tile(6)?.frame ?? CGRect(x: 700, y: 700, width: 60, height: 60)
        model.drag = ViewerModel.Drag(entry: mover, from: from, location: CGPoint(x: slot6.midX, y: slot6.midY - 6))
        model.dragMoved()
        guard save(ViewerView(model: model, stillBackdrop: true), "overview-drag.png", size) else { return 1 }
        // A window carried up by its title bar opens the same view.
        model.carrying = true
        guard save(ViewerView(model: model, stillBackdrop: true), "overview-carry.png", size) else { return 1 }
        model.carrying = false
        model.drag = nil
        model.openSlot = nil

        // Typing to find: "exc" lights Excel (or the first app of the sample) and dims the rest to a quarter.
        let findable = model.tiles.values.flatMap { $0 }.first { $0.app.localizedCaseInsensitiveContains("exc") } ?? mover
        model.query = findable.app.localizedCaseInsensitiveContains("exc") ? "exc" : String(findable.app.prefix(3)).lowercased()
        guard save(ViewerView(model: model, stillBackdrop: true), "overview-find.png", size) else { return 1 }
        model.query = ""

        // With live previews (drawn here as stand-ins; the real ones come from Screen Recording).
        for list in model.tiles.values { for e in list { model.previews[e.id] = Self.stand(in: e.frame?.size ?? CGSize(width: 1100, height: 700), title: e.app) } }
        guard save(ViewerView(model: model, stillBackdrop: true), "overview-previews.png", size) else { return 1 }
        model.previews = [:]

        let setup = SetupModel()
        setup.trusted = true
        setup.started = true
        setup.modifier = .command
        setup.conflicts = []
        setup.desktops = 1
        setup.openAtLogin = true
        setup.viewerKeys = true
        setup.parkedApps = { [.init(id: "com.apple.Safari", name: "Safari", on: false, animates: false),
                            .init(id: "com.example.automation", name: "Automation Helper", on: true, animates: false),
                            .init(id: "com.mitchellh.ghostty", name: "Ghostty", on: true, animates: true)] }
        setup.update = .init(have: "0.3.0 (abc1234)", channel: .stable, daily: true, nightlyNeedsTools: false, notice: UpdateNotice(name: "BaneySpaces 0.3.1", isNightly: false, installing: false))
        setup.finished = [.init(id: "a", label: "Claude Code · baneyspaces")]
        guard save(SetupView(model: setup, close: {}).background(Color(nsColor: .windowBackgroundColor)),
                   "setup.png", CGSize(width: 560, height: 0)) else { return 1 }
        // Each settings tab, for checks.
        for tab in SettingsTab.allCases.dropFirst() {
            setup.tab = tab
            guard save(SetupView(model: setup, close: {}).background(Color(nsColor: .windowBackgroundColor)),
                       "setup-\(tab.rawValue.lowercased()).png", CGSize(width: 560, height: 0)) else { return 1 }
        }
        setup.tab = .general
        // The ⌘Tab workspace switcher, second tile selected.
        let switcher = SwitcherModel()
        let icon = { (path: String) in NSWorkspace.shared.icon(forFile: path) }
        switcher.tiles = [
            .init(n: 1, icons: [icon("/Applications/Safari.app"), icon("/System/Applications/Notes.app"), icon("/System/Applications/Utilities/Terminal.app")], count: 3),
            .init(n: 2, icons: [icon("/System/Applications/Mail.app"), icon("/System/Applications/Calendar.app")], count: 2),
            .init(n: 5, icons: [icon("/System/Applications/Photos.app")], count: 1),
            .init(n: 3, icons: [icon("/System/Applications/Music.app")], count: 1),
        ]
        switcher.selected = 1
        guard save(SwitcherView(model: switcher), "switcher.png", CGSize(width: 520, height: 0)) else { return 1 }

        // The ⌘Tab app switcher across workspaces, Mail selected.
        let appSwitcher = SwitcherModel()
        appSwitcher.mode = .apps
        // Ghostty is on workspaces 1 and 4 (two windows there): two entries, told apart by color.
        appSwitcher.apps = [("Safari", "/Applications/Safari.app", 1, 1, false), ("Ghostty", "/System/Applications/Utilities/Terminal.app", 4, 2, true),
                            ("Mail", "/System/Applications/Mail.app", 2, 1, false), ("Ghostty", "/System/Applications/Utilities/Terminal.app", 1, 1, true),
                            ("Music", "/System/Applications/Music.app", 3, 1, false), ("Maps", "/System/Applications/Maps.app", 7, 1, false)]
            .enumerated().map { i, a in SwitcherModel.AppTile(pid: a.4 ? 99 : pid_t(i + 1), name: a.0, icon: icon(a.1), workspace: a.2, windows: a.3, isSplit: a.4) }
        appSwitcher.selected = 1
        guard save(SwitcherView(model: appSwitcher).padding(30), "switcher-apps.png", CGSize(width: 820, height: 0)) else { return 1 }

        // The Workspace Dock with workspace 4 current, hovering Terminal on workspace 1.
        let dock = DockModel()
        let app = { (n: Int, name: String, path: String) in
            DockModel.App(id: "\(n)\(name)", pid: name == "Terminal" ? 99 : pid_t(n * 10 + name.count), name: name, icon: icon(path),
                          windows: name == "Terminal" && n == 4 ? 2 : 1)
        }
        dock.tiles = [
            .init(id: 1, apps: [app(1, "Claude", "/Applications/Safari.app"), app(1, "Terminal", "/System/Applications/Utilities/Terminal.app")], isCurrent: false),
            .init(id: 2, apps: [app(2, "Music", "/System/Applications/Music.app")], isCurrent: false),
            .init(id: 3, apps: [app(3, "Notes", "/System/Applications/Notes.app")], isCurrent: false),
            .init(id: 4, apps: [app(4, "Mail", "/System/Applications/Mail.app"), app(4, "Terminal", "/System/Applications/Utilities/Terminal.app"),
                                app(4, "Messages", "/System/Applications/Messages.app")], isCurrent: true),
            .init(id: 5, apps: (0..<6).map { app(5, "App\($0)", ["/System/Applications/Photos.app", "/System/Applications/Maps.app", "/System/Applications/Preview.app", "/System/Applications/Books.app", "/System/Applications/News.app", "/System/Applications/Podcasts.app"][$0]) }, isCurrent: false),
        ]
        dock.hover = .app(1, "1Terminal")
        guard save(DockView(model: dock).padding(.vertical, 20).background(Color(white: 0.35)), "dock.png", CGSize(width: 820, height: 0)) else { return 1 }

        // Every agent badge: working on 1, asking on 2, an error on 3, a finish on 4.
        let agentDock = DockModel()
        func agent(_ n: Int, _ state: DockAgent.State, _ name: String, _ path: String) -> DockModel.Tile {
            var a = app(n, name, path)
            let ag = DockAgent(id: "\(n)", window: WindowID(n), workspace: n, state: state, name: "Claude", task: "Fix the build")
            a.agent = ag
            var t = DockModel.Tile(id: n, apps: [a, app(n, "Notes", "/System/Applications/Notes.app")], isCurrent: n == 1)
            t.agents = [ag]
            return t
        }
        // Two agents in one app: its icon shows the one asking, and nothing doubles up in the corner.
        var both = agent(5, .asking, "Terminal", "/System/Applications/Utilities/Terminal.app")
        both.agents.append(DockAgent(id: "5b", window: 55, workspace: 5, state: .working, name: "Claude", task: "Run the tests"))
        agentDock.tiles = [agent(1, .working, "Terminal", "/System/Applications/Utilities/Terminal.app"),
                           agent(2, .asking, "Terminal", "/System/Applications/Utilities/Terminal.app"),
                           agent(3, .failed, "Terminal", "/System/Applications/Utilities/Terminal.app"),
                           agent(4, .done, "Terminal", "/System/Applications/Utilities/Terminal.app"), both]
        guard save(DockView(model: agentDock).padding(.vertical, 20).background(Color(white: 0.35)), "dock-agents.png", CGSize(width: 820, height: 0)) else { return 1 }

        // The switch HUD, landing on workspace 4.
        let hud = HUDModel()
        hud.current = 4
        hud.occupied = [1, 2, 3, 4, 5, 7]
        hud.icons = [icon("/System/Applications/Mail.app"), icon("/System/Applications/Utilities/Terminal.app"), icon("/System/Applications/Messages.app")]
        guard save(HUDView(model: hud).background(Color(white: 0.35)), "hud.png", CGSize(width: 260, height: 0)) else { return 1 }

        // The same dock with Terminal's window strip open over workspace 4.
        dock.tiles[3] = .init(id: 4, apps: dock.tiles[3].apps.map { a in
            var a = a
            if a.name == "Terminal" {
                a.list = [.init(id: 1, title: "New Tab"), .init(id: 2, title: "Forward and auto-reply - Proton Account", isLast: true),
                          .init(id: 3, title: "YouTube - I finally ported TypeScript to Go")]
            }
            return a
        }, isCurrent: true)
        dock.hover = .app(4, "4Terminal")
        dock.strip = (4, "4Terminal")
        guard save(DockView(model: dock).padding(.vertical, 20).background(Color(white: 0.35)), "dock-strip.png", CGSize(width: 820, height: 0)) else { return 1 }

        // The dock on the other edges: a side dock with a hover label, the top dock with the strip.
        dock.strip = nil
        dock.edge = .left
        dock.hover = .tile(2)
        guard save(DockView(model: dock).padding(20).background(Color(white: 0.35)), "dock-left.png", CGSize(width: 520, height: 0)) else { return 1 }
        dock.edge = .right
        dock.hover = .app(4, "4Terminal")
        dock.strip = (4, "4Terminal")
        guard save(DockView(model: dock).padding(20).background(Color(white: 0.35)), "dock-right.png", CGSize(width: 520, height: 0)) else { return 1 }
        // A short screen: the side dock shrinks to fit.
        dock.strip = nil
        dock.hover = nil
        dock.edge = .left
        dock.maxLength = 560
        guard save(DockView(model: dock).padding(20).background(Color(white: 0.35)), "dock-left-fit.png", CGSize(width: 520, height: 0)) else { return 1 }
        dock.maxLength = .infinity
        dock.hover = .app(4, "4Terminal")
        dock.strip = (4, "4Terminal")
        dock.edge = .top
        guard save(DockView(model: dock).padding(.vertical, 20).background(Color(white: 0.35)), "dock-top.png", CGSize(width: 820, height: 0)) else { return 1 }
        dock.edge = .bottom

        // Mail dragged from workspace 4 onto workspace 2. The first pass measures the tiles.
        dock.strip = nil
        dock.hover = nil
        let dragView = DockView(model: dock).padding(.vertical, 20).background(Color(white: 0.35))
        guard save(dragView, "dock-drag.png", CGSize(width: 820, height: 0)), let two = dock.frames["tile:2"] else { return 1 }
        dock.drag = .init(ids: [1], from: 4, icon: icon("/System/Applications/Mail.app"), name: "Mail", location: CGPoint(x: two.midX + 6, y: two.midY - 4))
        guard save(dragView, "dock-drag.png", CGSize(width: 820, height: 0)) else { return 1 }
        dock.drag = nil

        // The ⌘Tab window bar: Tab held on Helium.
        let bar = SwitcherModel()
        bar.mode = .apps
        bar.windowBar = .init(pid: 1, name: "Helium", icon: icon("/Applications/Safari.app"),
                              windows: [.init(id: 1, title: "YouTube — I finally ported TypeScript to Go", workspace: 4),
                                        .init(id: 2, title: "GitHub — baney75/baneyspaces pull request 3", workspace: 4),
                                        .init(id: 3, title: "Gmail — Inbox", workspace: 1)], selected: 1)
        guard save(SwitcherView(model: bar).padding(30), "switcher-windows.png", CGSize(width: 820, height: 0)) else { return 1 }

        // The launcher: the opening menu, then a search.
        let launcher = LauncherModel(actions: LauncherActions())
        launcher.prepare(scope: .root)
        guard save(LauncherView(model: launcher).frame(height: 500).padding(30).background(Color(white: 0.3)), "launcher.png", CGSize(width: 760, height: 0)) else { return 1 }
        launcher.query = "ma"
        guard save(LauncherView(model: launcher).frame(height: 500).padding(30).background(Color(white: 0.3)), "launcher-search.png", CGSize(width: 760, height: 0)) else { return 1 }
        // A coding agent by name, offered in your terminal.
        launcher.agents = ["claude": "/usr/local/bin/claude", "codex": "/usr/local/bin/codex"]
        launcher.query = "claude"
        guard save(LauncherView(model: launcher).frame(height: 500).padding(30).background(Color(white: 0.3)), "launcher-agents.png", CGSize(width: 760, height: 0)) else { return 1 }

        // Bangs: typing "!", then a question for the default agent.
        launcher.query = "!y"
        guard save(LauncherView(model: launcher).frame(height: 500).padding(30).background(Color(white: 0.3)), "launcher-bangs.png", CGSize(width: 760, height: 0)) else { return 1 }
        launcher.query = "sunset photos"
        guard save(LauncherView(model: launcher).frame(height: 500).padding(30).background(Color(white: 0.3)), "launcher-web.png", CGSize(width: 760, height: 0)) else { return 1 }

        // The first thing a new person sees: permission not granted yet.
        let fresh = SetupModel()
        fresh.trusted = false
        fresh.modifier = .command
        fresh.conflicts = []
        fresh.desktops = 1
        fresh.openAtLogin = false
        fresh.viewerKeys = true
        guard save(SetupView(model: fresh, close: {}).background(Color(nsColor: .windowBackgroundColor)),
                   "setup-first-run.png", CGSize(width: 560, height: 0)) else { return 1 }
        return 0
    }

    /// A window-shaped picture: a title bar and lines of text, tinted by name. Stands in for a live preview in product shots.
    static func stand(in size: CGSize, title: String) -> NSImage {
        let hue = CGFloat(title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
        let image = NSImage(size: size, flipped: true) { r in
            NSColor(hue: hue, saturation: 0.25, brightness: 0.30, alpha: 1).setFill()
            r.fill()
            NSColor(hue: hue, saturation: 0.30, brightness: 0.42, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: r.width, height: 36).fill()
            NSColor(hue: hue, saturation: 0.15, brightness: 0.62, alpha: 1).setFill()
            var y: CGFloat = 70
            var k = 0
            while y < r.height - 30 {
                NSRect(x: 40, y: y, width: (r.width - 80) * (k % 3 == 0 ? 0.55 : k % 3 == 1 ? 0.85 : 0.7), height: 10).fill()
                y += 28; k += 1
            }
            return true
        }
        return image
    }
}
