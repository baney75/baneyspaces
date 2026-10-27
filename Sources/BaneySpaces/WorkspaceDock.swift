import AppKit
import BaneySpacesCore
import SwiftUI
import UniformTypeIdentifiers

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

    /// Which side of the screen it lives on. Bottom unless chosen.
    static var edge: DockEdge {
        get { DockEdge(rawValue: UserDefaults.standard.string(forKey: "dockEdge") ?? "") ?? .bottom }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "dockEdge") }
    }

    /// Badges for coding agents on app icons and tiles. On unless turned off; off, the dock
    /// shows apps only and a click on one never detours to an agent.
    static var agentStatus: Bool {
        get { UserDefaults.standard.object(forKey: "dockAgentStatus") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "dockAgentStatus") }
    }

    /// Other apps' windows at the pop-up menu level, in AppKit's coordinates.
    static func menuLevelWindows() -> [(id: Int, frame: CGRect)] {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return MenuWindows.parse(windows, level: Int(CGWindowLevelForKey(.popUpMenuWindow)), ownPID: getpid(),
                                 primaryHeight: NSScreen.screens.first?.frame.height ?? 0)
    }

    /// Moves it to another side; it comes up there the next time the pointer rests on that edge.
    func setEdge(_ e: DockEdge) {
        WorkspaceDock.edge = e
        let screen = shownOn ?? NSScreen.main
        hide(animated: false)
        needsRearm = false
        edgeSince = nil
        spanLength = nil
        model.edge = e
        // Shown by a script, it stays shown, now on its new side.
        if pinned, let screen { show(on: screen) }
    }

    private let spaces: Spaces
    var onShowOverview: () -> Void = {}
    var onShowLauncher: () -> Void = {}
    var onTurnOff: () -> Void = {}
    /// Picking a side from a tile's menu; the app delegate keeps setup and the menu in step.
    var onSetEdge: (DockEdge) -> Void = { _ in }
    /// Turning agent badges on or off from a tile's menu; the app delegate keeps setup in step.
    var onSetAgentStatus: (Bool) -> Void = { _ in }
    let model = DockModel()
    private var panel: DockPanel?
    private var timer: Timer?
    private var edgeSince: Date?
    private var awaySince: Date?
    private var buttonsUpSince: Date?
    private(set) var isRunning = false
    private(set) var isShown = false
    /// Shown by a script or a test, not the pointer: it stays until hidden the same way.
    private var pinned = false
    /// Hidden because the pointer moved away while still on the bottom edge: it comes back only
    /// after the pointer leaves the edge, so a pointer parked there can't make it bob up and down.
    private var needsRearm = false
    /// The screen whose edge that was; another screen's edge is fresh.
    private var rearmScreen: NSScreen?
    /// A file, link or image being dragged from another app: the dock comes up for it.
    private var outsideDrag = OutsideDrag()
    /// Resting that drag on an icon or tile brings its window or workspace forward.
    private var spring = SpringLoad()
    /// How long other apps' menu-level windows have been up: an old one isn't a menu.
    private var menuWindows = MenuWindows()
    private var menusSeenAt: TimeInterval = 0

    init(spaces: Spaces) {
        self.spaces = spaces
        model.onPick = { [weak self] n in self?.spaces.switchTo(n, announce: false) }
        model.onSendHere = { [weak self] n in self?.spaces.moveFocused(to: n) }
        model.onFocusApp = { [weak self] pid, n in self?.spaces.focusApp(pid, on: n, cycle: true) }
        model.onFocusWindow = { [weak self] id, n in self?.spaces.focus(id, on: n) }
        model.onMove = { [weak self] ids, n in self?.spaces.move(ids, to: n) }
        // Reloads wait out a drag; one that moved nothing catches up here.
        model.onDragDone = { [weak self] in self?.reload() }
        // After SwiftUI has laid out the strip, so the new size is the real one.
        model.onLayoutChange = { [weak self] in DispatchQueue.main.async { self?.resize() } }
        model.onShowOverview = { [weak self] in self?.hide(); self?.onShowOverview() }
        model.onShowLauncher = { [weak self] in self?.hide(); self?.onShowLauncher() }
        model.onTurnOff = { [weak self] in self?.onTurnOff() }
        model.onSetEdge = { [weak self] e in self?.onSetEdge(e) }
        model.onSetAgentStatus = { [weak self] on in self?.onSetAgentStatus(on) }
        model.onOpenFiles = { [weak self] urls, pid, n in self?.open(urls, with: pid, on: n) }
        model.openable = { [weak self] pid in self?.openable(by: pid) ?? [] }
        model.liveCurrent = { [weak self] in self?.spaces.model.current ?? 0 }
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
        // Mid-switch the windows are on the move; the switch's end calls this again. A drag in
        // progress keeps its tiles; a reload could pull the dragged icon out from under it. One
        // from another app too: tiles shifting under a held file would spring the one beside it.
        // Either drag's end reloads.
        guard isShown, !spaces.switching, model.drag == nil else { return }
        // The tiles hold still, but the "you're here" highlight and label read the live workspace.
        guard model.fileDrag == nil else { model.objectWillChange.send(); return }
        model.load(from: spaces)
        resize()
    }

    // MARK: Showing and hiding

    private func tick() {
        guard isRunning else { return }
        // A pinned dock takes drags from other apps too, though it doesn't come and go.
        let carrying = outsideDrag.update(buttonsDown: NSEvent.pressedMouseButtons != 0) { NSPasteboard(name: .drag).changeCount }
        // A drag that ended without leaving the dock or dropping (Escape) is over too.
        if !carrying, model.fileDrag != nil { model.fileDrag = nil }
        springLoad(carrying)
        guard !pinned else { return }
        // Once a second, so a menu window's age is known before the pointer reaches the edge.
        let uptime = ProcessInfo.processInfo.systemUptime
        if uptime - menusSeenAt > 1 {
            menusSeenAt = uptime
            menuWindows.update(WorkspaceDock.menuLevelWindows(), now: uptime)
        }
        // The overview already shows every workspace; the dock stays down while it's open.
        if MissionControlKeys.viewerOpen { if isShown { hide() }; edgeSince = nil; return }
        let mouse = NSEvent.mouseLocation
        // A drag whose mouse-up never reached the dock (the screen locked, another app took the
        // pointer) would hold it open forever; once the button has been up a moment, it's over.
        if model.drag != nil, NSEvent.pressedMouseButtons == 0 {
            if buttonsUpSince == nil { buttonsUpSince = Date() }
            if Date().timeIntervalSince(buttonsUpSince!) > 0.3 { model.cancelDrag() }
        } else {
            buttonsUpSince = nil
        }
        if isShown {
            guard let p = panel else { return }
            // Hovering the dock or the edge below it keeps it up; a menu open from it too, and a
            // drag that strays off it on the way to a tile.
            let screenFrame = (shownOn ?? p.screen)?.frame ?? p.frame
            // A window carried down from another app has the pointer itself: off the dock, it's not for it.
            let keep = WorkspaceDock.edge.keepZone(dock: p.frame, screen: screenFrame).contains(mouse) || model.menuOpen
                || (model.drag != nil && model.drag?.carried == false)
            if keep { awaySince = nil; return }
            if awaySince == nil { awaySince = Date() }
            if Date().timeIntervalSince(awaySince!) > 0.4 {
                rearmScreen = p.screen
                hide()
                needsRearm = true
            }
            return
        }
        // Resting on the dock's edge, buttons up (not dragging a selection) unless carrying
        // something from another app to drop, or a window by its title bar, on an edge with no
        // other screen beyond it, as the macOS Dock uses.
        let edge = WorkspaceDock.edge
        let screens = NSScreen.screens
        let screen = edge.screen(at: mouse, among: screens.map(\.frame)).map { screens[$0] }
        guard let screen, NSEvent.pressedMouseButtons == 0 || carrying || windowCarry != nil && carryRefused == nil else { edgeSince = nil; needsRearm = false; return }
        if needsRearm, screen == rearmScreen { edgeSince = nil; return }
        needsRearm = false
        // Only along the dock itself; the corners and the rest of the edge stay free.
        let length = spanLength ?? 560
        guard edge.withinSpan(mouse, screen: screen.frame, visible: screen.visibleFrame, length: length) else { edgeSince = nil; return }
        if edgeSince == nil { edgeSince = Date() }
        guard Date().timeIntervalSince(edgeSince!) > edge.dwell else { return }
        // A menu open in another app (a menu bar title, a status item) is what the pointer is
        // there for; the dock waits until it closes.
        let fresh = menuWindows.update(WorkspaceDock.menuLevelWindows(), now: ProcessInfo.processInfo.systemUptime)
        if DockEdge.menuInTheWay(fresh, pointer: mouse) { return }
        show(on: screen)
        if let g = windowCarry?.grab { carryMoved(g) }
    }

    // MARK: A window dragged down to the dock

    /// The window being dragged by its title bar, while the pointer could take it to the dock:
    /// only one on a workspace, looked up once per drag.
    private var windowCarry: (grab: TopDrag.Grab, entry: Spaces.Entry, from: Int)?
    /// A window dragged this time that isn't on a workspace: not asked about again until it's let go.
    private var carryRefused: WindowID?
    private var carryTarget: Int?
    /// The dock came up for the carried window, so it goes down when that drag ends.
    private var shownForCarry = false

    /// Another app's window follows the pointer. The dock comes up when the pointer rests on its
    /// edge (the tick watches for that), and then the tile under the pointer lights.
    func carryMoved(_ grab: TopDrag.Grab) {
        guard isRunning, DockCarry.accepts(WorkspaceDock.edge), !MissionControlKeys.viewerOpen,
              carryRefused != grab.window else { return }
        // A file dragged out of the window, or a switch that parked it (one a spring started for
        // that file): the window "moved" without being carried. Not for the dock, all this press.
        if outsideDrag.active || model.fileDrag != nil || spaces.switching {
            carryRefused = grab.window
            if let d = model.drag, d.carried { model.drag = nil }
            // A file drag keeps the dock it's using.
            shownForCarry = false
            windowCarry = nil
            return
        }
        if windowCarry?.grab.window != grab.window {
            guard let (entry, from) = spaces.entry(for: grab.window) else { carryRefused = grab.window; return }
            windowCarry = (grab, entry, from)
            carryTarget = nil
        }
        // Sliding in, the panel isn't where it will be and the tiles may not have reported where
        // they are: nothing is lit, and a let-go then moves nothing.
        guard let carry = windowCarry, isShown, model.shown, !slidingIn, let p = panel else { return }
        let location = DockCarry.point(NSEvent.mouseLocation, panel: p.frame, origin: model.origin)
        if var d = model.drag, d.carried, d.ids == [grab.window] {
            d.location = location
            model.drag = d
        } else {
            guard model.drag == nil else { return }
            shownForCarry = true
            let e = carry.entry
            let icon = NSRunningApplication(processIdentifier: e.pid)?.icon ?? NSWorkspace.shared.icon(for: .application)
            let title = WindowTitle.clean(e.title, app: e.app)
            model.drag = DockModel.Drag(ids: [grab.window], from: carry.from, icon: icon, name: title.isEmpty ? e.app : "“\(title)”",
                                        location: location, carried: true)
            Trace.log("dockCarry show window=\(grab.window) from=\(carry.from)")
        }
        // Each change, so trace.log (and scripts/dock-drag-probe.swift) shows what's lit.
        let target = model.dropTarget
        if target != carryTarget { Trace.log("dockCarry target=\(target.map(String.init) ?? "none")") }
        carryTarget = target
    }

    /// The drag ended. Let go at `p` (window-server space) over another workspace's tile: that
    /// workspace, for the window to go to. The dock goes down either way.
    func endCarry(_ grab: TopDrag.Grab, at p: CGPoint?) -> Int? {
        windowCarry = nil
        carryRefused = nil
        let wasShown = shownForCarry
        shownForCarry = false
        var target: Int?
        if let d = model.drag, d.carried, d.ids == [grab.window] {
            if let p, let panel, !slidingIn, let mainHeight = NSScreen.screens.first?.frame.maxY {
                var last = d
                last.location = DockCarry.point(CGPoint(x: p.x, y: mainHeight - p.y), panel: panel.frame, origin: model.origin)
                model.drag = last
                target = model.dropTarget
            }
            model.drag = nil
            Trace.log("dockCarry release target=\(target.map(String.init) ?? "none")")
        }
        guard wasShown, isShown else { return target }
        if pinned {
            // A pinned dock stays up; it catches up on what changed while its tiles held still.
            model.onDragDone()
        } else {
            // The pointer is still on the edge; it has to leave it before the dock comes again.
            rearmScreen = panel?.screen
            needsRearm = true
            hide()
        }
        return target
    }

    /// A drag from another app held on an icon or a tile for a moment brings that app's window
    /// or that workspace forward, so the drop can go into a window there. The dock stays up
    /// until the pointer leaves it for the window.
    private func springLoad(_ carrying: Bool) {
        guard carrying, isShown, let drag = model.fileDrag else { spring.reset(); return }
        guard let fire = spring.update(drag.target) else { return }
        Trace.log("dock spring \(fire)")
        // The tiles hold still mid-drag; their "you're here" highlight follows the switch.
        defer { model.objectWillChange.send() }
        switch fire {
        case .app(let n, let id):
            guard let pid = pid_t(id) else { return }
            spaces.focusApp(pid, on: n, announce: false)
        case .tile(let n):
            if n != spaces.model.current { spaces.switchTo(n, announce: false) }
        }
    }

    /// Files or links dropped on an app's icon open in that app on that icon's workspace: you go
    /// there first, so the window they open in is the one in front of you.
    private func open(_ urls: [URL], with pid: pid_t, on n: Int) {
        guard let app = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return }
        let openThem = {
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { Trace.log("dock drop: \(app.lastPathComponent) didn't open \(urls.count) item(s): \(error.localizedDescription)") }
            }
        }
        // Here too: the app's window on this workspace comes forward, so a browser puts the
        // link in that window, not in one parked on another workspace.
        spaces.focusApp(pid, on: n, announce: false)
        // A switch runs over a few turns of the run loop (one a spring started may still be, and
        // a window leaving full screen takes its animation); open once it's done. The cap is only
        // for a switch that never ends, and says so. In the common modes, so an open menu
        // doesn't hold it up.
        let deadline = Date().addingTimeInterval(4)
        let t = Timer(timeInterval: 0.02, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let late = Date() > deadline
            guard !self.spaces.switching || late else { return }
            t.invalidate()
            if late { Trace.log("dock drop: switch to \(n) still running after 4 s; opening anyway") }
            openThem()
        }
        RunLoop.main.add(t, forMode: .common)
    }

    /// The files and links being dragged that this app can open, or none unless it can open them
    /// all. Asked on every move over an icon, so it's kept per drag and app.
    private func openable(by pid: pid_t) -> [URL] {
        let board = NSPasteboard(name: .drag)
        if openableCache?.drag != board.changeCount {
            let urls = board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
            let apps = DockOpen.apps(openingAll: urls, kind: { url in
                url.isFileURL ? ((try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.identifier ?? DockOpen.kind(url)) : DockOpen.kind(url)
            }, handlers: { NSWorkspace.shared.urlsForApplications(toOpen: $0) }, identify: { Bundle(url: $0)?.bundleIdentifier })
            openableCache = (board.changeCount, urls, apps)
        }
        guard let cache = openableCache, let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
              cache.apps.contains(id) else { return [] }
        return cache.urls
    }
    /// One drag's files and links, and the bundle identifiers of the apps that can open them all.
    private var openableCache: (drag: Int, urls: [URL], apps: Set<String>)?

    /// `baneyspaces://dock/show`: for scripts and checks. It stays until `dock/hide`.
    func pin(_ on: Bool) {
        guard isRunning else { return }
        pinned = on
        if on { show(on: NSScreen.main ?? NSScreen.screens[0]) } else { hide() }
    }

    private func show(on screen: NSScreen, retried: Bool = false) {
        edgeSince = nil
        awaySince = nil
        model.reset()
        model.shown = true
        let edge = WorkspaceDock.edge
        model.maxLength = (edge.isVertical ? screen.visibleFrame.height : screen.frame.width) - 32
        model.load(from: spaces)
        let p = panel ?? makePanel()
        panel = p
        isShown = true
        p.contentView?.layoutSubtreeIfNeeded()
        let size = p.contentView?.fittingSize ?? .zero
        let up = edge.frame(size: size, screen: screen.frame, visible: screen.visibleFrame)
        shownOn = screen
        spanLength = edge.isVertical ? size.height : size.width
        p.setFrame(up.offsetBy(dx: edge.away.dx, dy: edge.away.dy), display: false)
        slidingIn = true
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().setFrame(up, display: true)
            p.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            self?.slidingIn = false
            // The first layout may not have measured itself yet (a dock shrunk to fit settles a
            // pass later); size to what it really is now.
            self?.resize()
        })
        // After hours up, the panel has been seen to stay off screen though it was ordered in
        // front. If the window server doesn't have it on screen, build a new one, once.
        guard !retried else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.isShown, self.panel === p, !p.isOnScreenNow,
                  // A full-screen Space (no menu bar on that display) keeps the dock off on purpose.
                  screen.visibleFrame != screen.frame, !Windows.frontIsFullScreen() else { return }
            Trace.log("dock panel not on screen; rebuilding it")
            p.orderOut(nil)
            self.panel = nil
            self.isShown = false
            self.show(on: screen, retried: true)
        }
    }

    func hide(animated: Bool = true) {
        guard isShown, let p = panel else { return }
        isShown = false
        model.reset()
        let away = WorkspaceDock.edge.away
        let down = p.frame.offsetBy(dx: away.dx, dy: away.dy)
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

    /// Tiles come and go as workspaces fill and empty; the dock stays centered on its edge.
    /// The tiles are centered in the panel (or pinned to its edge side), so growing the panel
    /// for the window strip never moves them out from under the pointer.
    private func resize() {
        guard isShown, let p = panel, let screen = shownOn ?? p.screen ?? NSScreen.main else { return }
        let size = p.contentView?.fittingSize ?? p.frame.size
        guard size != p.frame.size else { return }
        p.setFrame(WorkspaceDock.edge.frame(size: size, screen: screen.frame, visible: screen.visibleFrame), display: true)
        spanLength = WorkspaceDock.edge.isVertical ? size.height : size.width
    }

    /// The screen it came up on, so a resize keeps it there.
    private var shownOn: NSScreen?
    /// How far it reaches along its edge when last shown, for the stretch of edge that opens it.
    /// Forgotten when it moves to another edge, where that length means nothing.
    private var spanLength: CGFloat?

    private func makePanel() -> DockPanel {
        let p = DockPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        // The window list's full titles show on hover though BaneySpaces is never the active app.
        p.allowsToolTipsWhenApplicationIsInactive = true
        // Not over full-screen apps: a video's controls or a game sit along that edge.
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let host = FirstClickHostingView(rootView: DockView(model: model).environment(\.colorScheme, .dark))
        // The dock sizes and places its own panel (resize). Left to SwiftUI, the window's min and
        // max size were also set from inside a layout pass, which re-framed the window mid-pass;
        // while the label and strip measured themselves, AppKit ran out of passes and threw
        // (two crashes, 2026-10-14). SwiftUI now only reports its size, and the dock follows it.
        host.sizingOptions = [.intrinsicContentSize]
        host.onSizeChange = { [weak self] in self?.scheduleResize() }
        p.contentView = host
        return p
    }

    private var resizeQueued = false
    /// The slide-in animation would overwrite a resize mid-way; its completion resizes instead.
    private var slidingIn = false
    /// One resize on the next turn of the run loop, outside the layout pass that changed the size.
    private func scheduleResize() {
        guard !resizeQueued, !slidingIn else { return }
        resizeQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.resizeQueued = false
            self?.resize()
        }
    }
}

