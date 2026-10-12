import AppKit
import BaneySpacesCore
import SwiftUI

/// ⌘Tab across workspaces: hold ⌘, tap Tab to step, let go to go there. ⌘⇧Tab steps back;
/// Esc cancels. In app mode it steps through every app with a window, on any workspace, most
/// recently used first, and letting go lands on that app's window wherever it is. In workspace
/// mode it steps through workspaces with windows, most recent first.
final class WorkspaceSwitcher {
    private let spaces: Spaces
    private let model = SwitcherModel()
    private var panel: NSPanel?
    private var watchdog: Timer?
    /// Apps in the order they were last brought forward, most recent first.
    private var appOrder: [pid_t] = []

    init(spaces: Spaces) {
        self.spaces = spaces
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier { appOrder = [front] }
    }

    var isShowing: Bool { panel?.isVisible == true }

    /// Called for every app that comes forward, by any means.
    func noteActivated(_ pid: pid_t) {
        guard pid != getpid() else { return }
        appOrder.removeAll { $0 == pid }
        appOrder.insert(pid, at: 0)
        if appOrder.count > 64 { appOrder.removeLast() }
    }

    func step(forward: Bool) {
        if !isShowing {
            model.mode = MissionControlKeys.cmdTabMode == .workspaces ? .workspaces : .apps
            if model.mode == .workspaces {
                let order = spaces.switcherOrder()
                Trace.log("cmdTab show order=\(order) current=\(spaces.model.current)")
                model.tiles = order.map { n in
                    SwitcherModel.Tile(n: n, icons: icons(on: n), count: spaces.entries(on: n).count)
                }
            } else {
                model.apps = appTiles()
                Trace.log("cmdTab show apps=\(model.apps.count) current=\(spaces.model.current)")
            }
            // The first tap lands on the previous one, like the app switcher.
            let c = model.count
            model.selected = c > 1 ? (forward ? 1 : c - 1) : 0
            show()
        } else if model.count > 0 {
            let c = model.count
            model.selected = (model.selected + (forward ? 1 : c - 1)) % c
        }
    }

    func commit() {
        guard isShowing else { return }
        hide()
        switch model.mode {
        case .workspaces:
            let target = model.tiles.indices.contains(model.selected) ? model.tiles[model.selected].n : nil
            Trace.log("cmdTab commit target=\(target.map(String.init) ?? "none") current=\(spaces.model.current)")
            if let target, target != spaces.model.current { spaces.switchTo(target, announce: false) }
        case .apps:
            guard model.apps.indices.contains(model.selected) else { return }
            let app = model.apps[model.selected]
            Trace.log("cmdTab commit app on=\(app.workspace) current=\(spaces.model.current)")
            noteActivated(app.pid)
            spaces.focusApp(app.pid, on: app.workspace)
        }
    }

    func cancel() {
        Trace.log("cmdTab cancel")
        hide()
    }

    /// Every app with a window, most recently used first; an app on two workspaces once for each.
    private func appTiles() -> [SwitcherModel.AppTile] {
        var windows: [(app: Int32, workspace: Int)] = []
        var names: [pid_t: String] = [:]
        var titles: [String: [String]] = [:]
        for n in Workspaces.range {
            for e in spaces.entries(on: n) {
                windows.append((e.pid, n))
                names[e.pid] = e.app
                titles["\(e.pid):\(n)", default: []].append(e.title)
            }
        }
        var last: [Int32: Int] = [:]
        for pid in Set(windows.map(\.app)) { last[pid] = spaces.lastWorkspace(of: pid) }
        let list = AppSwitchList.make(windows: windows, appOrder: appOrder, workspaceOrder: spaces.recent, lastWorkspace: last)
        return list.map { e in
            SwitcherModel.AppTile(pid: e.app, name: names[e.app] ?? "App",
                                  icon: NSRunningApplication(processIdentifier: e.app)?.icon ?? NSWorkspace.shared.icon(for: .application),
                                  workspace: e.workspace, windows: e.windows, isSplit: e.isSplit,
                                  titles: titles["\(e.app):\(e.workspace)"] ?? [])
        }
    }

    private func icons(on n: Int) -> [NSImage] {
        var seen = Set<pid_t>()
        return spaces.entries(on: n).compactMap { e -> NSImage? in
            guard seen.insert(e.pid).inserted else { return nil }
            return NSRunningApplication(processIdentifier: e.pid)?.icon
        }
    }

    private func show() {
        let p = panel ?? makePanel()
        panel = p
        let host = p.contentView as! NSHostingView<SwitcherView>
        // Lay out the new tiles first; otherwise fittingSize still reports the last gesture's size.
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            p.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
        }
        p.orderFrontRegardless()
        // If the key watcher misses ⌘ being let go (it was off for a moment), notice it here.
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.isShowing else { return }
            if !NSEvent.modifierFlags.contains(.command) {
                MissionControlKeys.inGesture = false
                self.commit()
            }
        }
    }

    private func hide() {
        watchdog?.invalidate()
        watchdog = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: SwitcherView(model: model))
        return p
    }
}

final class SwitcherModel: ObservableObject {
    enum Mode { case apps, workspaces }
    struct Tile: Identifiable {
        let n: Int
        let icons: [NSImage]
        let count: Int
        var id: Int { n }
    }
    struct AppTile: Identifiable {
        let pid: pid_t
        let name: String
        let icon: NSImage
        let workspace: Int
        let windows: Int
        /// The same app has windows on another workspace too.
        let isSplit: Bool
        var titles: [String] = []
        var id: String { "\(pid):\(workspace)" }
    }
    @Published var mode = Mode.workspaces
    @Published var tiles: [Tile] = []
    @Published var apps: [AppTile] = []
    @Published var selected = 0
    var count: Int { mode == .apps ? apps.count : tiles.count }
}

struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel

    var body: some View {
        Group {
            if model.mode == .apps { appRow } else { workspaceRow }
        }
        .padding(14)
        .background(Chrome.panel(cornerRadius: 26))
        .environment(\.colorScheme, .dark)
    }

    /// Long lists wrap onto more rows instead of running off the screen. An app on two
    /// workspaces shows twice, each copy in its workspace's color with the number on it.
    private var appRow: some View {
        let columns = Array(repeating: GridItem(.fixed(104), spacing: 8), count: min(max(model.apps.count, 1), 8))
        return VStack(spacing: 10) {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Array(model.apps.enumerated()), id: \.element.id) { i, app in
                    let on = i == model.selected
                    let tint = Chrome.workspace(app.workspace)
                    VStack(spacing: 6) {
                        ZStack(alignment: .topTrailing) {
                            Image(nsImage: app.icon).resizable().frame(width: 64, height: 64)
                            WorkspaceBadge(n: app.workspace).offset(x: 8, y: -4)
                            if app.windows > 1 {
                                Text("×\(app.windows)").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(.white)
                                    .padding(.horizontal, 5).frame(minHeight: 17)
                                    .background(Capsule().fill(Color.black.opacity(0.75)))
                                    .offset(x: 8, y: 50)
                            }
                        }
                        Text(app.name).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(on ? 1 : 0.7))
                            .lineLimit(1).frame(maxWidth: 92)
                    }
                    .frame(width: 104, height: 108)
                    // A split app's copies are told apart at a glance by their workspace's color.
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(on ? tint.opacity(0.28) : app.isSplit ? tint.opacity(0.10) : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(on ? tint : app.isSplit ? tint.opacity(0.35) : .clear, lineWidth: on ? 2 : 1))
                    .accessibilityLabel("\(app.name), workspace \(app.workspace), \(app.windows) windows\(on ? ", selected" : "")")
                }
            }
            if model.apps.indices.contains(model.selected) {
                let app = model.apps[model.selected]
                let title = app.titles.first { !$0.isEmpty }
                HStack(spacing: 6) {
                    Circle().fill(Chrome.workspace(app.workspace)).frame(width: 7, height: 7)
                    Text(["Workspace \(app.workspace)", app.windows > 1 ? "\(app.windows) windows" : title].compactMap { $0 }.joined(separator: " · "))
                        .lineLimit(1)
                }
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: 600)
            }
        }
    }

    private var workspaceRow: some View {
        HStack(spacing: 12) {
            ForEach(Array(model.tiles.enumerated()), id: \.element.id) { i, tile in
                let on = i == model.selected
                VStack(spacing: 8) {
                    Text("\(tile.n)")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    HStack(spacing: -6) {
                        ForEach(Array(tile.icons.prefix(4).enumerated()), id: \.offset) { _, icon in
                            Image(nsImage: icon).resizable().frame(width: 26, height: 26)
                        }
                    }
                    .frame(height: 26)
                    Text(tile.count == 0 ? "Empty" : tile.count == 1 ? "1 window" : "\(tile.count) windows")
                        .font(.caption).foregroundStyle(.white.opacity(0.65))
                }
                .frame(width: 108, height: 128)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(on ? Color.white.opacity(0.16) : Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(on ? Chrome.accent.opacity(0.9) : Color.white.opacity(0.08), lineWidth: on ? 2 : 1))
                .accessibilityLabel("Workspace \(tile.n), \(tile.count) windows\(on ? ", selected" : "")")
            }
        }
    }
}

/// A workspace's number in its own color, the same everywhere: dock, ⌘Tab and launcher.
struct WorkspaceBadge: View {
    let n: Int
    var size: CGFloat = 20
    var body: some View {
        Text("\(n)")
            .font(.system(size: size * 0.55, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(minWidth: size, minHeight: size)
            .background(Circle().fill(Chrome.workspace(n)))
            .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 1))
    }
}

/// The look shared by the dock, the switcher and the launcher: a dark glass panel and one accent.
enum Chrome {
    static let accent = Color(red: 0.91, green: 0.26, blue: 0.29)

    /// One color per workspace, around the color wheel so neighbors never look alike. White
    /// text reads on all of them.
    static func workspace(_ n: Int) -> Color {
        let hues: [Double] = [0.0, 0.07, 0.12, 0.33, 0.47, 0.55, 0.62, 0.74, 0.86]
        let h = hues[(max(1, min(9, n)) - 1)]
        // Yellow-green hues read lighter, so they get a little less brightness for white text.
        let dim = (0.10...0.36).contains(h) ? 0.68 : 0.80
        return Color(hue: h, saturation: 0.62, brightness: dim)
    }

    static func panel(cornerRadius r: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: r, style: .continuous)
        return shape.fill(.ultraThinMaterial)
            // Dark enough that text in the windows behind never reads through.
            .overlay(shape.fill(Color(white: 0.07).opacity(0.88)))
            // A light top edge and a faint outline, like glass catching light.
            .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.06)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
    }
}

/// A short record of ⌘Tab gestures in trace.log, to diagnose a switcher that misbehaves. It
/// notes only the gesture (Tab, ⌘ let go, Esc) and workspace numbers, never other keys.
enum Trace {
    static func log(_ line: String) {
        let url = Spaces.folder.appendingPathComponent("trace.log")
        let text = "\(Date().timeIntervalSince1970) \(line)\n"
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 200_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(text.utf8))
            try? h.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }
}
