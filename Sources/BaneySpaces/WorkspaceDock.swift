import AppKit
import BaneySpacesCore
import SwiftUI

/// The macOS Dock, kept out of sight while the Workspace Dock is on. Its own settings are saved
/// first and put back exactly when the Workspace Dock goes off or BaneySpaces quits. Saved
/// values survive a crash, so the next launch (or the uninstaller) still restores the right ones.
enum SystemDock {
    private static let domain = "com.apple.dock" as CFString
    private static let savedKey = "systemDockSaved"
    /// Long enough that the Dock never slides up by accident while the Workspace Dock is in use.
    static let hiddenDelay = 1000.0

    static var isHiddenByUs: Bool { UserDefaults.standard.dictionary(forKey: savedKey) != nil }

    static func hide() {
        if !isHiddenByUs {
            // A setting that wasn't there is saved as absent, so restoring removes it again.
            var saved: [String: Any] = [:]
            for key in ["autohide", "autohide-delay"] { if let v = read(key) { saved[key] = v } }
            // Already at BaneySpaces' own values (its saved copy was lost: a crash, wiped
            // settings, another copy of the app): those aren't the person's. Save them as
            // absent, which restores the macOS defaults.
            if (saved["autohide-delay"] as? NSNumber)?.doubleValue == hiddenDelay { saved = [:] }
            UserDefaults.standard.set(saved, forKey: savedKey)
        }
        // Both writes run; either one changing means the Dock must restart to notice.
        let a = write("autohide", true as NSNumber)
        let b = write("autohide-delay", hiddenDelay as NSNumber)
        let changed = a || b
        if changed { restartDock() }
    }

    static func restore() {
        guard let saved = UserDefaults.standard.dictionary(forKey: savedKey) else { return }
        var changed = false
        // Only a setting still at the value BaneySpaces wrote goes back; one the person changed
        // since (⌥⌘D, System Settings) is their newer choice and stays.
        let ours: [String: NSNumber] = ["autohide": true as NSNumber, "autohide-delay": hiddenDelay as NSNumber]
        for key in ["autohide", "autohide-delay"] where read(key) == ours[key] {
            changed = write(key, saved[key] as? NSNumber) || changed
        }
        UserDefaults.standard.removeObject(forKey: savedKey)
        if changed { restartDock() }
    }

    private static func read(_ key: String) -> NSNumber? {
        CFPreferencesCopyAppValue(key as CFString, domain) as? NSNumber
    }

    /// Writes a setting (nil removes it); whether anything changed.
    private static func write(_ key: String, _ value: NSNumber?) -> Bool {
        guard read(key) != value else { return false }
        CFPreferencesSetAppValue(key as CFString, value, domain)
        CFPreferencesAppSynchronize(domain)
        return true
    }

    /// The Dock reads these settings when it starts; restarting it is how System Settings applies them.
    private static func restartDock() {
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = ["Dock"]
        try? kill.run()
    }
}