/// Never takes the keyboard: clicking a tile leaves your app in front.
final class DockPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A click on a dock tile acts at once, without first bringing BaneySpaces forward.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    /// SwiftUI's size for the dock changed.
    var onSizeChange: () -> Void = {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onSizeChange()
    }
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
        /// A coding agent in one of those windows: the one that needs you most.
        var agent: DockAgent?
    }
    struct Window: Identifiable {
        let id: WindowID
        let title: String
        /// The window used last on its workspace: where a plain click on the app goes.
        var isLast = false
        /// The agent in this window, whatever it's doing.
        var agent: DockAgent?
    }
    struct Tile: Identifiable {
        let id: Int
        let apps: [App]
        let isCurrent: Bool
        /// Coding agents on this workspace that are working, and that finished without you looking.
        var agents: [DockAgent] = []
        /// Those whose window isn't one of this tile's (not known yet): the tile's corner shows them.
        var unpinned: [DockAgent] = []
        var agentsWorking: Int { agents.filter { $0.state == .working }.count }
        var agentsDone: Int { agents.filter { $0.state == .done }.count }
        var windowCount: Int { apps.reduce(0) { $0 + $1.windows } }
    }
    /// An app's windows on one workspace, or one window from the strip, being dragged to another
    /// workspace. `location` is the pointer in the dock's own space.
    struct Drag {
        let ids: [WindowID]
        let from: Int
        let icon: NSImage
        /// What moves, for the label: an app's name or a window's title.
        let name: String
        var location: CGPoint
        /// Another app's window dragged by its title bar down to the dock: the window itself
        /// follows the pointer, so no icon does.
        var carried = false
    }
    /// Something from another app dragged over the dock: what it rests on, and whether it holds
    /// files or links an app can open.
    struct FileDrag: Equatable {
        var target: DockSpringTarget?
        var canOpen: Bool
    }
    /// What the pointer rests on: a whole tile, one app in a tile, or a button.
    enum Hover: Equatable {
        case tile(Int)
        case app(Int, String)
        case newWorkspace, launcher, overview
        /// The "+N" in a tile with more apps than fit.
        case more(Int)
    }

    @Published var tiles: [Tile] = []
    @Published var edge = WorkspaceDock.edge
    /// The longest the tiles can run along the edge on this screen; a longer dock shrinks to fit.
    @Published var maxLength: CGFloat = .infinity
    var onSetEdge: (DockEdge) -> Void = { _ in }
    @Published var agentStatus = WorkspaceDock.agentStatus
    var onSetAgentStatus: (Bool) -> Void = { _ in }
    @Published var hover: Hover? {
        didSet {
            hoverChanged()
            // A side dock's label column grows and shrinks with what's hovered.
            if edge.isVertical, (hover == nil) != (oldValue == nil) || hover != oldValue { onLayoutChange() }
        }
    }
    /// The window strip: an app's windows on one workspace, opened by resting on its icon.
    @Published var strip: (workspace: Int, app: String)? {
        didSet {
            // Removed from under the pointer, it never hears the pointer leave.
            if strip == nil, more == nil { onStrip = false }
            if strip != nil { more = nil }
            if (strip == nil) != (oldValue == nil) || strip?.app != oldValue?.app { onLayoutChange() }
        }
    }
    /// The apps a tile had no room for, listed over it: opened by resting on its "+N".
    @Published var more: Int? {
        didSet {
            if strip == nil, more == nil { onStrip = false }
            if more != nil, strip != nil { strip = nil }
            if more != oldValue { onLayoutChange() }
        }
    }

    /// The apps a tile shows as "+N", and its tile.
    var moreApps: (tile: Tile, apps: [App])? {
        guard let n = more, let t = tiles.first(where: { $0.id == n }), t.apps.count > DockModel.iconsShown + 1 else { return nil }
        return (t, Array(t.apps.dropFirst(DockModel.iconsShown)))
    }

    /// A tile shows up to four icons; past that, three and a "+N".
    static let iconsShown = 3
    @Published var drag: Drag?
    @Published var fileDrag: FileDrag? {
        didSet {
            guard fileDrag != oldValue else { return }
            // Its end catches up on what changed while the tiles held still: after the drag
            // callback that ended it returns, so a window scan never holds up the drop.
            if fileDrag == nil { DispatchQueue.main.async { [weak self] in self?.onDragDone() } }
            // During a drag the pointer's hover isn't reported; the drag's target lights up instead.
            switch fileDrag?.target {
            case .app(let n, let id): hover = .app(n, id)
            case .tile(let n): hover = .tile(n)
            case nil: if oldValue?.target != nil { hover = nil }
            }
        }
    }
    /// Each tile's and button's frame in the dock, keyed as `CenterReport` reports them, to find
    /// the tile under a drag.
    var frames: [String: CGRect] = [:]
    /// Where the space those frames are in starts, from the panel's top left.
    var origin: CGPoint = .zero
    /// When the last drag ended: the click that ends a drag isn't also a click on the icon.
    private var dragEnded = Date.distantPast
    /// Up on screen; a dwell that ends after the dock hid opens nothing.
    var shown = false
    /// The pointer is on the strip itself, which keeps it open.
    var onStrip = false
    private var dwell: DispatchWorkItem?
    var onFocusWindow: (WindowID, Int) -> Void = { _, _ in }
    var onLayoutChange: () -> Void = {}
    var menuOpen = false
    var onPick: (Int) -> Void = { _ in }
    /// The Deck's agents that are working or finished unseen, on every workspace.
    var agents: () -> [DockAgent] = { [] }
    var onFocusApp: (pid_t, Int) -> Void = { _, _ in }
    /// An agent's own tab or window, through the Deck, which also marks a finished one seen.
    var onFocusAgent: (DockAgent, Int) -> Void = { _, _ in }
    var onSendHere: (Int) -> Void = { _ in }
    var onMove: ([WindowID], Int) -> Void = { _, _ in }
    var onDragDone: () -> Void = {}
    /// Files or links dropped on an app's icon: that app opens them on the icon's workspace.
    var onOpenFiles: ([URL], pid_t, Int) -> Void = { _, _, _ in }
    /// What of the drag an app can open: everything, or nothing.
    var openable: (pid_t) -> [URL] = { _ in [] }
    /// The workspace you're on now. During a drag the tiles hold still, so theirs can be old.
    var liveCurrent: () -> Int = { 0 }
    /// The icon or tile the drag was last over, as lit and labeled. The drop goes there, even
    /// if the tiles moved after the button came up.
    var heldTarget: DockSpringTarget?
    var onShowOverview: () -> Void = {}
    var onShowLauncher: () -> Void = {}
    var onTurnOff: () -> Void = {}

    /// The first workspace with nothing on it, for the "new workspace" button.
    var firstEmpty: Int? { Workspaces.range.first { n in !tiles.contains { $0.id == n && !$0.apps.isEmpty } } }

    func load(from spaces: Spaces) {
        spaces.refresh()
        var byPid: [String: Spaces.Entry] = [:]
        var entries: [Int: [Spaces.Entry]] = [:]
        for n in Workspaces.range {
            entries[n] = spaces.entries(on: n)
            for e in entries[n]! { byPid["\(e.pid)"] = e }
        }
        let current = spaces.model.current
        // Each agent sits on the tile that holds its window, so its badge marks the app it runs in.
        let placed = !agentStatus ? [:] : DockTiles.place(agents(), windows: entries.mapValues { $0.map(\.id) }, current: current)
        let last = spaces.model.lastFocused
        tiles = DockTiles.make(current: current, windows: entries.mapValues { $0.map { "\($0.pid)" } }).map { t in
            let here = entries[t.workspace] ?? []
            let agents = placed[t.workspace] ?? []
            // The one that needs you most wins: asking, then an error, then finished, then working.
            let byWindow = Dictionary(agents.map { ($0.window, $0) }) { a, b in a.state.urgency >= b.state.urgency ? a : b }
            var apps = t.apps.map { a in
                let pid = pid_t(a.key) ?? 0
                let list = here.filter { "\($0.pid)" == a.key }.map {
                    Window(id: $0.id, title: WindowTitle.clean($0.title, app: $0.app), isLast: $0.id == last[t.workspace], agent: byWindow[$0.id])
                }
                return App(id: a.key, pid: pid, name: byPid[a.key]?.app ?? "App",
                           icon: NSRunningApplication(processIdentifier: pid)?.icon ?? NSWorkspace.shared.icon(for: .application),
                           windows: a.windows, list: list,
                           agent: list.compactMap(\.agent).max { $0.state.urgency < $1.state.urgency })
            }
            var order = DockTiles.agentsInView(apps.map(\.id), flagged: Set(apps.filter { $0.agent != nil }.map(\.id)), shown: DockModel.iconsShown)
            // Under the pointer, icons hold still: an agent starting elsewhere mustn't swap
            // another app into the slot you're about to click.
            if hoveredTile == t.workspace, let before = tiles.first(where: { $0.id == t.workspace })?.apps.map(\.id),
               Set(before) == Set(order) { order = before }
            apps.sort { order.firstIndex(of: $0.id)! < order.firstIndex(of: $1.id)! }
            var tile = Tile(id: t.workspace, apps: apps, isCurrent: t.isCurrent)
            tile.agents = agents
            let windows = Set(here.map(\.id))
            tile.unpinned = agents.filter { !windows.contains($0.window) }
            return tile
        }
        // A strip for an app that's gone or down to one window closes.
        if let s = strip, (stripApp?.list.count ?? 0) < 2 || !tiles.contains(where: { $0.id == s.workspace }) { strip = nil }
        if more != nil, moreApps == nil { more = nil }
    }

    /// The tile the pointer is on, by itself or one of its icons.
    private var hoveredTile: Int? {
        switch hover {
        case .tile(let n), .app(let n, _), .more(let n): return n
        default: return nil
        }
    }

    var stripApp: App? {
        guard let s = strip else { return nil }
        return tiles.first { $0.id == s.workspace }?.apps.first { $0.id == s.app }
    }

    /// Resting on an app with more than one window here opens its strip after a moment. Moving
    /// to another app or button closes it; drifting up to the strip, or across its own tile, doesn't.
    private func hoverChanged() {
        dwell?.cancel()
        // Mid-drag the strip stays as it was: it may hold the row being dragged. A drag from
        // another app opens the app itself, not its strip.
        if drag != nil || fileDrag != nil { return }
        switch hover {
        case .app(let n, let id):
            if let s = strip, s.workspace == n, s.app == id { return }
            // Crossing another icon in the same tile on the way up to the strip keeps it; resting
            // there opens that app's strip instead. Another tile's app closes it.
            if let s = strip, s.workspace != n, !onStrip { strip = nil }
            if let m = more, m != n, !onStrip { more = nil }
            guard let app = tiles.first(where: { $0.id == n })?.apps.first(where: { $0.id == id }), app.list.count > 1 else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.shown, self.hover == .app(n, id) else { return }
                self.strip = (n, id)
            }
            dwell = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        case .newWorkspace, .launcher, .overview:
            if !onStrip { strip = nil; more = nil }
        case .tile(let n):
            if let s = strip, s.workspace != n, !onStrip { strip = nil }
            if let m = more, m != n, !onStrip { more = nil }
        case .more(let n):
            if more == n { return }
            if !onStrip { strip = nil }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.shown, self.hover == .more(n) else { return }
                self.more = n
            }
            dwell = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        case nil:
            break
        }
    }

    /// The workspace a drag would land on, if any.
    var dropTarget: Int? {
        guard let drag else { return nil }
        var tiles: [Int: CGRect] = [:]
        for t in self.tiles { if let f = frames["tile:\(t.id)"] { tiles[t.id] = f } }
        let empty = firstEmpty.flatMap { n in frames["btn:new"].map { (workspace: n, frame: $0) } }
        return DockDrop.target(at: drag.location, from: drag.from, tiles: tiles, empty: empty)
    }

    func dragged(_ ids: [WindowID], from n: Int, icon: NSImage, name: String, to location: CGPoint) {
        // A gesture still tracking after the dock hid is dead; it starts nothing.
        guard shown else { return }
        if drag == nil {
            dwell?.cancel()
            NSCursor.closedHand.push()
        }
        drag = Drag(ids: ids, from: n, icon: icon, name: name, location: location)
    }

    /// Let go over another workspace's tile: the windows move there, and you stay where you are.
    func endDrag() {
        guard let drag, !drag.carried else { return }
        NSCursor.pop()
        let to = dropTarget
        self.drag = nil
        dragEnded = Date()
        if let to {
            // The strip came from the workspace they left; it closes rather than list them there.
            strip = nil
            onMove(drag.ids, to)
        } else {
            onDragDone()
        }
    }

    /// Ends a drag without moving anything.
    func cancelDrag() {
        guard let d = drag else { return }
        if !d.carried { NSCursor.pop() }
        drag = nil
        dragEnded = Date()
        onDragDone()
    }

    /// A click, unless it's the mouse-up that ends a drag.
    var clickCounts: Bool { drag == nil && Date().timeIntervalSince(dragEnded) > 0.3 }

    /// The dock went away.
    func reset() {
        if let drag, !drag.carried { NSCursor.pop() }
        drag = nil
        fileDrag = nil
        heldTarget = nil
        shown = false
        dwell?.cancel()
        hover = nil
        onStrip = false
        strip = nil
        more = nil
    }

    func setHover(_ h: Hover, _ inside: Bool) {
        if inside { hover = h } else if hover == h { hover = nil }
    }
}

