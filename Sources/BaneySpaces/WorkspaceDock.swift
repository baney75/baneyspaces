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
    var onTurnOff: () -> Void = {}
    private let model = DockModel()
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
        model.onShowOverview = { [weak self] in self?.hide(); self?.onShowOverview() }
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
        model.hovered = nil
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
        let name: String
        let icon: NSImage
        let windows: Int
    }
    struct Tile: Identifiable {
        let id: Int
        let apps: [App]
        let isCurrent: Bool
        var windowCount: Int { apps.reduce(0) { $0 + $1.windows } }
    }

    @Published var tiles: [Tile] = []
    @Published var hovered: Int?
    var menuOpen = false
    var onPick: (Int) -> Void = { _ in }
    var onSendHere: (Int) -> Void = { _ in }
    var onShowOverview: () -> Void = {}
    var onTurnOff: () -> Void = {}

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
            Tile(id: t.workspace, apps: t.apps.map { a in
                let pid = pid_t(a.key) ?? 0
                return App(id: a.key, name: byPid[a.key]?.app ?? "App",
                           icon: NSRunningApplication(processIdentifier: pid)?.icon ?? NSWorkspace.shared.icon(for: .application),
                           windows: a.windows)
            }, isCurrent: t.isCurrent)
        }
    }
}

private struct DockView: View {
    @ObservedObject var model: DockModel
    private let accent = Color(red: 0.91, green: 0.26, blue: 0.29)

    var body: some View {
        VStack(spacing: 6) {
            // Room above the tiles for the hovered tile's name; clicks pass through it.
            label.frame(height: 26)
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(model.tiles) { tile in tileButton(tile) }
                Rectangle().fill(Color.white.opacity(0.18)).frame(width: 1, height: 40).padding(.horizontal, 2)
                overviewButton
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .background(
                // Material for depth, a dark wash so busy windows behind don't show through.
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.regularMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.black.opacity(0.45)))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            )
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 2)
        // Wide enough for a long workspace name above a short dock.
        .frame(minWidth: 480)
        .fixedSize()
    }

    @ViewBuilder private var label: some View {
        if let n = model.hovered, let tile = model.tiles.first(where: { $0.id == n }) {
            Text(title(tile))
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.75)))
                .foregroundStyle(.white)
                .transition(.opacity)
        } else if model.hovered == 0 {
            Text("Show All Workspaces")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.75)))
                .foregroundStyle(.white)
        } else {
            Color.clear.frame(width: 1)
        }
    }

    private func title(_ tile: DockModel.Tile) -> String {
        guard !tile.apps.isEmpty else { return "Workspace \(tile.id) · empty" }
        let apps = tile.apps.map { $0.windows > 1 ? "\($0.name) (\($0.windows))" : $0.name }
        return "Workspace \(tile.id) · \(apps.joined(separator: ", "))"
    }

    private func tileButton(_ tile: DockModel.Tile) -> some View {
        let hovered = model.hovered == tile.id
        return VStack(spacing: 5) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(hovered ? 0.16 : 0.08))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(tile.isCurrent ? accent : Color.white.opacity(0.1), lineWidth: tile.isCurrent ? 2 : 1))
                icons(tile).frame(width: 56, height: 56)
                Text("\(tile.id)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(minWidth: 17, minHeight: 17)
                    .background(Circle().fill(tile.isCurrent ? accent : Color.black.opacity(0.7)))
                    .offset(x: -4, y: 4)
            }
            .frame(width: 56, height: 56)
            Circle().fill(tile.isCurrent ? accent : Color.clear).frame(width: 4, height: 4)
        }
        .scaleEffect(hovered ? 1.12 : 1, anchor: .bottom)
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: hovered)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { model.hovered = tile.id } else if model.hovered == tile.id { model.hovered = nil }
        }
        .onTapGesture { model.onPick(tile.id) }
        .contextMenu {
            Button("Go to Workspace \(tile.id)") { model.onPick(tile.id) }
            Button("Send Front Window to Workspace \(tile.id)") { model.onSendHere(tile.id) }
            Divider()
            Button("Show All Workspaces") { model.onShowOverview() }
            Button("Turn Off Workspace Dock") { model.onTurnOff() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title(tile) + (tile.isCurrent ? ", current" : ""))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.onPick(tile.id) }
    }

    /// One app fills the tile; up to four share it; more show three and a count.
    @ViewBuilder private func icons(_ tile: DockModel.Tile) -> some View {
        let apps = tile.apps
        if apps.isEmpty {
            Image(systemName: "plus").font(.system(size: 16, weight: .medium)).foregroundStyle(.white.opacity(0.35))
        } else if apps.count == 1 {
            Image(nsImage: apps[0].icon).resizable().frame(width: 40, height: 40)
        } else {
            let shown = apps.count > 4 ? Array(apps.prefix(3)) : apps
            LazyVGrid(columns: [GridItem(.fixed(22), spacing: 3), GridItem(.fixed(22), spacing: 3)], spacing: 3) {
                ForEach(shown) { app in Image(nsImage: app.icon).resizable().frame(width: 22, height: 22) }
                if apps.count > 4 {
                    Text("+\(apps.count - 3)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.8)).frame(width: 22, height: 22)
                }
            }
            .frame(width: 47)
        }
    }

    private var overviewButton: some View {
        let hovered = model.hovered == 0
        return VStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(hovered ? 0.16 : 0.06))
                .overlay(Image(systemName: "square.grid.3x3.fill").font(.system(size: 20)).foregroundStyle(.white.opacity(0.8)))
                .frame(width: 56, height: 56)
            Color.clear.frame(width: 4, height: 4)
        }
        .scaleEffect(hovered ? 1.12 : 1, anchor: .bottom)
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: hovered)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { model.hovered = 0 } else if model.hovered == 0 { model.hovered = nil }
        }
        .onTapGesture { model.onShowOverview() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Show All Workspaces")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.onShowOverview() }
    }
}
