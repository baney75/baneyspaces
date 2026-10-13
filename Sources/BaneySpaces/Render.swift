import AppKit
import BaneySpacesCore
import SwiftUI

/// `BaneySpaces --render <folder>` draws the overview, still and mid-drag, with sample windows
/// into PNGs, for the README and the website. It never touches real windows.
@MainActor
enum Render {
    static func run(into folder: URL) -> Int32 {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sample: [Int: [(String, String, String)]] = [
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
        let model = ViewerModel()
        model.current = 1
        var id: WindowID = 100
        for (n, windows) in sample {
            model.tiles[n] = windows.map { app, path, title in
                id += 1
                model.icons[id] = NSWorkspace.shared.icon(forFile: path)
                return Spaces.Entry(id: id, pid: 0, app: app, title: title)
            }
        }
        for n in 1...9 where model.tiles[n] == nil { model.tiles[n] = [] }
        let size = CGSize(width: 1512, height: 945)
        // Tile frames as the live layout places them, so the drag image can light its target.
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

        // The same overview mid-drag: Mail's window on its way to workspace 6.
        let mail = model.tiles[2]![0]
        // Mirrors ViewerView's layout: 48pt padding, 20pt gaps, a 40pt footer.
        let pad: CGFloat = 48, gap: CGFloat = 20, footer: CGFloat = 40
        let gridWidth: CGFloat = min(size.width, 1600) - 2 * pad
        let tileW: CGFloat = (gridWidth - 2 * gap) / 3
        let tileH: CGFloat = (size.height - 2 * pad - footer - 2 * gap) / 3
        let targetX: CGFloat = pad + 2 * (tileW + gap)
        let targetY: CGFloat = pad + tileH + gap
        let target = CGRect(x: targetX, y: targetY, width: tileW, height: tileH)
        model.tileFrames = [6: target]
        model.drag = ViewerModel.Drag(entry: mail, from: 2, location: CGPoint(x: target.midX - 40, y: target.midY + 10))
        guard save(ViewerView(model: model, stillBackdrop: true), "overview-drag.png", size) else { return 1 }

        let setup = SetupModel()
        setup.trusted = true
        setup.modifier = .command
        setup.conflicts = []
        setup.desktops = 1
        setup.openAtLogin = true
        setup.viewerKeys = true
        guard save(SetupView(model: setup, close: {}).background(Color(nsColor: .windowBackgroundColor)),
                   "setup.png", CGSize(width: 520, height: 0)) else { return 1 }
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
                   "setup-first-run.png", CGSize(width: 520, height: 0)) else { return 1 }
        return 0
    }
}