/// A dock of workspaces instead of apps: one tile for each workspace in use, showing its apps.
/// It waits out of sight and slides up when the pointer rests on the bottom edge of a screen,
/// the way the macOS Dock does when it hides itself. Click a tile to go there.
final class WorkspaceDock {
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "workspaceDock") }
        set { UserDefaults.standard.set(newValue, forKey: "workspaceDock") }
    }

    private let spaces: Spaces
    var onShowOverview: () -> Void = {}
    var onShowLauncher: () -> Void = {}
    var onTurnOff: () -> Void = {}
    let model = DockModel()
    private var panel: DockPanel?
    private var timer: Timer?
    private var edgeSince: Date?
    private var awaySince: Date?
    private(set) var isRunning = false
    private(set) var isShown = false
    /// Shown by a script or a test, not the pointer: it stays until hidden the same way.
    private var pinned = false

    init(spaces: Spaces) {
        self.spaces = spaces
        model.onPick = { [weak self] n in self?.spaces.switchTo(n, announce: false) }
        model.onSendHere = { [weak self] n in self?.spaces.moveFocused(to: n) }
        model.onFocusApp = { [weak self] pid, n in self?.spaces.focusApp(pid, on: n, cycle: true) }
        model.onFocusWindow = { [weak self] id, n in self?.spaces.focus(id, on: n) }
        // After SwiftUI has laid out the strip, so the new size is the real one.
        model.onLayoutChange = { [weak self] in DispatchQueue.main.async { self?.resize() } }
        model.onShowOverview = { [weak self] in self?.hide(); self?.onShowOverview() }
        model.onShowLauncher = { [weak self] in self?.hide(); self?.onShowLauncher() }
        model.onTurnOff = { [weak self] in self?.onTurnOff() }
        // A tile's right-click menu keeps the dock up while it's open.
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.model.menuOpen = true
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.model.menuOpen = false
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        SystemDock.hide()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// `restoreSystemDock` puts the macOS Dock back: when the Workspace Dock is turned off, and
    /// when BaneySpaces quits or loses its permission.
    func stop(restoreSystemDock: Bool) {
        timer?.invalidate()
        timer = nil
        isRunning = false
        pinned = false
        hide(animated: false)
        if restoreSystemDock { SystemDock.restore() }
    }

    /// Workspaces changed: a shown dock follows along.
    func reload() {
        // Mid-switch the windows are on the move; the switch's end calls this again.
        guard isShown, !spaces.switching else { return }
        model.load(from: spaces)
        resize()
    }

    // MARK: Showing and hiding

    private func tick() {
        guard isRunning, !pinned else { return }
        // The overview already shows every workspace; the dock stays down while it's open.
        if MissionControlKeys.viewerOpen { if isShown { hide() }; edgeSince = nil; return }
        let mouse = NSEvent.mouseLocation
        if isShown {
            guard let p = panel else { return }
            // Hovering the dock or the edge below it keeps it up; a menu open from it too.
            let keep = p.frame.insetBy(dx: -24, dy: -24).contains(mouse) || model.menuOpen
            if keep { awaySince = nil; return }
            if awaySince == nil { awaySince = Date() }
            if Date().timeIntervalSince(awaySince!) > 0.4 { hide() }
            return
        }
        // Resting on the bottom edge, buttons up (not dragging a window or a selection).
        // The bottom edge of a screen with no other screen below it, as the macOS Dock uses.
        let screen = NSScreen.screens.first { s in
            mouse.x >= s.frame.minX && mouse.x < s.frame.maxX && mouse.y >= s.frame.minY - 1 && mouse.y < s.frame.minY + 2
                && !NSScreen.screens.contains { $0 != s && $0.frame.contains(NSPoint(x: mouse.x, y: s.frame.minY - 1)) }
        }
        guard let screen, NSEvent.pressedMouseButtons == 0 else { edgeSince = nil; return }
        if edgeSince == nil { edgeSince = Date() }
        if Date().timeIntervalSince(edgeSince!) > 0.12 { show(on: screen) }
    }

    /// `baneyspaces://dock/show`: for scripts and checks. It stays until `dock/hide`.
    func pin(_ on: Bool) {
        guard isRunning else { return }
        pinned = on
        if on { show(on: NSScreen.main ?? NSScreen.screens[0]) } else { hide() }
    }

    private func show(on screen: NSScreen) {
        edgeSince = nil
        awaySince = nil
        model.load(from: spaces)
        let p = panel ?? makePanel()
        panel = p
        isShown = true
        let size = p.contentView?.fittingSize ?? .zero
        let up = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + 6, width: size.width, height: size.height)
        p.setFrame(up.offsetBy(dx: 0, dy: -18), display: false)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().setFrame(up, display: true)
            p.animator().alphaValue = 1
        }
    }

    func hide(animated: Bool = true) {
        guard isShown, let p = panel else { return }
        isShown = false
        model.reset()
        let down = p.frame.offsetBy(dx: 0, dy: -18)
        guard animated else { p.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().setFrame(down, display: true)
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.isShown else { return }
            p.orderOut(nil)
        })
    }

    /// Tiles come and go as workspaces fill and empty; the dock stays centered.
    private func resize() {
        guard let p = panel, let screen = p.screen ?? NSScreen.main else { return }
        let size = p.contentView?.fittingSize ?? p.frame.size
        guard size != p.frame.size else { return }
        p.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: p.frame.minY, width: size.width, height: size.height), display: true)
    }

    private func makePanel() -> DockPanel {
        let p = DockPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        // Not over full-screen apps: a video's controls or a game sit along that edge.
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.contentView = FirstClickHostingView(rootView: DockView(model: model).environment(\.colorScheme, .dark))
        return p
    }
}

