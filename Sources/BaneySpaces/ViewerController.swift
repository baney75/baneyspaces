import AppKit
import BaneySpacesCore
import SwiftUI

/// A borderless panel over everything, on every display's active desktop.
final class ViewerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// One display's overview: its own panel, its own model (the workspace this display shows is the
/// one marked; the others are dimmed with the name of the display showing them).
final class OverviewDisplay {
    let screen: NSScreen
    let key: DisplayKey?
    let model = ViewerModel()
    let panel: ViewerPanel
    let container: OverviewContainer
    let motion = OverviewMotionRunner()
    /// The display's frame in Accessibility coordinates, the space window frames are in.
    var ax: CGRect = .zero

    init(screen: NSScreen) {
        self.screen = screen
        key = Windows.key(of: screen)
        let hosting = NSHostingView(rootView: ViewerView(model: model).environment(\.colorScheme, .dark))
        container = OverviewContainer(hosting: hosting)
        panel = ViewerPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = container
    }
}

final class ViewerController {
    private let spaces: Spaces
    private var displays: [OverviewDisplay] = []
    private var keyMonitor: Any?
    /// Open from the moment `open()` runs until `close()` starts, not until the fade ends, so a
    /// quick second press always does the right thing.
    private(set) var isOpen = false { didSet { MissionControlKeys.viewerOpen = isOpen } }
    /// Bumped on every open, so a fade-out that finishes late can't hide a viewer reopened since.
    private var openCount = 0
    /// What the last visit saw, for the first frame of the next: previews are in `OverviewPreviews`.
    private var cached: [Int: [Spaces.Entry]]?
    private var help = OverviewHelp(opens: UserDefaults.standard.integer(forKey: ViewerController.opensKey))
    private static let opensKey = "overviewOpens"

    /// The agent on each window, for its badge on the card.
    var agents: () -> [DockAgent] = { [] }
    /// A strip slot, a tile's `+`, or a search with no match, asks to open something on workspace `n`: the launcher's open-here
    /// (`fix/open-here` adds the entry point; until it merges, AppDelegate goes to `n` and shows the launcher).
    var onOpenHere: (Int, String?) -> Void = { _, _ in }

    init(spaces: Spaces) { self.spaces = spaces }

    /// `behavior.overview` (spec/config.md), kept as other settings are until the config file lands on macOS.
    private var settings: OverviewSettings {
        let d = UserDefaults.standard
        return OverviewSettings(layout: d.string(forKey: "overviewLayout").flatMap(OverviewLayoutMode.init) ?? .adaptive,
                                empty: d.string(forKey: "overviewEmpty").flatMap(OverviewEmptyMode.init) ?? .compact,
                                previews: d.string(forKey: "overviewPreviews").flatMap(OverviewPreviewMode.init) ?? .live)
    }

    /// The display the keys go to: the one whose panel is key, else the first.
    private var active: OverviewDisplay? {
        displays.first { $0.panel.isKeyWindow } ?? displays.first
    }

    func toggle() { isOpen ? active?.model.onClose() : open() }

    // MARK: Opening

