import AppKit
import BaneySpacesCore
import Carbon.HIToolbox
import SwiftUI

/// The Deck: every terminal split, browser tab and coding agent on this workspace in one sidebar,
/// with a switcher, agent state from hooks, and a toast when an agent finishes while you're
/// elsewhere. BaneySpaces' app delegate owns it and starts it once Accessibility is allowed.
final class DeckController {
    let engine = Engine()
    let server = Server()
    let model = DeckModel()
    lazy var panel = SidebarPanel(model: model)
    lazy var palette = PalettePanel()
    lazy var edge = EdgeTrigger()
    lazy var toast = ToastPanel()
    /// ⌃⌘ keys: held while any wrapped app is in front. No app we wrap uses them.
    let deckKeys = ScopedHotkeys(signature: "BSDK")
    /// ⌘⇧ keys: held only while a terminal is in front, so browsers keep ⌘⇧C (Inspect) and ⌘⇧B (bookmarks).
    let terminalKeys = ScopedHotkeys(signature: "BSTM")
    /// Esc, held only while the drawer is open, so it never eats Esc otherwise.
    let escape = ScopedHotkeys(signature: "BSES")
    var visibility = SidebarVisibility(pinned: UserDefaults.standard.bool(forKey: "deckPinned"))
    var layout = Deck.Layout(rawValue: UserDefaults.standard.string(forKey: "deckLayout") ?? "") ?? .stack
    /// Rows you've been to, oldest first, for ⌃⌘[ and ⌃⌘].
    var history = DeckHistory()
    var currentFocus: Item?
    var previousFocus: Item?
    var trustTimer: Timer?
    private(set) var started = false