/// Never takes the keyboard: clicking a tile leaves your app in front.
final class DockPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A click on a dock tile acts at once, without first bringing BaneySpaces forward.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class DockModel: ObservableObject {
    struct App: Identifiable {
        let id: String
        let pid: pid_t
        let name: String
        let icon: NSImage
        let windows: Int
        /// This app's windows on the tile's workspace, with their titles (a browser's front tab,
        /// a player's video), for the window strip.
        var list: [Window] = []
    }
    struct Window: Identifiable {
        let id: WindowID
        let title: String
    }
    struct Tile: Identifiable {
        let id: Int
        let apps: [App]
        let isCurrent: Bool
        var windowCount: Int { apps.reduce(0) { $0 + $1.windows } }
    }
    /// What the pointer rests on: a whole tile, one app in a tile, or a button.
    enum Hover: Equatable {
        case tile(Int)
        case app(Int, String)
        case newWorkspace, launcher, overview
    }

    @Published var tiles: [Tile] = []
    @Published var hover: Hover? { didSet { hoverChanged() } }
    /// The window strip: an app's windows on one workspace, opened by resting on its icon.
    @Published var strip: (workspace: Int, app: String)? { didSet { if (strip == nil) != (oldValue == nil) || strip?.app != oldValue?.app { onLayoutChange() } } }
    /// The pointer is on the strip itself, which keeps it open.
    var onStrip = false
    private var dwell: DispatchWorkItem?
    var onFocusWindow: (WindowID, Int) -> Void = { _, _ in }
    var onLayoutChange: () -> Void = {}
    var menuOpen = false
    var onPick: (Int) -> Void = { _ in }
    var onFocusApp: (pid_t, Int) -> Void = { _, _ in }
    var onSendHere: (Int) -> Void = { _ in }
    var onShowOverview: () -> Void = {}
    var onShowLauncher: () -> Void = {}
    var onTurnOff: () -> Void = {}

    /// The first workspace with nothing on it, for the "new workspace" button.
    var firstEmpty: Int? { Workspaces.range.first { n in !tiles.contains { $0.id == n && !$0.apps.isEmpty } } }

    func load(from spaces: Spaces) {
        spaces.refresh()
        var byPid: [String: Spaces.Entry] = [:]
        var windows: [Int: [String]] = [:]
        for n in Workspaces.range {
            let entries = spaces.entries(on: n)
            for e in entries { byPid["\(e.pid)"] = e }
            windows[n] = entries.map { "\($0.pid)" }
        }
        tiles = DockTiles.make(current: spaces.model.current, windows: windows).map { t in
            let entries = spaces.entries(on: t.workspace)
            return Tile(id: t.workspace, apps: t.apps.map { a in
                let pid = pid_t(a.key) ?? 0
                return App(id: a.key, pid: pid, name: byPid[a.key]?.app ?? "App",
                           icon: NSRunningApplication(processIdentifier: pid)?.icon ?? NSWorkspace.shared.icon(for: .application),
                           windows: a.windows,
                           list: entries.filter { "\($0.pid)" == a.key }.map { Window(id: $0.id, title: $0.title) })
            }, isCurrent: t.isCurrent)
        }
        // A strip for an app that's gone or down to one window closes.
        if let s = strip, (stripApp?.list.count ?? 0) < 2 || !tiles.contains(where: { $0.id == s.workspace }) { strip = nil }
    }

    var stripApp: App? {
        guard let s = strip else { return nil }
        return tiles.first { $0.id == s.workspace }?.apps.first { $0.id == s.app }
    }

    /// Resting on an app with more than one window here opens its strip after a moment. Moving
    /// to another app or button closes it; drifting up to the strip, or across its own tile, doesn't.
    private func hoverChanged() {
        dwell?.cancel()
        switch hover {
        case .app(let n, let id):
            if let s = strip, s.workspace == n, s.app == id { return }
            if strip != nil && !onStrip { strip = nil }
            guard let app = tiles.first(where: { $0.id == n })?.apps.first(where: { $0.id == id }), app.list.count > 1 else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.hover == .app(n, id) else { return }
                self.strip = (n, id)
            }
            dwell = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        case .newWorkspace, .launcher, .overview:
            if !onStrip { strip = nil }
        case .tile(let n):
            if let s = strip, s.workspace != n, !onStrip { strip = nil }
        case nil:
            break
        }
    }

    /// The dock went away.
    func reset() {
        dwell?.cancel()
        hover = nil
        onStrip = false
        strip = nil
    }

    func setHover(_ h: Hover, _ inside: Bool) {
        if inside { hover = h } else if hover == h { hover = nil }
    }
}