    func open() {
        removeMonitor()
        isOpen = true
        openCount += 1
        help.opened()
        UserDefaults.standard.set(help.opens, forKey: Self.opensKey)
        // Opened on the display under the pointer, it's about that display's workspace.
        spaces.usePointerDisplay()
        let pointer = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        build(for: NSScreen.screens, first: pointer)
        // The first frame is drawn from what the last visit saw; the scan comes after it.
        let entries = cached ?? spaces.overviewEntries()
        cached = entries
        let plan = motionPlan()
        for d in displays {
            d.model.reset()
            d.model.help = help
            d.panel.ignoresMouseEvents = false
            d.panel.setFrame(d.screen.frame, display: true)
            d.panel.alphaValue = 0
        }
        configure(entries: entries)
        for d in displays { d.panel.orderFrontRegardless() }
        show(plan: plan)
        installMonitor()
        let count = openCount
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isOpen, self.openCount == count else { return }
            // Recorded before the viewer takes the keyboard, so closing returns to the window in front now.
            self.spaces.rememberFocus()
            let fresh = self.spaces.overviewEntries()
            self.cached = fresh
            self.configure(entries: fresh, keepingState: true)
            // The viewer takes the keyboard so 1–9, Return and Esc reach it, not the app below.
            Windows.makeFrontmost(getpid())
            NSApp.activate(ignoringOtherApps: true)
            self.active?.panel.makeKeyAndOrderFront(nil)
            self.refreshPreviews()
        }
    }

    private func motionPlan() -> OverviewMotion {
        OverviewMotion.plan(spec: Chrome.spec, previews: settings.previews == .live && OverviewPreviews.allowed, reduceMotion: Chrome.reduceMotion)
    }

    /// One panel per display, reused from the last visit.
    private func build(for screens: [NSScreen], first: NSScreen?) {
        var next: [OverviewDisplay] = []
        for s in screens {
            let key = Windows.key(of: s)
            if let old = displays.first(where: { $0.key == key && $0.screen.frame == s.frame }) { next.append(old) } else { next.append(OverviewDisplay(screen: s)) }
        }
        for gone in displays where !next.contains(where: { $0 === gone }) { gone.panel.orderOut(nil) }
        // The pointer's display first: it takes the keyboard.
        displays = next.sorted { ($0.screen == first ? 0 : 1) < ($1.screen == first ? 0 : 1) }
        for d in displays { wire(d) }
    }

    private func wire(_ d: OverviewDisplay) {
        let m = d.model
        m.onPick = { [weak self, weak d] n in
            guard let self, let d else { return }
            self.close(toward: n)
            self.spaces.use(display: d.key)
            self.spaces.switchTo(n)
        }
        m.onPickWindow = { [weak self, weak d] id, n in
            guard let self, let d else { return }
            self.close(toward: n)
            self.spaces.use(display: d.key)
            self.spaces.focus(id, on: n)
        }
        m.onMove = { [weak self, weak d] id, n, follow in
            guard let self, let d else { return }
            self.spaces.move(id, to: n)
            if follow {
                // Option held: go with it.
                self.close(toward: n)
                self.spaces.use(display: d.key)
                self.spaces.switchTo(n)
            } else {
                // The tile already shows the move; reload once the real one has settled.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.reload() }
            }
        }
        // Closing without a pick hands focus back to the workspace you were on.
        m.onClose = { [weak self, weak d] in
            guard let self, let d else { return }
            let n = d.model.current
            self.close(toward: n)
            self.spaces.use(display: d.key)
            self.spaces.switchTo(n)
        }
        m.onCloseWindow = { [weak self] id, n in self?.closeWindow(id, on: n) }
        m.onOpenHere = { [weak self, weak d] n, text in
            guard let self, let d else { return }
            self.close(toward: n)
            self.spaces.use(display: d.key)
            self.onOpenHere(n, text)
        }
    }

    /// Each display's tiles from the scan: windows keep their place on their own display and are
    /// mapped to the same share of this one.
    private func configure(entries: [Int: [Spaces.Entry]], keepingState: Bool = false) {
        let all = Windows.displays()
        let shown = spaces.model.shown
        let mapped = agents().reduce(into: [WindowID: DockAgent]()) { if $1.window != 0 { $0[$1.window] = $1 } }
        for d in displays {
            let m = d.model
            let me = all.first { $0.key == d.key }
            d.ax = me?.frame ?? Geometry.toAX(d.screen.frame, primaryHeight: NSScreen.screens.first?.frame.height ?? 0)
            m.settings = settings
            m.safeTop = d.screen.safeAreaInsets.top
            m.displayName = shown.count > 1 ? d.screen.localizedName : nil
            m.current = spaces.workspace(onScreen: d.screen)
            m.otherDisplays = [:]
            for other in displays where other !== d {
                if let k = other.key, let n = shown[k], k != d.key { m.otherDisplays[n] = other.screen.localizedName }
            }
            m.agents = mapped
            var tiles: [Int: [Spaces.Entry]] = [:]
            let frames = Dictionary(all.map { ($0.key, $0.frame) }, uniquingKeysWith: { a, _ in a })
            for (n, list) in entries {
                tiles[n] = list.map { e in
                    var e = e
                    if let f = e.frame {
                        let from = Geometry.display(of: f, in: frames).flatMap { frames[$0] } ?? d.ax
                        e.frame = OverviewLayout.map(f, from: from, to: d.ax)
                    }
                    return e
                }
            }
            for n in Workspaces.range where tiles[n] == nil { tiles[n] = [] }
            if !keepingState || !Self.same(m.tiles, tiles) { m.tiles = tiles }
            if settings.previews == .live, OverviewPreviews.allowed {
                m.previews = OverviewPreviews.shared.known(entries.values.flatMap { $0.map(\.id) })
            } else {
                m.previews = [:]
            }
        }
    }

    private static func same(_ a: [Int: [Spaces.Entry]], _ b: [Int: [Spaces.Entry]]) -> Bool {
        guard a.keys == b.keys else { return false }
        for (n, list) in a {
            let other = b[n] ?? []
            guard list.count == other.count, zip(list, other).allSatisfy({ $0.id == $1.id && $0.title == $1.title && $0.frame == $1.frame }) else { return false }
        }
        return true
    }

    /// Live previews fill in after the first frame.
    private func refreshPreviews() {
        guard settings.previews == .live, OverviewPreviews.allowed else { return }
        let ids = Workspaces.range.flatMap { n in (cached?[n] ?? []).map(\.id) }
        OverviewPreviews.shared.refresh(ids) { [weak self] id, image in
            guard let self, self.isOpen else { return }
            for d in self.displays { d.model.previews[id] = image }
        }
    }

    /// A scan of the windows, for after something moved or closed.
    private func reload() {
        guard isOpen else { return }
        let fresh = spaces.overviewEntries()
        cached = fresh
        configure(entries: fresh, keepingState: true)
    }

    // MARK: Motion

    private func show(plan: OverviewMotion) {
        let spring = OverviewSpring.opening(spec: Chrome.spec)
        let seconds = plan == .none ? 0 : plan == .travel ? min(spring.response, 0.4) : Chrome.duration(0.12, .panelIn)
        for d in displays {
            d.motion.cancel(model: d.model, container: d.container)
            let layout = d.model.layout(for: d.screen.frame.size)
            d.motion.open(plan: plan, model: d.model, layout: layout, container: d.container) {}
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = seconds
                d.panel.animator().alphaValue = 1
            }
            if seconds == 0 { d.panel.alphaValue = 1 }
        }
    }

    // MARK: Keys and the middle button

    private func installMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseUp]) { [weak self] event in
            guard let self, self.isOpen else { return event }
            if event.type == .otherMouseUp { return self.middleClick(event) ? nil : event }
            return self.key(event) ? nil : event
        }
    }

    private func removeMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    /// A middle click on a card closes its window.
    private func middleClick(_ event: NSEvent) -> Bool {
        guard event.buttonNumber == 2, let d = displays.first(where: { $0.panel === event.window }), d.model.drag == nil else { return false }
        let h = d.panel.contentView?.bounds.height ?? 0
        let p = CGPoint(x: event.locationInWindow.x, y: h - event.locationInWindow.y)
        guard let hit = d.model.card(at: p) else { return false }
        d.model.onCloseWindow(hit.id, hit.workspace)
        return true
    }

    /// The window's own close button is pressed, so an app with unsaved changes asks first. If the
    /// window is still there a moment later, the app is asking: it comes forward so the question is seen.
    private func closeWindow(_ id: WindowID, on n: Int) {
        spaces.closeWindow(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.isOpen else { return }
            if self.spaces.isOpen(id) {
                self.close(toward: n)
                self.spaces.focus(id, on: n)
            } else {
                self.reload()
            }
        }
    }

    /// Handles one key; true when the overview took it.
    private func key(_ event: NSEvent) -> Bool {
        guard let d = active else { return false }
        let m = d.model
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⌘ and ⌃ shortcuts belong to the system and to BaneySpaces' own hotkeys.
        if flags.contains(.command) || flags.contains(.control) { return false }
        switch event.keyCode {
        case 53:   // Esc: the text first, then the overview.
            if m.query.isEmpty { m.onClose() } else { setQuery("") }
            return true
        case 36, 76:   // Return
            return enter(d)
        case 51:   // Delete
            if !m.query.isEmpty { setQuery(String(m.query.dropLast())) }
            return true
        case 123, 124, 125, 126:
            guard m.drag == nil, m.query.isEmpty, let l = m.lastLayout else { return true }
            let dir: OverviewDirection = [123: .left, 124: .right, 125: .down, 126: .up][event.keyCode] ?? .right
            m.keyed = OverviewNav.move(from: m.highlighted, dir, in: l, current: m.current)
            return true
        default: break
        }
        guard let chars = event.characters, !chars.isEmpty, chars.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 && !(0xF700...0xF8FF).contains($0.value) }) else {
            return false
        }
        if m.query.isEmpty {
            if let n = Int(chars), Workspaces.range.contains(n) { m.onPick(n); return true }
            if chars == "?" { var h = m.help; h.toggle(); for x in displays { x.model.help = h }; help.forced = h.forced; return true }
            if chars == "+" || chars == "=" { return openHere(on: d) }
            if chars == " " { return true }
        }
        setQuery(m.query + chars)
        return true
    }

    private func setQuery(_ text: String) {
        for d in displays { d.model.query = text; d.model.keyed = nil }
    }

    /// Return: the best match of what was typed, or what's selected. With a search that matches nothing,
    /// the launcher is asked for it.
    private func enter(_ d: OverviewDisplay) -> Bool {
        let m = d.model
        if !m.query.isEmpty {
            if let best = m.found?.best { m.activate(.card(best)) } else { m.onOpenHere(m.current, m.query) }
            return true
        }
        m.activate(m.highlighted ?? .tile(m.current))
        return true
    }

    /// `+` on a selected tile or slot opens the launcher for that workspace.
    private func openHere(on d: OverviewDisplay) -> Bool {
        let m = d.model
        switch m.highlighted {
        case .tile(let n)?, .slot(let n)?: m.onOpenHere(n, nil)
        case .plus?: if let n = m.lastLayout?.plusTarget { m.onOpenHere(n, nil) }
        default: m.onOpenHere(m.current, nil)
        }
        return true
    }

    // MARK: Carrying a window up from the desktop

    /// The top-left of the screen a carried window's overview is on, in window-server space.
    private var carryOrigin = CGPoint.zero

    /// Opens over the screen under `p` for a window being dragged to the top of the screen, in
    /// place of Mission Control. The drag stays the window server's: the viewer takes neither
    /// the pointer nor the keyboard, and only follows where it goes. False for a window that
    /// isn't on a workspace.
    func openCarrying(_ id: WindowID, at p: CGPoint) -> Bool {
        guard !isOpen, let (entry, from) = spaces.entry(for: id) else { return false }
        // Matched in window-server space, as the drag was: at a screen's very top edge an AppKit
        // point would fall just outside it.
        let cgFrames = TopDragWatcher.screens()
        guard let mainHeight = NSScreen.screens.first?.frame.maxY,
              let i = cgFrames.firstIndex(where: { $0.contains(p) }), i < NSScreen.screens.count else { return false }
        let screen = NSScreen.screens[i]
        removeMonitor()
        isOpen = true
        openCount += 1
        build(for: [screen], first: screen)
        guard let d = displays.first else { return false }
        d.model.reset()
        d.model.help = help
        configure(entries: spaces.overviewEntries())
        carryOrigin = CGPoint(x: screen.frame.minX, y: mainHeight - screen.frame.maxY)
        d.panel.ignoresMouseEvents = true
        d.panel.setFrame(screen.frame, display: true)
        d.model.carrying = true
        d.model.drag = ViewerModel.Drag(entry: entry, from: from, location: viewerPoint(p))
        d.panel.alphaValue = 0
        d.panel.orderFrontRegardless()
        show(plan: motionPlan())
        Trace.log("topDrag open window=\(id) from=\(from)")
        return true
    }

    /// The carried window's card follows the pointer.
    func carryMoved(to p: CGPoint) {
        guard isOpen, let d = active, d.model.carrying, var drag = d.model.drag else { return }
        drag.location = viewerPoint(p)
        d.model.drag = drag
        d.model.dragMoved()
    }

    /// The button came up: the workspace the window was let go over, if not its own, and whether Option
    /// was held to go with it. Closes.
    func endCarrying() -> (workspace: Int, follow: Bool)? {
        guard isOpen, let d = active, d.model.carrying else { return nil }
        let target = d.model.dropTarget
        let follow = NSEvent.modifierFlags.contains(.option)
        Trace.log("topDrag release target=\(target.map(String.init) ?? "none") follow=\(follow)")
        close(toward: target)
        return target.map { ($0, follow) }
    }

    /// The pointer in the viewer's own space: the panel's top-left is its origin, the camera housing included.
    private func viewerPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - carryOrigin.x, y: p.y - carryOrigin.y)
    }

    // MARK: Closing

    /// Closes toward workspace `n` (the one picked; the cards of its windows return to them).
    func close(toward n: Int? = nil) {
        removeMonitor()
        guard isOpen else { return }
        isOpen = false
        let count = openCount
        let plan = motionPlan()
        let spring = OverviewSpring.closing(spec: Chrome.spec)
        let seconds = plan == .none ? 0 : plan == .travel ? min(spring.response, 0.35) : Chrome.duration(0.1, .panelOut)
        cached = cached ?? [:]
        for d in displays {
            let layout = d.model.layout(for: d.screen.frame.size)
            d.model.drag = nil
            d.model.carrying = false
            d.motion.close(plan: plan, model: d.model, layout: layout, toward: n, container: d.container) {}
            let panel = d.panel
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = seconds
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self, weak d] in
                guard let self, self.openCount == count, !self.isOpen else { return }
                panel.orderOut(nil)
                if let d { d.motion.finish(model: d.model) }
            })
            if seconds == 0 { panel.alphaValue = 0; panel.orderOut(nil) }
        }
        UserDefaults.standard.set(help.opens, forKey: Self.opensKey)
    }
}
