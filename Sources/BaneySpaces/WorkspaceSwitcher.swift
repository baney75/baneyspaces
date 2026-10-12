import AppKit
import BaneySpacesCore
import SwiftUI

/// ⌘Tab across workspaces: hold ⌘, tap Tab to step, let go to go there. ⌘⇧Tab steps back;
/// Esc cancels. In app mode it steps through every app with a window, on any workspace, most
/// recently used first, and letting go lands on that app's window wherever it is. In workspace
/// mode it steps through workspaces with windows, most recent first.
///
/// Holding Tab on an app with more than one window opens the window bar: that app's windows,
/// on every workspace, to tab through the same way. Holding Tab again goes back to the apps.
final class WorkspaceSwitcher {
    private let spaces: Spaces
    private let model = SwitcherModel()
    private var panel: NSPanel?
    private var watchdog: Timer?
    /// Apps in the order they were last brought forward, most recent first.
    private var appOrder: [pid_t] = []
    private var hold = TabHold()
    /// Tab presses in this gesture, not counting repeats.
    private var presses = 0
    private var selectedBeforePress = 0

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

    /// `time` is the system uptime when the key arrived, read on the tap's thread.
    func step(forward: Bool, isRepeat: Bool, at time: Double) {
        // A held Tab opens or closes the window bar once; its other repeats do nothing, so
        // holding never races through the list.
        if isRepeat {
            guard isShowing, model.mode == .apps, hold.repeated(at: time) else { return }
            if model.windowBar != nil { return toggleWindowBar() }
            let before = presses == 1 ? 0 : selectedBeforePress
            guard let target = TabHold.target(before: before, landed: model.selected, windows: windowCount(of:)) else {
                Trace.log("cmdTab hold: no app with more than one window")
                return
            }
            model.selected = target
            return toggleWindowBar()
        }
        hold.press(at: time)
        presses = isShowing ? presses + 1 : 1
        selectedBeforePress = model.selected
        if isShowing, model.windowBar != nil {
            let c = model.windowBar!.windows.count
            model.windowBar!.selected = (model.windowBar!.selected + (forward ? 1 : c - 1)) % c
            return
        }
        if !isShowing {
            model.windowBar = nil
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
            if let bar = model.windowBar, bar.windows.indices.contains(bar.selected) {
                let w = bar.windows[bar.selected]
                // Where it is now: it may have moved, or closed, since the bar opened.
                spaces.refresh()
                guard let n = spaces.model.workspace(of: w.id) else {
                    // Closed meanwhile: the app is still the choice.
                    Trace.log("cmdTab commit window gone")
                    return spaces.focusApp(bar.pid)
                }
                Trace.log("cmdTab commit window on=\(n) current=\(spaces.model.current)")
                noteActivated(bar.pid)
                return spaces.focus(w.id, on: n)
            }
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

    /// Opens the selected app's window bar, or closes it back to the apps. An app with one
    /// window has nothing to pick, so a hold on it does nothing.
    private func toggleWindowBar() {
        if model.windowBar != nil {
            model.windowBar = nil
            Trace.log("cmdTab window bar closed")
            return relayout()
        }
        guard model.apps.indices.contains(model.selected) else { return }
        let app = model.apps[model.selected]
        var windows: [SwitcherModel.WindowTile] = []
        for n in [app.workspace] + Workspaces.range.filter({ $0 != app.workspace }) {
            // The window used last on each workspace leads that workspace's group.
            let last = spaces.model.lastFocused[n]
            let mine = spaces.entries(on: n).filter { $0.pid == app.pid }.sorted { $0.id == last && $1.id != last }
            for e in mine { windows.append(.init(id: e.id, title: WindowTitle.clean(e.title, app: e.app), workspace: n)) }
        }
        guard windows.count > 1 else { return }
        Trace.log("cmdTab window bar opened windows=\(windows.count)")
        // The first one is the window that tapping would land on; a tap from here moves on.
        // For the app you're in, its first window is the one in front, so start on the next one.
        let inFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.pid && app.workspace == spaces.model.current
        model.windowBar = .init(pid: app.pid, name: app.name, icon: app.icon, windows: windows, selected: inFront ? 1 : 0)
        relayout()
    }

    /// Every window of the app at `index` in the list, on all workspaces.
    private func windowCount(of index: Int) -> Int {
        guard model.apps.indices.contains(index) else { return 0 }
        let pid = model.apps[index].pid
        return model.apps.filter { $0.pid == pid }.reduce(0) { $0 + $1.windows }
    }

    /// The bar changed size: keep it centered.
    private func relayout() {
        guard let p = panel, let host = p.contentView as? NSHostingView<SwitcherView> else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let screen = p.screen ?? NSScreen.main
        guard let frame = screen?.frame else { return }
        p.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height), display: true)
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
                MissionControlKeys.gestureEndedElsewhere()
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
    struct WindowTile: Identifiable {
        let id: WindowID
        let title: String
        let workspace: Int
    }
    /// The window bar: one app's windows, open while Tab was held on it.
    struct WindowBar {
        let pid: pid_t
        let name: String
        let icon: NSImage
        let windows: [WindowTile]
        var selected: Int
    }
    @Published var windowBar: WindowBar?
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
            if let bar = model.windowBar { windowRow(bar) } else if model.mode == .apps { appRow } else { workspaceRow }
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
                    if model.apps.filter({ $0.pid == app.pid }).reduce(0, { $0 + $1.windows }) > 1 {
                        Text("Hold Tab to pick a window").foregroundStyle(.white.opacity(0.4))
                    }
                }
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: 600)
            }
        }
    }

    /// One app's windows, each with its title and workspace color. Wraps after four.
    private func windowRow(_ bar: SwitcherModel.WindowBar) -> some View {
        let columns = Array(repeating: GridItem(.fixed(200), spacing: 8), count: min(bar.windows.count, 4))
        return VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(nsImage: bar.icon).resizable().frame(width: 22, height: 22)
                Text("\(bar.name) windows").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text("Hold Tab to go back").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.45))
            }
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Array(bar.windows.enumerated()), id: \.element.id) { i, w in
                    let on = i == bar.selected
                    let tint = Chrome.workspace(w.workspace)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(nsImage: bar.icon).resizable().frame(width: 30, height: 30)
                            Spacer()
                            WorkspaceBadge(n: w.workspace)
                        }
                        Text(w.title.isEmpty ? "Untitled window" : w.title)
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(on ? 1 : 0.75))
                            .lineLimit(2).multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
                    }
                    .padding(12)
                    .frame(width: 200)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(on ? tint.opacity(0.28) : Color.white.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(on ? tint : Color.white.opacity(0.08), lineWidth: on ? 2 : 1))
                    .accessibilityLabel("\(w.title), workspace \(w.workspace)\(on ? ", selected" : "")")
                }
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