private struct AppFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

/// Reports a view's frame in the dock's space under `key`, to line the label and strip up with
/// it and to find the tile under a drag.
private struct CenterReport: ViewModifier {
    let key: String
    func body(content: Content) -> some View {
        content.background(GeometryReader { g in
            Color.clear.preference(key: AppFrames.self, value: [key: g.frame(in: .named("dock"))])
        })
    }
}

/// Grows a tile, icon or button under the pointer with a spring, and animates nothing else. A plain
/// `.animation(_, value: hovered)` also animated the layout change that hover sets off in the same
/// update (the label above the dock widens it and re-centers the bar), so the tile under the pointer
/// slid sideways across its neighbors while the panel snapped into place (Donovan, 2026-10-19).
private struct HoverScale: ViewModifier {
    let scale: CGFloat
    var anchor: UnitPoint = .center
    let spring: Animation
    func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            content.animation(spring) { $0.scaleEffect(scale, anchor: anchor) }
        } else {
            // macOS 13 has no scoped animation, so the slide can still show there.
            content.scaleEffect(scale, anchor: anchor).animation(spring, value: scale)
        }
    }
}

private struct SizeReport: ViewModifier {
    @Binding var size: CGSize
    func body(content: Content) -> some View {
        content.background(GeometryReader { g in Color.clear.onAppear { size = g.size }.onChange(of: g.size) { size = $0 } })
    }
}