private struct AppCenters: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) { value.merge(nextValue()) { $1 } }
}

struct DockView: View {
    @ObservedObject var model: DockModel
    private let tileSize: CGFloat = 64
    /// Where each app icon's center sits across the dock, so the strip opens over its app.
    @State private var centers: [String: CGFloat] = [:]
    @State private var stripWidth: CGFloat = 0
    @State private var dockWidth: CGFloat = 0

    var body: some View {
        VStack(spacing: 8) {
            // Room above the tiles for what the pointer is on, or the window strip.
            if let app = model.stripApp, let n = model.strip?.workspace {
                windowStrip(app, workspace: n)
                    .background(GeometryReader { g in Color.clear.onAppear { stripWidth = g.size.width }.onChange(of: g.size.width) { stripWidth = $0 } })
                    .offset(x: stripOffset(n, app.id))
            } else {
                label.frame(height: 24)
            }
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(model.tiles) { tile in tileView(tile) }
                if let n = model.firstEmpty, !model.tiles.contains(where: { $0.id == n }) { newWorkspaceButton(n) }
                Capsule().fill(Color.white.opacity(0.14)).frame(width: 1, height: 44).padding(.horizontal, 4).padding(.bottom, 14)
                squareButton(.launcher, "magnifyingglass", "Find or Install an App") { model.onShowLauncher() }
                squareButton(.overview, "square.grid.3x3", "Show All Workspaces") { model.onShowOverview() }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .background(Chrome.panel(cornerRadius: 24))
            .background(GeometryReader { g in Color.clear.onAppear { dockWidth = g.size.width }.onChange(of: g.size.width) { dockWidth = $0 } })
        }
        .coordinateSpace(name: "dock")
        .onPreferenceChange(AppCenters.self) { centers = $0 }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        // Wide enough for a long label above a short dock.
        .frame(minWidth: 480)
        .fixedSize()
    }