    /// Set by the app delegate: the menu bar badge shows how many agents finished unseen.
    var onUnseenChange: (Int) -> Void = { _ in }

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "deckEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "deckEnabled") }
    }

    var reserve: CGFloat { visibility.pinned ? SidebarPanel.width + SidebarPanel.margin : 0 }
    var effectiveLayout: Deck.Layout { visibility.pinned ? layout : .free }
    var unseenCount: Int { engine.attention.unseen.count }

    func start(workspaceOf: @escaping (UInt32) -> Int?, currentWorkspace: @escaping () -> Int) {
        guard !started else { return }
        started = true
        wireModel()
        engine.workspaceOf = workspaceOf
        engine.currentWorkspace = currentWorkspace
        engine.onUpdate = { [weak self] in self?.engineUpdated() }
        engine.onNewWindow = { [weak self] pid in self?.windowAppeared(pid) }
        engine.start()
        server.handle = { [weak self] in self?.handle($0) ?? Wire.Reply(ok: false) }
        server.start()

        let ctrlCmd = controlKey | cmdKey, cmdShift = cmdKey | shiftKey
        deckKeys.add(keyCode: kVK_ANSI_K, modifiers: ctrlCmd) { [weak self] in self?.togglePalette() }
        deckKeys.add(keyCode: kVK_ANSI_B, modifiers: ctrlCmd) { [weak self] in self?.send(.toggleKey) }
        deckKeys.add(keyCode: kVK_ANSI_U, modifiers: ctrlCmd) { [weak self] in self?.jumpToFinished() }
        deckKeys.add(keyCode: kVK_ANSI_LeftBracket, modifiers: ctrlCmd) { [weak self] in self?.goBack() }
        deckKeys.add(keyCode: kVK_ANSI_RightBracket, modifiers: ctrlCmd) { [weak self] in self?.goForward() }
        terminalKeys.add(keyCode: kVK_ANSI_C, modifiers: cmdShift) { [weak self] in self?.tile() }
        terminalKeys.add(keyCode: kVK_ANSI_B, modifiers: cmdShift) { [weak self] in self?.send(.toggleKey) }
        terminalKeys.add(keyCode: kVK_ANSI_U, modifiers: cmdShift) { [weak self] in self?.jumpToFinished() }
        escape.add(keyCode: kVK_Escape, modifiers: 0) { [weak self] in self?.send(.escape) }

        panel.onPointer = { [weak self] inside in self?.pointer(inside: inside) }
        edge.onRest = { [weak self] in self?.send(.edgeRest) }
        toast.onPick = { [weak self] id in if let i = self?.engine.item(id) { self?.focus(i) } }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.panel.shown { self.panel.place(on: DeckLayout.activeScreen(), animated: false) }
            self.apply()
        }
        if !AX.isTrusted { watchForTrust() }
        model.hooksInstalled = Self.hooksInstalled()
        appChanged()
    }

    /// Everything off: keys released, panels gone. Windows stay where they are.
    func stop() {
        guard started else { return }
        started = false
        deckKeys.deactivate(); terminalKeys.deactivate(); escape.deactivate()
        panel.orderOut(nil); edge.orderOut(nil); palette.dismiss(); toast.orderOut(nil)
    }

    func wireModel() {
        model.pinned = visibility.pinned
        model.layout = layout
        model.onFocus = { [weak self] in self?.focus($0); self?.send(.picked) }
        model.onClose = { [weak self] item, what in self?.engine.close(item, what) }
        model.onNewHere = { [weak self] in self?.engine.newTerminal(in: $0.directory) }
        model.onTile = { [weak self] in self?.tile() }
        model.onNewClaude = { [weak self] in self?.newClaude(); self?.send(.picked) }
        model.onNewTerminal = { [weak self] in
            self?.engine.newTerminal(in: self?.engine.items.first { $0.focused && !$0.directory.isEmpty }?.directory)
            self?.send(.picked)
        }
        model.onPin = { [weak self] in self?.send(.pin($0)) }
        model.onLayout = { [weak self] in self?.setLayout($0) }
        model.onAllow = { AX.askForTrust() }
        model.onSearch = { [weak self] in self?.togglePalette() }
        model.onInstallHooks = { [weak self] in self?.installHooks() }
        palette.model.source = { [weak self] in self?.paletteEntries() ?? [] }
    }

    // MARK: engine

    var lastState = ""
    var lastUnseen: [String] = []
    func engineUpdated() {
        if model.items != engine.items { model.items = engine.items }
        let unseen = engine.attention.unseen
        if model.unseen != unseen { model.unseen = unseen }
        if model.trusted != AX.isTrusted { model.trusted = AX.isTrusted }
        // Newly finished while you're in some other app: say so, once, in a corner.
        let fresh = unseen.filter { !lastUnseen.contains($0) }
        if let id = fresh.first, let item = engine.item(id), wrappedFront == nil || !(item.focused) {
            toast.show(item, more: fresh.count - 1, on: DeckLayout.activeScreen())
        }
        if unseen != lastUnseen { onUnseenChange(unseen.count) }
        lastUnseen = unseen
        if let f = engine.items.first(where: \.focused), f.id != currentFocus?.id {
            if let c = currentFocus, c.windowNumber != f.windowNumber { previousFocus = c }
            currentFocus = f
            history.visit(f.id)
        }
        writeState()
    }

    /// What the Deck believes, for checks, agents and bug reports:
    /// ~/Library/Application Support/BaneySpaces/deck.json.
    func writeState() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        struct State: Encodable {
            let trusted: Bool
            let pinned: Bool
            let open: Bool
            let sidebarVisible: Bool
            let layout: String
            let unseen: [String]
            let reads: [String: String]
            let items: [Item]
        }
        let s = State(trusted: AX.isTrusted, pinned: visibility.pinned, open: visibility.open, sidebarVisible: panel.shown,
                      layout: effectiveLayout.rawValue, unseen: engine.attention.unseen, reads: engine.statusInfo, items: engine.items)
        guard let data = try? enc.encode(s), let text = String(data: data, encoding: .utf8), text != lastState else { return }
        lastState = text
        try? FileManager.default.createDirectory(at: Wire.supportDir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: Wire.statePath), options: .atomic)
    }

    /// A new wrapped window: while docked it joins the deck frame, or at least leaves the strip.
    func windowAppeared(_ pid: pid_t) {
        guard visibility.pinned, panel.shown else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            if self.effectiveLayout == .stack { DeckLayout.stack(self.engine, reserve: self.reserve) }
            else { DeckLayout.clearStrip(self.engine, width: self.reserve) }
        }
    }

    func watchForTrust() {
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] t in
            guard AX.isTrusted else { return }
            t.invalidate()
            self?.engine.retryWatching()
            self?.model.trusted = true
        }
    }

    // MARK: showing and hiding

    var wrappedFront: AppSpec? {
        guard let b = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return nil }
        return engine.specs.first { $0.bundleID == b }
    }

    func send(_ e: SidebarVisibility.Event) {
        guard started else { return }
        // A rest timer that started just before you switched apps must not open it behind your back.
        if e == .edgeRest && wrappedFront == nil { return }
        let wasPinned = visibility.pinned
        visibility.handle(e)
        if visibility.pinned != wasPinned {
            UserDefaults.standard.set(visibility.pinned, forKey: "deckPinned")
            model.pinned = visibility.pinned
        }
        apply()
        if visibility.pinned && !wasPinned { arrange() }
        if e == .edgeRest { closeUnlessPointerArrives() }
    }

    func closeUnlessPointerArrives() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            guard let self, self.panel.shown, !self.visibility.pinned else { return }
            if !self.panel.frame.insetBy(dx: -10, dy: 0).contains(NSEvent.mouseLocation) { self.send(.pointerLeft) }
        }
    }

    /// The app delegate calls this when the front app changes.
    func appChanged() {
        guard started else { return }
        let front = wrappedFront
        if front != nil { deckKeys.activate() } else { deckKeys.deactivate() }
        if front?.role == .terminal { terminalKeys.activate() } else { terminalKeys.deactivate() }
        // BaneySpaces' own panels (the switcher, the launcher) count as staying in the deck.
        if front == nil && NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid() {
            visibility.handle(.ghosttyInactive)
        }
        apply()
    }

    func apply() {
        let front = wrappedFront != nil
        let show = visibility.visible(ghosttyFront: front)
        if show {
            if !panel.shown { panel.place(on: DeckLayout.activeScreen(), animated: !visibility.pinned) }
            else if let s = panel.screen, s != DeckLayout.activeScreen() { panel.place(on: DeckLayout.activeScreen(), animated: false) }
            panel.orderFrontRegardless()
            edge.orderOut(nil)
        } else {
            panel.slideOut()
            if front { edge.place(on: DeckLayout.activeScreen()); edge.orderFrontRegardless() } else { edge.orderOut(nil) }
        }
        if show && !visibility.pinned && front { escape.activate() } else { escape.deactivate() }
        engine.scheduleSweep(visible: show)
        writeState()
    }

    var leaveTimer: Timer?
    func pointer(inside: Bool) {
        leaveTimer?.invalidate()
        if inside { send(.pointerEntered); return }
        leaveTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in self?.send(.pointerLeft) }
    }

    // MARK: actions

    func focus(_ item: Item) {
        if effectiveLayout == .split {
            DeckLayout.split(engine, left: currentFocus?.id == item.id ? previousFocus : currentFocus, right: item, reserve: reserve)
        } else if effectiveLayout == .stack {
            DeckLayout.place(engine, item: item, reserve: reserve)
        }
        engine.focus(item)
    }

    func goBack() { if let id = history.back(alive: Set(engine.items.map(\.id))), let i = engine.item(id) { focus(i) } else { NSSound.beep() } }
    func goForward() { if let id = history.forward(alive: Set(engine.items.map(\.id))), let i = engine.item(id) { focus(i) } else { NSSound.beep() } }

    /// Puts every window where the layout says, once, when docking or switching layout.
    func arrange() {
        switch effectiveLayout {
        case .stack: DeckLayout.stack(engine, reserve: reserve)
        case .split:
            if let c = currentFocus { DeckLayout.split(engine, left: previousFocus, right: c, reserve: reserve) }
            else { DeckLayout.clearStrip(engine, width: reserve) }
        case .free: DeckLayout.clearStrip(engine, width: reserve)
        }
    }

    func setLayout(_ l: Deck.Layout) {
        layout = l
        model.layout = l
        UserDefaults.standard.set(l.rawValue, forKey: "deckLayout")
        if !visibility.pinned { send(.pin(true)) } else { arrange() }
        writeState()
    }

    func tile() {
        DeckLayout.tile(engine, reserve: reserve)
        model.trusted = AX.isTrusted
        send(.picked)
    }

    func jumpToFinished() {
        guard let id = engine.attention.unseen.first, let item = engine.item(id) else { NSSound.beep(); return }
        focus(item)
    }

    func togglePalette() {
        if palette.isOpen { palette.dismiss() } else { palette.show(on: DeckLayout.activeScreen()) }
    }

    func newClaude() {
        let desk = NSHomeDirectory() + "/.local/bin/claude-desk"
        if FileManager.default.isExecutableFile(atPath: desk) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: desk)
            try? p.run()
        } else {
            let dir = engine.items.first { $0.focused && !$0.directory.isEmpty }?.directory
            engine.newTerminal(in: dir, command: "claude")
        }
    }

    static func cliPath() -> String { Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin/baneyspaces").path }

    static func hooksInstalled() -> Bool {
        guard let d = FileManager.default.contents(atPath: NSHomeDirectory() + "/.claude/settings.json"),
              let s = String(data: d, encoding: .utf8) else { return true }
        return HookSettings.mentioned(in: s)
    }

    func installHooks() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.cliPath())
        p.arguments = ["hooks", "install"]
        try? p.run()
        p.waitUntilExit()
        model.hooksInstalled = Self.hooksInstalled()
    }

    func paletteEntries() -> [PaletteModel.Entry] {
        var out: [PaletteModel.Entry] = engine.items.map { item in
            let unseen = engine.attention.unseen.contains(item.id)
            var sub = [item.appName]
            if !item.detail.isEmpty { sub.append(item.detail) }
            if item.workspace > 0 { sub.append("workspace \(item.workspace)") }
            let badge = unseen ? "done" : item.activity == .working ? "working" : ""
            return .init(id: item.id, title: item.label, subtitle: sub.joined(separator: " · "), bundleID: item.bundleID,
                         symbol: nil, badge: badge) { [weak self] in self?.focus(item) }
        }
        // Finished turns first, then busy ones: that's usually where you're headed.
        func rank(_ e: PaletteModel.Entry) -> Int { e.badge == "done" ? 0 : e.badge == "working" ? 1 : 2 }
        out = out.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        let cmds: [(String, String, () -> Void)] = [
            ("New Claude session", "sparkle", { [weak self] in self?.newClaude() }),
            ("New terminal", "plus", { [weak self] in self?.engine.newTerminal(in: nil) }),
            ("Tile windows", "square.grid.2x2", { [weak self] in self?.tile() }),
            ("Layout: Stack", "square.stack", { [weak self] in self?.setLayout(.stack) }),
            ("Layout: Split", "rectangle.split.2x1", { [weak self] in self?.setLayout(.split) }),
            ("Layout: Free", "macwindow.on.rectangle", { [weak self] in self?.setLayout(.free) }),
            (visibility.pinned ? "Unpin sidebar" : "Pin sidebar", "pin", { [weak self] in guard let self else { return }; self.send(.pin(!self.visibility.pinned)) }),
        ]
        out += cmds.map { c in .init(id: "cmd:" + c.0, title: c.0, subtitle: "Command", bundleID: nil, symbol: c.1, badge: "", run: c.2) }
        return out
    }

    // MARK: socket

    func handle(_ r: Wire.Request) -> Wire.Reply {
        switch r.op {
        case .ping:
            var info = engine.statusInfo
            info["version"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
            return .init(ok: true, info: info)
        case .list:
            return .init(ok: true, items: engine.items)
        case .event:
            guard let e = r.event else { return .init(ok: false, error: "no event") }
            engine.apply(e)
            return .init(ok: true)
        case .notify:
            guard let e = r.event else { return .init(ok: false, error: "no event") }
            guard let item = engine.notify(e) else { return .init(ok: false, error: "couldn't tell which row this terminal is") }
            return .init(ok: true, info: ["id": item.id, "label": item.label])
        case .focus:
            guard let q = r.target, let item = engine.find(q) else { return .init(ok: false, error: "nothing matches") }
            focus(item)
            return .init(ok: true, info: ["id": item.id, "label": item.label])
        case .open:
            guard let s = r.target, let url = URL(string: s), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
                return .init(ok: false, error: "only http and https URLs")
            }
            NSWorkspace.shared.open(url)
            return .init(ok: true)
        case .send:
            guard let q = r.target, let item = engine.find(q) else { return .init(ok: false, error: "nothing matches") }
            guard engine.send(item, r.text ?? "") else { return .init(ok: false, error: "\(item.label) isn't a Ghostty terminal") }
            return .init(ok: true, info: ["id": item.id, "label": item.label])
        case .tile: tile(); return .init(ok: true)
        case .layout:
            guard let l = Deck.Layout(rawValue: r.text ?? "") else { return .init(ok: false, error: "free, stack or split") }
            setLayout(l)
            return .init(ok: true)
        case .sidebar: send(.toggleKey); return .init(ok: true)
        case .palette: togglePalette(); return .init(ok: true)
        }
    }

    // MARK: menu

    /// The Deck's part of BaneySpaces' menu bar menu.
    func menuItems(target: AnyObject) -> [NSMenuItem] {
        var out: [NSMenuItem] = []
        let unseen = engine.attention.unseen.compactMap { engine.item($0) }
        if !unseen.isEmpty {
            let h = NSMenuItem(title: "Finished While You Were Away", action: nil, keyEquivalent: "")
            h.isEnabled = false
            out.append(h)
            for t in unseen {
                let i = NSMenuItem(title: "  " + t.label, action: #selector(DeckMenuTarget.focusRow(_:)), keyEquivalent: "")
                i.representedObject = t.id
                i.target = menuTarget
                out.append(i)
            }
            out.append(.separator())
        }
        let sub = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void, on: Bool? = nil) {
            let i = NSMenuItem(title: title, action: #selector(DeckMenuTarget.run(_:)), keyEquivalent: "")
            i.representedObject = DeckMenuTarget.Action(action)
            i.target = menuTarget
            if let on { i.state = on ? .on : .off }
            sub.addItem(i)
        }
        add("Go to Anything…  ⌃⌘K", { [weak self] in self?.togglePalette() })
        add("Dock the Sidebar", { [weak self] in guard let self else { return }; self.send(.pin(!self.visibility.pinned)) }, on: visibility.pinned)
        for l in Deck.Layout.allCases {
            add("Layout: \(l.rawValue.capitalized)", { [weak self] in self?.setLayout(l) }, on: layout == l)
        }
        add("Tile Windows", { [weak self] in self?.tile() })
        add("Jump to Finished Agent  ⌃⌘U", { [weak self] in self?.jumpToFinished() })
        if !model.hooksInstalled { add("Install Claude Code and Grok Hooks", { [weak self] in self?.installHooks() }) }
        let deck = NSMenuItem(title: "Deck", action: nil, keyEquivalent: "")
        deck.submenu = sub
        out.append(deck)
        return out
    }

    private lazy var menuTarget = DeckMenuTarget(owner: self)
}