struct DockView: View {
    /// The key under which the stack reports its own frame in the panel. No colon, so no drop
    /// target reads it as a tile or an icon.
    static let originKey = "origin"
    @ObservedObject var model: DockModel
    private let tileSize: CGFloat = 64
    /// Where each tile, app icon and button sits in the dock, so the strip and label line up with it.
    @State private var frames: [String: CGRect] = [:]
    @State private var sideSize: CGSize = .zero
    @State private var barSize: CGSize = .zero
    @State private var stackSize: CGSize = .zero

    var body: some View {
        let edge = model.edge
        // The label or strip goes on the screen side of the tiles: above a bottom dock, beside a side one.
        let stack = edge.isVertical ? AnyLayout(HStackLayout(alignment: .center, spacing: 8)) : AnyLayout(VStackLayout(alignment: .center, spacing: 8))
        return stack {
            if edge == .bottom || edge == .right { side }
            fittedBar
            if edge == .top || edge == .left { side }
        }
        .modifier(SizeReport(size: $stackSize))
        // The icon being dragged follows the pointer.
        .overlay(alignment: .topLeading) {
            if let drag = model.drag, !drag.carried {
                Image(nsImage: drag.icon).resizable().interpolation(.high).frame(width: 36, height: 36)
                    .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
                    .position(drag.location)
                    .allowsHitTesting(false)
            }
        }
        // Where the "dock" space starts in the panel, to place a pointer the panel never hears.
        .background(GeometryReader { g in
            Color.clear.preference(key: AppFrames.self, value: [DockView.originKey: g.frame(in: .global)])
        })
        .coordinateSpace(name: "dock")
        // Files, links and images dragged from another app. Its location is in the stack's own
        // space, the one named "dock" that the frames are reported in.
        .onDrop(of: [.item], delegate: OutsideDrop(model: model))
        .onPreferenceChange(AppFrames.self) { f in
            frames = f
            model.frames = f
            if let o = f[DockView.originKey]?.origin { model.origin = o }
        }
        .padding(edge.isVertical ? .vertical : .horizontal, 16)
        .padding(edge == .bottom ? .bottom : edge == .top ? .top : edge == .left ? .leading : .trailing, 4)
        // Room for a long label beside a short dock.
        .frame(minWidth: edge.isVertical ? nil : 480, minHeight: edge.isVertical ? 300 : nil)
        .fixedSize()
    }

