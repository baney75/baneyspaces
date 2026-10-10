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
        return 0
    }
}