/// Menu items need an Objective-C target; this one forwards to the Deck.
final class DeckMenuTarget: NSObject {
    final class Action { let run: () -> Void; init(_ run: @escaping () -> Void) { self.run = run } }
    weak var owner: DeckController?
    init(owner: DeckController) { self.owner = owner }
    @objc func focusRow(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, let owner, let row = owner.engine.item(id) else { return }
        owner.focus(row)
    }
    @objc func run(_ item: NSMenuItem) { (item.representedObject as? Action)?.run() }
}

/// A small notice in the top-right corner when an agent finishes or needs you while you're looking
/// elsewhere. It never takes focus; a click goes there, and it fades on its own.
final class ToastPanel: NSPanel {
    var onPick: (String) -> Void = { _ in }
    private var hideTimer: Timer?
    private var itemID = ""
    private let text = NSHostingView(rootView: ToastView(title: "", detail: "", bundleID: ""))

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 64), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        title = "BaneySpaces Agent Notice"
        setAccessibilityIdentifier("deck.toast")
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        contentView = SidebarPanel.chrome(text, radius: 12)
    }

    override var canBecomeKey: Bool { false }

    func show(_ item: Item, more: Int, on screen: NSScreen) {
        itemID = item.id
        let what = item.notice.isEmpty ? "finished" : item.notice
        let who = item.agent.isEmpty ? item.appName : item.agent.capitalized
        text.rootView = ToastView(title: "\(who): \(what)", detail: item.label + (more > 0 ? "  +\(more) more" : ""), bundleID: item.bundleID)
        let v = screen.visibleFrame
        setFrame(NSRect(x: v.maxX - 332, y: v.maxY - 76, width: 320, height: 64), display: true)
        alphaValue = 1
        orderFrontRegardless()
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in self?.fade() }
    }

    override func mouseDown(with event: NSEvent) {
        hideTimer?.invalidate()
        orderOut(nil)
        onPick(itemID)
    }

    private func fade() {
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; animator().alphaValue = 0 }, completionHandler: { [weak self] in self?.orderOut(nil) })
    }
}

struct ToastView: View {
    let title: String
    let detail: String
    let bundleID: String
    var body: some View {
        HStack(spacing: 10) {
            if !bundleID.isEmpty { Image(nsImage: Icons.app(bundleID)).resizable().frame(width: 28, height: 28) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text("⌃⌘U").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