    /// The bar, shrunk evenly when all its tiles wouldn't fit along the screen's edge.
    /// How much the bar is shrunk to fit its edge (1 when it fits).
    private var barScale: CGFloat {
        let length = model.edge.isVertical ? barSize.height : barSize.width
        return length > 0 && model.maxLength.isFinite ? min(1, model.maxLength / length) : 1
    }

    @ViewBuilder private var fittedBar: some View {
        let scale = barScale
        if scale < 1 {
            bar.scaleEffect(scale).frame(width: barSize.width * scale, height: barSize.height * scale)
        } else {
            bar
        }
    }

    /// The tiles and buttons, in a row or, on a side, a column.
    private var bar: some View {
        let vertical = model.edge.isVertical
        let layout = vertical ? AnyLayout(VStackLayout(alignment: .center, spacing: 8)) : AnyLayout(HStackLayout(alignment: .bottom, spacing: 8))
        return layout {
            ForEach(model.tiles) { tile in tileView(tile) }
            if let n = model.firstEmpty, !model.tiles.contains(where: { $0.id == n }) { newWorkspaceButton(n) }
            Capsule().fill(Color.white.opacity(0.14))
                .frame(width: vertical ? 44 : 1, height: vertical ? 1 : 44)
                .padding(vertical ? .vertical : .horizontal, 4).padding(.bottom, vertical ? 0 : 14)
            utilityButtons
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, vertical ? 10 : 4)
        .background(Chrome.panel(cornerRadius: 24))
        .modifier(SizeReport(size: $barSize))
    }

    /// What the pointer is on, or the window strip, lined up with it.
    @ViewBuilder private var side: some View {
        let vertical = model.edge.isVertical
        if let app = model.stripApp, let n = model.strip?.workspace {
            windowStrip(app, workspace: n)
                .modifier(SizeReport(size: $sideSize))
                .offset(sideOffset("\(n):\(app.id)"))
        } else if let m = model.moreApps {
            moreList(m.apps, in: m.tile)
                .modifier(SizeReport(size: $sideSize))
                .offset(sideOffset("more:\(m.tile.id)"))
        } else if vertical {
            // As wide as the label, and nothing when there's none, so the panel (and the area that
            // keeps the dock up) never reaches far into the screen. The panel resizes with it, and
            // the bar stays put because the panel is pinned to its edge.
            label.modifier(SizeReport(size: $sideSize))
                .offset(sideOffset(hoverKey))
        } else {
            label.frame(height: 24)
        }
    }

    /// The dock key for what the pointer is on, as reported by `CenterReport`.
    private var hoverKey: String {
        switch model.hover {
        case .tile(let n): return "tile:\(n)"
        case .app(let n, let id): return "\(n):\(id)"
        case .newWorkspace: return "btn:new"
        case .launcher: return "btn:launcher"
        case .overview: return "btn:overview"
        case .more(let n): return "more:\(n)"
        case nil: return ""
        }
    }