    @ViewBuilder private var label: some View {
        if let text = labelText {
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.78)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
                .foregroundStyle(.white)
                .transition(.opacity)
        } else {
            Color.clear.frame(width: 1)
        }
    }

    private var labelText: String? {
        switch model.hover {
        case .tile(let n): return model.tiles.first { $0.id == n }.map(title)
        case .app(let n, let id):
            guard let app = model.tiles.first(where: { $0.id == n })?.apps.first(where: { $0.id == id }) else { return nil }
            let elsewhere = model.tiles.filter { $0.id != n && $0.apps.contains { $0.pid == app.pid } }.map { String($0.id) }
            var parts = ["\(app.name) · Workspace \(n)"]
            if app.windows > 1 { parts.append("\(app.windows) windows, click again for the next") }
            if !elsewhere.isEmpty { parts.append("also on \(elsewhere.joined(separator: ", "))") }
            return parts.joined(separator: " · ")
        case .newWorkspace: return model.firstEmpty.map { "Go to Empty Workspace \($0)" }
        case .launcher: return "Find or Install an App"
        case .overview: return "Show All Workspaces"
        case nil: return nil
        }
    }

    /// An app's windows on one workspace, each labeled with its title. Click one to go to it.
    private func windowStrip(_ app: DockModel.App, workspace n: Int) -> some View {
        let tint = Chrome.workspace(n)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(nsImage: app.icon).resizable().frame(width: 16, height: 16)
                Text("\(app.name) · \(app.list.count) windows").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white)
                WorkspaceBadge(n: n, size: 16)
            }
            HStack(spacing: 6) {
                ForEach(Array(app.list.prefix(8).enumerated()), id: \.element.id) { i, w in
                    StripCard(title: w.title, index: i + 1, tint: tint) { model.onFocusWindow(w.id, n) }
                }
            }
        }
        .padding(10)
        .background(Chrome.panel(cornerRadius: 16))
        .onHover { inside in model.onStrip = inside }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// Over the app, but never past either end of the dock.
    private func stripOffset(_ n: Int, _ id: String) -> CGFloat {
        guard let x = centers["\(n):\(id)"], dockWidth > 0, stripWidth > 0 else { return 0 }
        // Centers are measured in the dock's space, which is 16 points in from the panel edge.
        let fromMiddle = x - (dockWidth / 2 + 16)
        let room = max(0, (dockWidth - stripWidth) / 2)
        return min(max(fromMiddle, -room), room)
    }

    private func title(_ tile: DockModel.Tile) -> String {
        guard !tile.apps.isEmpty else { return "Workspace \(tile.id) · empty" }
        let apps = tile.apps.map { $0.windows > 1 ? "\($0.name) (\($0.windows))" : $0.name }
        return "Workspace \(tile.id) · \(apps.joined(separator: ", "))"
    }

    private func isHovered(_ tile: DockModel.Tile) -> Bool {
        switch model.hover {
        case .tile(let n), .app(let n, _): return n == tile.id
        default: return false
        }
    }

    private func tileView(_ tile: DockModel.Tile) -> some View {
        let hovered = isHovered(tile)
        let tint = Chrome.workspace(tile.id)
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return VStack(spacing: 5) {
            ZStack(alignment: .topLeading) {
                shape.fill(tile.isCurrent ? tint.opacity(hovered ? 0.34 : 0.26) : Color.white.opacity(hovered ? 0.13 : 0.06))
                    .overlay(shape.strokeBorder(tile.isCurrent ? tint : Color.white.opacity(hovered ? 0.18 : 0.08),
                                                lineWidth: tile.isCurrent ? 1.5 : 1))
                    .onHover { model.setHover(.tile(tile.id), $0) }
                    .onTapGesture { model.onPick(tile.id) }
                icons(tile).frame(width: tileSize, height: tileSize)
            }
            .frame(width: tileSize, height: tileSize)
            // The number under the tile, lit for the workspace you're on, like the key that gets there.
            Text("\(tile.id)")
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundStyle(tile.isCurrent ? Color.white : tint.opacity(hovered ? 1 : 0.85))
                .frame(minWidth: 18, minHeight: 15)
                .background(Capsule().fill(tile.isCurrent ? tint : Color.clear))
                .allowsHitTesting(false)
        }
        .scaleEffect(hovered ? 1.06 : 1, anchor: .bottom)
        .animation(.spring(response: 0.25, dampingFraction: 0.72), value: hovered)
        .contextMenu {
            Button("Go to Workspace \(tile.id)") { model.onPick(tile.id) }
            Button("Send Front Window to Workspace \(tile.id)") { model.onSendHere(tile.id) }
            Divider()
            Button("Find or Install an App") { model.onShowLauncher() }
            Button("Show All Workspaces") { model.onShowOverview() }
            Button("Turn Off Workspace Dock") { model.onTurnOff() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title(tile) + (tile.isCurrent ? ", current" : ""))
        .accessibilityAction { model.onPick(tile.id) }
    }

    /// One app fills the tile; two sit side by side; up to four share a grid; more show three
    /// and a count. Each icon is its own button that goes straight to that app.
    @ViewBuilder private func icons(_ tile: DockModel.Tile) -> some View {
        let apps = tile.apps
        if apps.isEmpty {
            Image(systemName: "plus").font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.3))
                .allowsHitTesting(false)
        } else if apps.count == 1 {
            appIcon(apps[0], in: tile, size: 42)
        } else if apps.count == 2 {
            HStack(spacing: 2) { ForEach(apps) { appIcon($0, in: tile, size: 28) } }
        } else {
            let shown = apps.count > 4 ? Array(apps.prefix(3)) : apps
            LazyVGrid(columns: [GridItem(.fixed(24), spacing: 3), GridItem(.fixed(24), spacing: 3)], spacing: 3) {
                ForEach(shown) { appIcon($0, in: tile, size: 24) }
                if apps.count > 4 {
                    Text("+\(apps.count - 3)")
                        .font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.85))
                        .frame(width: 24, height: 24)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.12)))
                        .onHover { model.setHover(.tile(tile.id), $0) }
                        .onTapGesture { model.onPick(tile.id) }
                }
            }
            .frame(width: 51)
        }
    }

    /// The app hovered anywhere in the dock, so its copies on other workspaces light up too.
    private var hoveredPid: pid_t? {
        guard case .app(let n, let id) = model.hover else { return nil }
        return model.tiles.first { $0.id == n }?.apps.first { $0.id == id }?.pid
    }

    private func appIcon(_ app: DockModel.App, in tile: DockModel.Tile, size: CGFloat) -> some View {
        let hovered = model.hover == .app(tile.id, app.id)
        let twin = !hovered && hoveredPid == app.pid
        return Image(nsImage: app.icon).resizable().interpolation(.high).frame(width: size, height: size)
            .shadow(color: .black.opacity(hovered ? 0.4 : 0.2), radius: hovered ? 4 : 2, y: 1)
            // The same app on another workspace: ringed in this tile's color while its twin is hovered.
            .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .strokeBorder(Chrome.workspace(tile.id), lineWidth: twin ? 2 : 0).padding(-2))
            // One dot per window when there's more than one; clicking again steps through them.
            .overlay(alignment: .bottom) {
                if app.windows > 1 {
                    HStack(spacing: 2) {
                        ForEach(0..<min(app.windows, 3), id: \.self) { _ in Circle().fill(Color.white).frame(width: 3, height: 3) }
                    }
                    .padding(.horizontal, 3).padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
                    .offset(y: 5)
                }
            }
            .background(GeometryReader { g in
                Color.clear.preference(key: AppCenters.self, value: ["\(tile.id):\(app.id)": g.frame(in: .named("dock")).midX])
            })
            .scaleEffect(hovered ? 1.18 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.65), value: hovered)
            .contentShape(Rectangle())
            .onHover { model.setHover(.app(tile.id, app.id), $0) }
            .onTapGesture { model.onFocusApp(app.pid, tile.id) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(app.name), workspace \(tile.id)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.onFocusApp(app.pid, tile.id) }
    }

    private func newWorkspaceButton(_ n: Int) -> some View {
        let hovered = model.hover == .newWorkspace
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return VStack(spacing: 5) {
            shape.strokeBorder(Color.white.opacity(hovered ? 0.35 : 0.16), style: StrokeStyle(lineWidth: 1.2, dash: [4, 4]))
                .background(shape.fill(Color.white.opacity(hovered ? 0.08 : 0.0)))
                .overlay(Image(systemName: "plus").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white.opacity(hovered ? 0.9 : 0.45)))
                .frame(width: tileSize * 0.75, height: tileSize)
            Color.clear.frame(width: 18, height: 15)
        }
        .contentShape(Rectangle())
        .onHover { model.setHover(.newWorkspace, $0) }
        .onTapGesture { model.onPick(n) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Go to empty workspace \(n)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.onPick(n) }
    }

    private func squareButton(_ which: DockModel.Hover, _ symbol: String, _ name: String, _ action: @escaping () -> Void) -> some View {
        let hovered = model.hover == which
        return VStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(hovered ? 0.14 : 0.05))
                .overlay(Image(systemName: symbol).font(.system(size: 19, weight: .medium)).foregroundStyle(.white.opacity(hovered ? 0.95 : 0.7)))
                .frame(width: tileSize, height: tileSize)
            Color.clear.frame(width: 18, height: 15)
        }
        .scaleEffect(hovered ? 1.06 : 1, anchor: .bottom)
        .animation(.spring(response: 0.25, dampingFraction: 0.72), value: hovered)
        .contentShape(Rectangle())
        .onHover { model.setHover(which, $0) }
        .onTapGesture(perform: action)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}

/// One window in the dock's window strip: its title, two lines at most, numbered in order.
private struct StripCard: View {
    let title: String
    let index: Int
    let tint: Color
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Text("\(index)").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(.white)
                .frame(width: 16, height: 16).background(Circle().fill(tint.opacity(hovered ? 1 : 0.7)))
            Text(title.isEmpty ? "Untitled window" : title)
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(hovered ? 1 : 0.8))
                .lineLimit(2).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(8)
        .frame(width: 168, height: 50, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovered ? tint.opacity(0.3) : Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(hovered ? tint : Color.white.opacity(0.08)))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: action)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title.isEmpty ? "Untitled window" : title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}