    /// Across from `key` along the dock, but never past either end of it.
    private func sideOffset(_ key: String) -> CGSize {
        guard let c = frames[key].map({ CGPoint(x: $0.midX, y: $0.midY) }), barSize != .zero, sideSize != .zero, stackSize != .zero else { return .zero }
        // The bar as drawn, shrunk to fit or not; the centers are measured as drawn too.
        let bar = CGSize(width: barSize.width * barScale, height: barSize.height * barScale)
        if model.edge.isVertical {
            let room = max(0, (bar.height - sideSize.height) / 2)
            return CGSize(width: 0, height: min(max(c.y - stackSize.height / 2, -room), room))
        }
        let room = max(0, (bar.width - sideSize.width) / 2)
        return CGSize(width: min(max(c.x - stackSize.width / 2, -room), room), height: 0)
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
        if let file = model.fileDrag {
            switch file.target {
            case .app(let n, let id):
                guard let app = model.tiles.first(where: { $0.id == n })?.apps.first(where: { $0.id == id }) else { return nil }
                return file.canOpen ? "Hold to bring up \(app.name), or drop to open it there" : "Hold to bring up \(app.name)"
            case .tile(let n):
                return n == model.liveCurrent() ? "Workspace \(n) · you're here" : "Hold to go to Workspace \(n)"
            case nil:
                return "Hold on an app or a workspace"
            }
        }
        if let drag = model.drag {
            guard let to = model.dropTarget else { return "Drop on a workspace to move \(drag.name)" }
            return "Move \(drag.name) to Workspace \(to)"
        }
        switch model.hover {
        case .tile(let n): return model.tiles.first { $0.id == n }.map(title)
        case .app(let n, let id):
            guard let app = model.tiles.first(where: { $0.id == n })?.apps.first(where: { $0.id == id }) else { return nil }
            let elsewhere = model.tiles.filter { $0.id != n && $0.apps.contains { $0.pid == app.pid } }.map { String($0.id) }
            // The tile already says which workspace; the label adds only what the icon can't.
            var parts = [app.name]
            if app.windows > 1 { parts.append("\(app.windows) windows") }
            if !elsewhere.isEmpty { parts.append("also on \(elsewhere.count == 1 ? "Workspace" : "Workspaces") \(elsewhere.joined(separator: ", "))") }
            if let agent = app.agent { parts.append(agent.summary) }
            return parts.joined(separator: " · ")
        case .newWorkspace: return model.firstEmpty.map { "Go to Empty Workspace \($0)" }
        case .launcher: return "Find or Install an App"
        case .overview: return "Show All Workspaces"
        case .more(let n):
            guard let t = model.tiles.first(where: { $0.id == n }) else { return nil }
            return t.apps.dropFirst(DockModel.iconsShown).map(\.name).joined(separator: ", ")
        case nil: return nil
        }
    }

    /// The apps behind a tile's "+N", a row each. Click one to go straight to it.
    private func moreList(_ apps: [DockModel.App], in tile: DockModel.Tile) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Text("\(apps.count) more").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                Spacer(minLength: 8)
                WorkspaceBadge(n: tile.id, size: 17)
            }
            .padding(.horizontal, 8).padding(.bottom, 4)
            ForEach(apps) { app in
                MoreRow(app: app, tint: Chrome.workspace(tile.id)) { model.onFocusApp(app.pid, tile.id) }
                    .contextMenu { appMenu(app, in: tile) }
            }
        }
        .padding(6).padding(.top, 4)
        .frame(width: 240)
        .background(Chrome.panel(cornerRadius: 14))
        .onHover { inside in model.onStrip = inside }
    }

    /// An app's windows on one workspace, a row each with its title (a browser's tab, a player's
    /// video). Click one to go to it.
    private func windowStrip(_ app: DockModel.App, workspace n: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Image(nsImage: app.icon).resizable().frame(width: 18, height: 18)
                // Mid-drag the strip stays (it holds the row being dragged), so it says where
                // the drag lands in place of the label it covers.
                if model.drag != nil, let text = labelText {
                    Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
                } else {
                    Text(app.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    Text("\(app.list.count) windows").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                }
                Spacer(minLength: 8)
                WorkspaceBadge(n: model.dropTarget ?? n, size: 17)
            }
            .padding(.horizontal, 8).padding(.bottom, 4)
            // Every window is reachable: past ten, the list scrolls.
            ScrollView(.vertical, showsIndicators: app.list.count > 10) {
                VStack(spacing: 2) {
                    ForEach(app.list) { w in
                        StripRow(window: w, icon: app.icon, tint: Chrome.workspace(n), dragging: model.drag?.ids == [w.id],
                                 onDrag: { model.dragged([w.id], from: n, icon: app.icon, name: w.title.isEmpty ? app.name : "“\(w.title)”", to: $0) },
                                 onDragEnd: { model.endDrag() }) {
                            guard model.clickCounts else { return }
                            if let a = w.agent { model.onFocusAgent(a, n) } else { model.onFocusWindow(w.id, n) }
                        }
                    }
                }
            }
            .frame(height: CGFloat(min(app.list.count, 10)) * 30)
        }
        .padding(6).padding(.top, 4)
        .frame(width: 320)
        .background(Chrome.panel(cornerRadius: 14))
        .onHover { inside in model.onStrip = inside }
    }

    private func title(_ tile: DockModel.Tile) -> String {
        guard !tile.apps.isEmpty else { return "Workspace \(tile.id) · empty" }
        let apps = tile.apps.map { $0.windows > 1 ? "\($0.name) (\($0.windows))" : $0.name }
        let agent = tile.agents.max { $0.state.urgency < $1.state.urgency }
        return (["Workspace \(tile.id)", apps.joined(separator: ", ")] + [agent?.summary].compactMap { $0 }).joined(separator: " · ")
    }

    private func isHovered(_ tile: DockModel.Tile) -> Bool {
        switch model.hover {
        case .tile(let n), .app(let n, _), .more(let n): return n == tile.id
        default: return false
        }
    }

    private func tileView(_ tile: DockModel.Tile) -> some View {
        // Mid-drag from another app the tiles hold still, so a spring's switch shows from the live workspace.
        let tile = model.fileDrag == nil ? tile : DockModel.Tile(id: tile.id, apps: tile.apps, isCurrent: tile.id == model.liveCurrent(), agents: tile.agents, unpinned: tile.unpinned)
        let target = model.dropTarget == tile.id
        let hovered = isHovered(tile) || target
        let tint = Chrome.workspace(tile.id)
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return VStack(spacing: 5) {
            ZStack(alignment: .topLeading) {
                shape.fill(tile.isCurrent ? tint.opacity(hovered ? 0.34 : 0.26) : Color.white.opacity(hovered ? 0.13 : 0.06))
                    .overlay(shape.strokeBorder(tile.isCurrent || target ? tint : Color.white.opacity(hovered ? 0.18 : 0.08),
                                                lineWidth: target ? 2.5 : tile.isCurrent ? 1.5 : 1))
                    .onHover { model.setHover(.tile(tile.id), $0) }
                    .onTapGesture { model.onPick(tile.id) }
                icons(tile).frame(width: tileSize, height: tileSize)
                agentBadge(tile).frame(width: tileSize, height: tileSize, alignment: .topTrailing)
            }
            .frame(width: tileSize, height: tileSize)
            .modifier(CenterReport(key: "tile:\(tile.id)"))
            // The number under the tile, lit for the workspace you're on, like the key that gets there.
            Text("\(tile.id)")
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundStyle(tile.isCurrent ? Color.white : tint.opacity(hovered ? 1 : 0.85))
                .frame(minWidth: 18, minHeight: 15)
                .background(Capsule().fill(tile.isCurrent ? tint : Color.clear))
                .allowsHitTesting(false)
        }
        .modifier(HoverScale(scale: hovered ? 1.06 : 1, anchor: .bottom, spring: .spring(response: 0.25, dampingFraction: 0.72)))
        .contextMenu { tileMenu(tile) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title(tile) + (tile.isCurrent ? ", current" : ""))
        .accessibilityAction { model.onPick(tile.id) }
    }

    /// A finished agent lights the tile's corner orange with a count; clicking it goes to the
    /// agent. One still working turns a ring on its app's icon instead (`appIcon`): a plain
    /// dot on the tile read as an unread badge and didn't say which app (Donovan, 2026-10-16).
    @ViewBuilder private func agentBadge(_ tile: DockModel.Tile) -> some View {
        HStack(spacing: 2) {
            unpinnedBadge(tile)
            doneBadge(tile)
        }
    }

    /// An agent asking or stopped on an error with no app here to wear its badge: in the corner,
    /// beside a finished count if there is one, since it needs you more.
    @ViewBuilder private func unpinnedBadge(_ tile: DockModel.Tile) -> some View {
        if let a = tile.unpinned.filter({ $0.state != .done }).max(by: { $0.state.urgency < $1.state.urgency }) {
            AgentStatusBadge(state: a.state, size: 14)
                .contentShape(Circle())
                .onTapGesture { if model.clickCounts { model.onFocusAgent(a, tile.id) } }
                .help(a.summary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(a.summary)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { model.onFocusAgent(a, tile.id) }
                .offset(x: 4, y: -4)
        }
    }

    @ViewBuilder private func doneBadge(_ tile: DockModel.Tile) -> some View {
        if let done = tile.agents.first(where: { $0.state == .done }) {
            Text("\(tile.agentsDone)")
                .font(.system(size: 9.5, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                .frame(minWidth: 16, minHeight: 16).background(Circle().fill(Color.orange))
                .contentShape(Circle())
                .onTapGesture { if model.clickCounts { model.onFocusAgent(done, tile.id) } }
                .help(done.summary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(tile.agentsDone == 1 ? done.summary : "\(tile.agentsDone) agents finished, go to \(done.name)")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { model.onFocusAgent(done, tile.id) }
                .offset(x: 4, y: -4)
        }
    }

    // MARK: Right-click menus
    // Short on purpose (Donovan, 2026-10-14: "way too cluttered"). The dock's own buttons find
    // apps and show every workspace, so the menus hold only what a click can't do.

    /// Another workspace's tile: go there or bring the front window over. The tile you're on has
    /// nothing a click doesn't do, so it shows the dock's own settings.
    @ViewBuilder private func tileMenu(_ tile: DockModel.Tile) -> some View {
        if tile.isCurrent {
            dockOptions
        } else {
            Button("Go to Workspace \(tile.id)") { model.onPick(tile.id) }
            Button("Move Front Window Here") { model.onSendHere(tile.id) }
            Divider()
            Menu("Dock") { dockOptions }
        }
    }

    /// Show and Quit; holding ⌥ turns Quit into Force Quit, as in the macOS Dock.
    @ViewBuilder private func appMenu(_ app: DockModel.App, in tile: DockModel.Tile) -> some View {
        Button("Show \(app.name)") { model.onFocusApp(app.pid, tile.id) }
        Divider()
        let quit = Button("Quit \(app.name)") { NSRunningApplication(processIdentifier: app.pid)?.terminate() }
        let force = Button("Force Quit \(app.name)") { NSRunningApplication(processIdentifier: app.pid)?.forceTerminate() }
        if #available(macOS 15, *) {
            quit.modifierKeyAlternate(.option) { force }
        } else {
            quit
            force
        }
        // Icons cover most of a tile, so the tile's own action is here too.
        if !tile.isCurrent {
            Divider()
            Button("Move Front Window Here") { model.onSendHere(tile.id) }
        }
        Divider()
        Menu("Dock") { dockOptions }
    }

    @ViewBuilder private var dockOptions: some View {
        Section("Position on Screen") {
            ForEach(DockEdge.allCases, id: \.self) { e in
                Button { model.onSetEdge(e) } label: {
                    if e == model.edge { Label(e.title, systemImage: "checkmark") } else { Text(e.title) }
                }
            }
        }
        Divider()
        Button { model.onSetAgentStatus(!model.agentStatus) } label: {
            if model.agentStatus { Label("Show Agent Status", systemImage: "checkmark") } else { Text("Show Agent Status") }
        }
        Divider()
        Button("Turn Off Workspace Dock") { model.onTurnOff() }
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
            let shown = apps.count > 4 ? Array(apps.prefix(DockModel.iconsShown)) : apps
            LazyVGrid(columns: [GridItem(.fixed(24), spacing: 3), GridItem(.fixed(24), spacing: 3)], spacing: 3) {
                ForEach(shown) { appIcon($0, in: tile, size: 24) }
                if apps.count > 4 {
                    // Rest on it (or click it) to list the apps it stands for, each one clickable.
                    let open = model.hover == .more(tile.id) || model.more == tile.id
                    Text("+\(apps.count - DockModel.iconsShown)")
                        .font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(open ? 1 : 0.85))
                        .frame(width: 24, height: 24)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(open ? 0.24 : 0.12)))
                        .modifier(CenterReport(key: "more:\(tile.id)"))
                        .contentShape(Rectangle())
                        .onHover { model.setHover(.more(tile.id), $0) }
                        .onTapGesture { model.more = tile.id }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(apps.count - DockModel.iconsShown) more apps on workspace \(tile.id)")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { model.more = tile.id }
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
        let dragging = model.drag.map { $0.from == tile.id && $0.ids == app.list.map(\.id) } ?? false
        let hovered = model.drag == nil && model.hover == .app(tile.id, app.id)
        let twin = !hovered && hoveredPid == app.pid
        let ring: CGFloat = hovered ? 2 : twin ? 1 : 0
        return Image(nsImage: app.icon).resizable().interpolation(.high).frame(width: size, height: size)
            .shadow(color: .black.opacity(hovered ? 0.4 : 0.2), radius: hovered ? 4 : 2, y: 1)
            // The icon under the pointer is ringed in its workspace's color. The same app on
            // another workspace gets only a faint outline, so the ring never lands on the copy
            // you aren't pointing at. A macOS icon's art fills the middle 824 of its 1024 points
            // with a corner of about 185, so the ring traces that, a point outside it; around the
            // whole image it floated off the art and ran into the tile's edge.
            .overlay(RoundedRectangle(cornerRadius: size * 0.18 + ring + 1, style: .continuous)
                .strokeBorder(hovered ? Chrome.workspace(tile.id) : Color.white.opacity(0.4), lineWidth: ring)
                .padding(size * 100 / 1024 - ring - 1))
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
            .overlay(alignment: .topTrailing) {
                // The icon's own click and label already cover it.
                if let a = app.agent, a.state != .done {
                    AgentStatusBadge(state: a.state, size: max(10, size * 0.42)).offset(x: 3, y: -3)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .modifier(CenterReport(key: "\(tile.id):\(app.id)"))
            .modifier(HoverScale(scale: hovered ? 1.18 : 1, spring: .spring(response: 0.22, dampingFraction: 0.65)))
            .opacity(dragging ? 0.3 : 1)
            .contentShape(Rectangle())
            .onHover { model.setHover(.app(tile.id, app.id), $0) }
            // Drag it onto another tile to move all its windows here there.
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named("dock"))
                    .onChanged { v in model.dragged(app.list.map(\.id), from: tile.id, icon: app.icon, name: app.name, to: v.location) }
                    .onEnded { _ in model.endDrag() }
            )
            .simultaneousGesture(TapGesture().onEnded {
                guard model.clickCounts else { return }
                tapApp(app, in: tile)
            })
            .contextMenu { appMenu(app, in: tile) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(app.name), workspace \(tile.id)" + (app.agent.map { ", " + $0.summary } ?? ""))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { tapApp(app, in: tile) }
    }

    /// An agent waiting on you is why you'd click: go to its tab, not the app's last window.
    private func tapApp(_ app: DockModel.App, in tile: DockModel.Tile) {
        if let a = app.agent, a.state.needsYou { model.onFocusAgent(a, tile.id) } else { model.onFocusApp(app.pid, tile.id) }
    }

    private func newWorkspaceButton(_ n: Int) -> some View {
        let hovered = model.hover == .newWorkspace || model.dropTarget == n
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return VStack(spacing: 5) {
            shape.strokeBorder(Color.white.opacity(hovered ? 0.35 : 0.16), style: StrokeStyle(lineWidth: 1.2, dash: [4, 4]))
                .background(shape.fill(Color.white.opacity(hovered ? 0.08 : 0.0)))
                .overlay(Image(systemName: "plus").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white.opacity(hovered ? 0.9 : 0.45)))
                // Slimmer along the dock, full size across it: on a side dock it lines up with the
                // column of tiles instead of sitting narrower than them.
                .frame(width: model.edge.isVertical ? tileSize : tileSize * 0.75,
                       height: model.edge.isVertical ? tileSize * 0.75 : tileSize)
                .modifier(CenterReport(key: "btn:new"))
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

    /// Find an app and show every workspace: two small buttons sharing one tile's room, so the
    /// workspaces carry the dock. Stacked on a bottom or top dock, side by side on a side one.
    private var utilityButtons: some View {
        let vertical = model.edge.isVertical
        let pair = vertical ? AnyLayout(HStackLayout(spacing: 4)) : AnyLayout(VStackLayout(spacing: 4))
        let size = vertical ? CGSize(width: (tileSize - 4) / 2, height: 44) : CGSize(width: 44, height: (tileSize - 4) / 2)
        return VStack(spacing: 5) {
            pair {
                smallButton(.launcher, "magnifyingglass", "Find or Install an App", size: size) { model.onShowLauncher() }
                smallButton(.overview, "square.grid.3x3", "Show All Workspaces", size: size) { model.onShowOverview() }
            }
            .frame(height: tileSize)
            // Lines up with the tiles' number row.
            if !vertical { Color.clear.frame(width: 18, height: 15) }
        }
    }

    private func smallButton(_ which: DockModel.Hover, _ symbol: String, _ name: String, size: CGSize, _ action: @escaping () -> Void) -> some View {
        let hovered = model.hover == which
        return RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(hovered ? 0.16 : 0.05))
            .overlay(Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(hovered ? 0.95 : 0.6)))
            .frame(width: size.width, height: size.height)
            .modifier(CenterReport(key: which == .launcher ? "btn:launcher" : "btn:overview"))
            .modifier(HoverScale(scale: hovered ? 1.06 : 1, spring: .spring(response: 0.25, dampingFraction: 0.72)))
            .contentShape(Rectangle())
            .onHover { model.setHover(which, $0) }
            .onTapGesture(perform: action)
            .contextMenu { dockOptions }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(name)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

/// A drag from another app over the dock: it lights the icon or tile under it (the dock springs
/// that open after a moment, in `WorkspaceDock.springLoad`), and a drop on an app's icon opens
/// the files or links in that app, as the macOS Dock does.
private struct OutsideDrop: DropDelegate {
    let model: DockModel

    func validateDrop(info: DropInfo) -> Bool { true }

    func dropEntered(info: DropInfo) { track(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        track(info)
        guard case .app = model.fileDrag?.target, model.fileDrag?.canOpen == true else { return DropProposal(operation: .cancel) }
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        model.heldTarget = nil
        model.fileDrag = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        // What was lit when the button came up: the dock's tick may since have cleared the
        // drag and let the tiles move.
        let target = model.heldTarget
        model.heldTarget = nil
        model.fileDrag = nil
        guard case .app(let n, let id) = target, let pid = pid_t(id) else { return false }
        let urls = model.openable(pid)
        guard !urls.isEmpty else { return false }
        // The drop is answered at once; going to the app (Accessibility calls a busy app can
        // stall) waits for the next turn of the run loop, so the source app isn't held up.
        DispatchQueue.main.async { [model] in model.onOpenFiles(urls, pid, n) }
        return true
    }

    private func track(_ info: DropInfo) {
        let target = DockSpringTarget.at(info.location, frames: model.frames)
        var canOpen = false
        if case .app(_, let id) = target, let pid = pid_t(id) { canOpen = !model.openable(pid).isEmpty }
        model.heldTarget = target
        let state = DockModel.FileDrag(target: target, canOpen: canOpen)
        if model.fileDrag != state { model.fileDrag = state }
    }
}

/// One app behind a tile's "+N": its icon, name and window count.
private struct MoreRow: View {
    let app: DockModel.App
    let tint: Color
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: app.icon).resizable().interpolation(.high).frame(width: 18, height: 18)
            Text(app.name).font(.system(size: 12.5, weight: hovered ? .semibold : .regular))
                .foregroundStyle(.white.opacity(hovered ? 1 : 0.85)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            if app.windows > 1 {
                Text("\(app.windows) windows").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovered ? tint.opacity(0.85) : .clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: action)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.name)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}

/// One window in the dock's window strip: its title on one line, the full title on hover.
private struct StripRow: View {
    let window: DockModel.Window
    let icon: NSImage
    let tint: Color
    var dragging = false
    var onDrag: (CGPoint) -> Void = { _ in }
    var onDragEnd: () -> Void = {}
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let title = window.title.isEmpty ? "Untitled window" : window.title
        HStack(spacing: 8) {
            Image(nsImage: icon).resizable().frame(width: 16, height: 16).opacity(hovered ? 1 : 0.85)
            Text(title).font(.system(size: 12.5, weight: hovered ? .semibold : .regular))
                .foregroundStyle(.white.opacity(hovered ? 1 : 0.85)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            if let a = window.agent, a.state == .working {
                AgentStatusBadge(state: a.state, size: 12).allowsHitTesting(false).accessibilityHidden(true)
            } else if let a = window.agent {
                Text(a.state.word).font(.system(size: 10, weight: .semibold)).foregroundStyle(a.state.color)
            } else if window.isLast {
                Text("Last used").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovered ? tint.opacity(0.85) : .clear))
        .contentShape(Rectangle())
        .opacity(dragging ? 0.4 : 1)
        .help(title)
        .onHover { hovered = $0 }
        // Drag it onto a workspace tile to move just this window there.
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named("dock"))
                .onChanged { onDrag($0.location) }
                .onEnded { _ in onDragEnd() }
        )
        .simultaneousGesture(TapGesture().onEnded(action))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title + (window.agent.map { ", " + $0.summary } ?? (window.isLast ? ", last used" : "")))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}

/// What an agent is doing, in the corner of its app's icon: a turning ring while it works, a
/// yellow "?" when it's asking you something, a red "!" when it stopped on an error. A finish
/// is the tile's orange count instead. Shapes differ as well as colors, so it reads without color.
struct AgentStatusBadge: View {
    let state: DockAgent.State
    let size: CGFloat

    var body: some View {
        if state == .working {
            AgentSpinner(size: size)
        } else {
            Image(systemName: state.symbol)
                .font(.system(size: size * 0.62, weight: .heavy))
                .foregroundStyle(state == .asking ? Color.black.opacity(0.85) : Color.white)
                .frame(width: size, height: size)
                .background(Circle().fill(state.color))
                .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.75))
        }
    }
}

extension DockAgent.State {
    var color: Color {
        switch self {
        case .working: .blue
        case .asking: .yellow
        case .failed: .red
        case .done: .orange
        }
    }

    var symbol: String {
        switch self {
        case .working: "arrow.triangle.2.circlepath"
        case .asking: "questionmark"
        case .failed: "exclamationmark"
        case .done: "checkmark"
        }
    }

    /// The strip's word for it.
    var word: String {
        switch self {
        case .working: "Working"
        case .asking: "Needs you"
        case .failed: "Error"
        case .done: "Finished"
        }
    }
}

/// An agent at work: a short arc that turns, so it reads as "in progress", not "unread". With
/// Reduce Motion on, it holds still.
private struct AgentSpinner: View {
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false

    var body: some View {
        Circle().trim(from: 0, to: 0.7)
            .stroke(Color.white, style: StrokeStyle(lineWidth: max(1.5, size * 0.16), lineCap: .round))
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(reduceMotion ? nil : .linear(duration: 1).repeatForever(autoreverses: false), value: turning)
            .padding(size * 0.22)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.blue))
            .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.75))
            .onAppear { turning = !reduceMotion }
    }
}
