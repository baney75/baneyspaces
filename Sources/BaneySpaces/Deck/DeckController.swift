import AppKit
import BaneySpacesCore
import Carbon.HIToolbox
import SwiftUI

/// What the agent workspace needs from BaneySpaces. The app delegate fills it in.
struct AgentHost {
    var workspace: () -> Int? = { nil }
    var setWorkspace: (Int?) -> Void = { _ in }
    var current: () -> Int = { 1 }
    /// The next window of a process goes to a workspace: `newProcess` when the agent started
    /// that process itself (its windows so far go too), `title` to take only the window of a file.
    var claim: (_ pid: pid_t, _ workspace: Int, _ newProcess: Bool, _ title: String?) -> Void = { _, _, _, _ in }
    var unclaim: (pid_t) -> Void = { _ in }
    var move: (UInt32, Int) -> Void = { _, _ in }
    var windows: () -> [(id: WindowID, app: String, title: String)] = { [] }
}

/// The Deck: the engine behind every terminal split, browser tab and coding agent BaneySpaces
/// knows about. It feeds the launcher's rows, the Workspace Dock's agent badges and the
/// `baneyspaces` command, reads agent state from hooks, and toasts when an agent finishes while
/// you're elsewhere. BaneySpaces' app delegate owns it and starts it once Accessibility is allowed.
final class DeckController {
    let engine = Engine()
    let server = Server()
    let phones = PhoneWatcher()
    let remote = RemoteServer()
    private var remoteRetry: Timer?

    static var remoteEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "remoteEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "remoteEnabled") }
    }
    lazy var toast = ToastPanel()
    /// ⌃⌘U, held while any wrapped app is in front. No app we wrap uses it.
    let deckKeys = ScopedHotkeys(signature: "BSDK")
    /// ⌘⇧U, held only while a terminal is in front.
    let terminalKeys = ScopedHotkeys(signature: "BSTM")
    /// Set by the app delegate: opens the launcher, where the Deck's rows are searched. ⌃⌘K calls it.
    var onSearch: () -> Void = {}
    /// The rows changed, so an open launcher can show them.
    var onItemsChange: () -> Void = {}
    private var lastItems: [Item] = []
    /// Claude Code and Grok report to BaneySpaces (their hooks are installed).
    private(set) var hooksInstalled = true
    /// A new Claude session's pane is on its way.
    private var claudeOpening = false
    var trustTimer: Timer?
    private(set) var started = false

    var agentHost = AgentHost()

    /// Set by the app delegate: the menu bar badge shows how many agents finished unseen.
    var onUnseenChange: (Int) -> Void = { _ in }
    /// Which rows are working, asking or stopped changed, so the Workspace Dock's badges can follow.
    var onWorkingChange: () -> Void = {}
    private var lastWorking: [String: String] = [:]

    /// Agents working, asking, stopped on an error or finished unseen, for the Workspace Dock: each with its window, so the
    /// dock can badge the app it runs in and go straight to it.
    /// Finished ones come in the order ⌘⇧U visits them, so a tile's badge goes to the same one.
    func dockAgents() -> [DockAgent] {
        let unseen = engine.attention.unseen
        let agents = engine.items.compactMap { item -> DockAgent? in
            guard let state = DockAgent.State.of(activity: item.activity, unseen: unseen.contains(item.id), notice: item.notice) else { return nil }
            let name = item.agent.isEmpty ? item.appName : item.agent.prefix(1).uppercased() + item.agent.dropFirst()
            return DockAgent(id: item.id, window: item.windowNumber, workspace: item.workspace, state: state, name: name,
                             task: Activity.label(of: item.title))
        }
        let rank = { (a: DockAgent) in unseen.firstIndex(of: a.id) ?? unseen.count }
        return agents.sorted { rank($0) < rank($1) }
    }

    /// Goes to an agent's own row: its tab or split selected, and a finished one marked seen.
    /// False when the Deck no longer has it.
    func focusAgent(_ id: String) -> Bool {
        guard started, let item = engine.item(id) else { return false }
        focus(item)
        return true
    }

    var unseenCount: Int { engine.attention.unseen.count }

    private var keysAdded = false

    func start(workspaceOf: @escaping (UInt32) -> Int?, currentWorkspace: @escaping () -> Int) {
        guard !started else { return }
        started = true
        engine.workspaceOf = workspaceOf
        engine.currentWorkspace = currentWorkspace
        engine.onUpdate = { [weak self] in self?.engineUpdated() }
        engine.extraItems = { [weak self] in self?.phones.phones.map(\.item) ?? [] }
        phones.onChange = { [weak self] in self?.engine.merge() }
        engine.start()
        phones.start()
        server.handle = { [weak self] in self?.handle($0) ?? Wire.Reply(ok: false) }
        server.start()
        remote.handle = { [weak self] in self?.handle($0) ?? Wire.Reply(ok: false) }
        if Self.remoteEnabled { startRemote() }

        let ctrlCmd = controlKey | cmdKey, cmdShift = cmdKey | shiftKey
        if !keysAdded {
            keysAdded = true
            deckKeys.add(keyCode: kVK_ANSI_U, modifiers: ctrlCmd) { [weak self] in self?.jumpToFinished() }
            terminalKeys.add(keyCode: kVK_ANSI_U, modifiers: cmdShift) { [weak self] in self?.jumpToFinished() }
        }

        toast.onPick = { [weak self] id in if let i = self?.engine.item(id) { self?.focus(i) } }
        if !AX.isTrusted { watchForTrust() }
        hooksInstalled = Self.hooksInstalled()
        appChanged()
    }

    /// Everything off: keys released, panels gone, no reads, no socket. Windows stay where they are.
    func stop() {
        guard started else { return }
        started = false
        deckKeys.deactivate(); terminalKeys.deactivate()
        toast.orderOut(nil)
        trustTimer?.invalidate()
        engine.stop()
        phones.stop()
        server.stop()
        remote.stop()
        remoteRetry?.invalidate()
        lastUnseen = []
        onUnseenChange(0)
    }

    // MARK: engine

    var lastState = ""
    var lastUnseen: [String] = []
    func engineUpdated() {
        guard started else { return }
        let unseen = engine.attention.unseen
        // Newly finished while you're in some other app: say so, once, in a corner.
        let fresh = unseen.filter { !lastUnseen.contains($0) }
        if let id = fresh.first, let item = engine.item(id), wrappedFront == nil || !(item.focused) {
            toast.show(item, more: fresh.count - 1, on: Self.activeScreen())
        }
        if unseen != lastUnseen { onUnseenChange(unseen.count) }
        let working = Dictionary(engine.items.filter { $0.activity == .working || !$0.notice.isEmpty }
            .map { ($0.id, $0.activity == .working ? "" : $0.notice) }) { a, _ in a }
        if working != lastWorking { lastWorking = working; onWorkingChange() }
        lastUnseen = unseen
        if engine.items != lastItems { lastItems = engine.items; onItemsChange() }
        writeState()
    }

    /// What the Deck believes, for checks, agents and bug reports:
    /// ~/Library/Application Support/BaneySpaces/deck.json.
    func writeState() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        struct State: Encodable {
            let trusted: Bool
            let unseen: [String]
            let reads: [String: String]
            let items: [Item]
        }
        let s = State(trusted: AX.isTrusted, unseen: engine.attention.unseen, reads: engine.statusInfo, items: engine.items)
        guard let data = try? enc.encode(s), let text = String(data: data, encoding: .utf8), text != lastState else { return }
        lastState = text
        try? FileManager.default.createDirectory(at: Wire.supportDir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: Wire.statePath), options: .atomic)
    }

    func watchForTrust() {
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] t in
            guard AX.isTrusted else { return }
            t.invalidate()
            self?.engine.retryWatching()
        }
    }

    // MARK: showing and hiding

    var wrappedFront: AppSpec? {
        guard let b = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return nil }
        return engine.specs.first { $0.bundleID == b }
    }

    /// The app delegate calls this when the front app changes.
    func appChanged() {
        guard started else { return }
        let front = wrappedFront
        if front != nil { deckKeys.activate() } else { deckKeys.deactivate() }
        if front?.role == .terminal { terminalKeys.activate() } else { terminalKeys.deactivate() }
    }

    // MARK: actions

    /// Goes to a row picked in the launcher, a toast or a dock badge. A phone opens as its app.
    func focus(_ item: Item) {
        if item.kind == .device {
            engine.seen(item.id)
            if let p = phones.phone(item.id) { phones.open(p) }
            return
        }
        engine.focus(item)
    }

    func jumpToFinished() {
        guard let id = engine.attention.unseen.first, let item = engine.item(id) else { NSSound.beep(); return }
        focus(item)
    }

    /// The launcher's "New Claude session": another session tiled into
    /// `claude-desk`'s Claude window, through a script compiled here (`Scripts.claudeDesk`).
    /// Running `claude-desk` itself cost a bash and an `osascript` launch plus a 90 to 150 ms
    /// compile on every press. It stays the fallback when the script never reached Ghostty, and a
    /// plain terminal running `claude` without it. `done` runs once the pane is up or handed off.
    func newClaude(then done: @escaping () -> Void = {}) {
        guard !claudeOpening else { return }
        let desk = NSHomeDirectory() + "/.local/bin/claude-desk"
        guard FileManager.default.isExecutableFile(atPath: desk) else {
            let dir = engine.items.first { $0.focused && !$0.directory.isEmpty }?.directory
            engine.newTerminal(in: dir, command: "claude")
            return done()
        }
        claudeOpening = true
        let finish = { [weak self] in self?.claudeOpening = false; done() }
        guard Automation.allowed(Catalog.known[0].bundleID) else { return runClaudeDesk(desk, then: finish) }
        let script = claudeScript
        script.queue.async { [weak self] in
            let r = script.run("claudeTile", [ClaudeDesk.workDir, ClaudeDesk.paneCommand, ClaudeDesk.read().joined(separator: "\n")])
            if let out = r.out { ClaudeDesk.write(ClaudeDesk.parse(out)) }
            DispatchQueue.main.async {
                // Only a script that never reached Ghostty is tried again through claude-desk; one
                // that failed or timed out partway may already have opened the pane.
                if Self.neverReached.contains(r.error) { self?.runClaudeDesk(desk, then: finish) } else { finish() }
            }
        }
    }

    private lazy var claudeScript = Scripts.claudeDesk()

    /// Errors that mean Ghostty saw nothing: the script didn't compile, Automation isn't allowed,
    /// Ghostty isn't running or its connection was gone.
    static let neverReached: Set<Int> = [OSA.didNotCompile, -1743, -600, -609]

    private func runClaudeDesk(_ path: String, then done: @escaping () -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.terminationHandler = { _ in DispatchQueue.main.async(execute: done) }
        do { try p.run() } catch { done() }
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
        hooksInstalled = Self.hooksInstalled()
    }

    /// Rows for BaneySpaces' launcher (⌘Space, ⌃⌘K), so one search finds apps, splits, tabs and agents.
    func launcherItems(_ q: String) -> [LauncherItem] {
        guard started else { return [] }
        let unseen = engine.attention.unseen
        let rows = q.isEmpty
            ? unseen.compactMap { engine.item($0) }
            : DeckRank.rank(q, engine.items) { [$0.label, "\($0.appName) \($0.label)", $0.detail] }
        return rows.map { item in
            let done = unseen.contains(item.id)
            var sub = [item.appName]
            if !item.notice.isEmpty { sub.append(item.notice) } else if !item.detail.isEmpty { sub.append(item.detail) }
            return LauncherItem(id: "deck:" + item.id, section: done ? "Needs You" : "Terminals, Tabs and Agents",
                                title: item.label, subtitle: sub.joined(separator: " · "), icon: .file(Self.appPath(item.bundleID)),
                                badge: done ? "Done" : item.activity == .working ? "Working" : "",
                                workspaces: item.workspace > 0 ? [item.workspace] : [],
                                run: { [weak self] in self?.focus(item) })
        }
    }

    /// The screen showing the front app's focused window, else the main one: where the toast appears.
    static func activeScreen() -> NSScreen {
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let w: AXUIElement = AX.app(pid, timeout: 0.1).value(kAXFocusedWindowAttribute), let f = w.frame {
            let center = CGPoint(x: f.midX, y: f.midY)
            if let s = NSScreen.screens.first(where: { AX.flip($0.frame).contains(center) }) { return s }
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    private static var appPaths: [String: String] = [:]
    static func appPath(_ bundleID: String) -> String {
        if let p = appPaths[bundleID] { return p }
        let p = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path ?? ""
        appPaths[bundleID] = p
        return p
    }

    // MARK: socket

    func handle(_ r: Wire.Request) -> Wire.Reply {
        guard started else { return .init(ok: false, error: "the Deck hasn't started") }
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
        case .agent: return agent(r.text ?? "status", r.args ?? [])
        case .remote:
            switch r.text ?? "status" {
            case "on":
                Self.remoteEnabled = true
                startRemote()
            case "off":
                Self.remoteEnabled = false
                remoteRetry?.invalidate()
                remote.stop()
            case "token":
                return .init(ok: true, info: ["token": RemoteServer.token()])
            default: break
            }
            var info = ["remote": Self.remoteEnabled ? "on" : "off"]
            if let a = remote.address { info["listening"] = "\(a):\(Remote.port)" }
            else if Self.remoteEnabled { info["listening"] = "waiting for Tailscale" }
            return .init(ok: true, info: info)
        }
    }

    /// Listens for your other machines. Every 30 seconds it checks the tailnet address: it starts
    /// once Tailscale is up, and moves when the address changes.
    private func startRemote() {
        _ = RemoteServer.token()
        _ = remote.start()
        remoteRetry?.invalidate()
        remoteRetry = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] t in
            guard let self, Self.remoteEnabled, self.started else { return t.invalidate() }
            if self.remote.address != RemoteServer.tailnetAddress() { self.remote.stop() }
            _ = self.remote.start()
        }
    }

    // MARK: agent workspace

    /// `baneyspaces agent …`: work for agents on a workspace you aren't looking at.
    func agent(_ sub: String, _ args: [String]) -> Wire.Reply {
        let h = agentHost
        switch sub {
        case "on":
            let n = args.first.flatMap(Int.init) ?? h.workspace() ?? 9
            guard Workspaces.range.contains(n) else { return .init(ok: false, error: "pick a workspace from 1 to 9") }
            h.setWorkspace(n)
            return agentStatus()
        case "off":
            h.setWorkspace(nil)
            return .init(ok: true, info: ["workspace": "off"])
        case "status":
            return agentStatus()
        case "open":
            guard let n = h.workspace() else { return .init(ok: false, error: "the agent workspace is off: baneyspaces agent on") }
            guard let name = args.first, let url = Self.appURL(name) else { return .init(ok: false, error: "no app called \(args.first ?? "")") }
            let appName = url.deletingPathExtension().lastPathComponent
            let bundle = Bundle(url: url)?.bundleIdentifier
            let files = args.dropFirst().map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            let running = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundle && bundle != nil }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            cfg.addsToRecentItems = false
            if let file = files.first {
                // The file's window, recognized by its name, goes there; nothing else of the app.
                let title = file.lastPathComponent
                if let running { h.claim(running.processIdentifier, n, false, title) }
                NSWorkspace.shared.open(files, withApplicationAt: url, configuration: cfg) { app, _ in
                    guard let app, running == nil else { return }
                    DispatchQueue.main.async { h.claim(app.processIdentifier, n, false, title) }
                }
                return .init(ok: true, info: ["workspace": "\(n)", "app": appName, "files": "\(files.count)"])
            }
            /// A new window from behind through the app's own New Window command, claimed first.
            func newWindow(_ app: NSRunningApplication) -> Bool {
                h.claim(app.processIdentifier, n, false, nil)
                guard let item = Windows.newWindowItem(app.processIdentifier),
                      AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
                    h.unclaim(app.processIdentifier)
                    return false
                }
                return true
            }
            if let running {
                guard newWindow(running) else {
                    return .init(ok: false, error: "\(running.localizedName ?? name) has no New Window command it would run from behind")
                }
                return .init(ok: true, info: ["workspace": "\(n)", "app": appName])
            }
            // Not running: start it from behind. Whatever it restores is yours and stays put;
            // once it's up, a new window of its own goes to the agent workspace.
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { app, _ in
                guard let app else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { _ = newWindow(app) }
            }
            return .init(ok: true, info: ["workspace": "\(n)", "app": appName, "note": "starting; its window opens there in a moment"])
        case "run":
            guard let n = h.workspace() else { return .init(ok: false, error: "the agent workspace is off: baneyspaces agent on") }
            let cmd = args.drop { $0 != "--" }.dropFirst().joined(separator: " ")
            guard !cmd.isEmpty else { return .init(ok: false, error: "usage: baneyspaces agent run [--dir DIR] -- <command>") }
            let dir = args.firstIndex(of: "--dir").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            guard engine.newAgentTerminal(in: dir, command: cmd, opened: { pid, name in h.claim(pid, n, false, name) }) else {
                return .init(ok: false, error: "couldn't start a terminal for it")
            }
            return .init(ok: true, info: ["workspace": "\(n)", "command": cmd])
        case "move":
            guard let n = h.workspace() else { return .init(ok: false, error: "the agent workspace is off: baneyspaces agent on") }
            // A window number (what cua-driver and `agent status` show), or a row by ID or words.
            if args.count == 1, let id = UInt32(args[0]) {
                h.move(id, n)
                return .init(ok: true, info: ["workspace": "\(n)", "moved": "window \(id)"])
            }
            guard let q = args.first, let item = engine.find(args.joined(separator: " ")) ?? engine.find(q), item.windowNumber != 0 else {
                return .init(ok: false, error: "nothing matches")
            }
            h.move(item.windowNumber, n)
            return .init(ok: true, info: ["workspace": "\(n)", "moved": item.label])
        default:
            return .init(ok: false, error: "usage: baneyspaces agent status|on [N]|off|open <app> [file…]|run [--dir D] -- <cmd>|move <row>")
        }
    }

    func agentStatus() -> Wire.Reply {
        guard let n = agentHost.workspace() else { return .init(ok: true, info: ["workspace": "off"]) }
        var info = ["workspace": "\(n)", "current": "\(agentHost.current())"]
        for (i, w) in agentHost.windows().enumerated() { info["window.\(i)"] = "\(w.id)\t\(w.app)\t\(w.title)" }
        return .init(ok: true, items: engine.items.filter { $0.workspace == n }, info: info)
    }

    /// An app by bundle ID, path, or name ("Helium", "helium").
    static func appURL(_ name: String) -> URL? {
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) { return u }
        if name.hasSuffix(".app"), FileManager.default.fileExists(atPath: name) { return URL(fileURLWithPath: name) }
        let dirs = ["/Applications", NSHomeDirectory() + "/Applications", "/System/Applications", "/System/Applications/Utilities"]
        for d in dirs {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: d) else { continue }
            if let hit = names.first(where: { $0.lowercased() == name.lowercased() + ".app" }) { return URL(fileURLWithPath: d).appendingPathComponent(hit) }
        }
        return nil
    }

    // MARK: menu

    /// The Deck's part of BaneySpaces' menu bar menu: agents that finished while you were away.
    func menuItems() -> [NSMenuItem] {
        var out: [NSMenuItem] = []
        let unseen = engine.attention.unseen.compactMap { engine.item($0) }
        if !unseen.isEmpty {
            out.append(.separator())
            let h = NSMenuItem(title: "Finished While You Were Away", action: nil, keyEquivalent: "")
            h.isEnabled = false
            out.append(h)
            for t in unseen {
                let i = NSMenuItem(title: t.label, action: #selector(DeckMenuTarget.focusRow(_:)), keyEquivalent: "")
                i.indentationLevel = 1
                i.representedObject = t.id
                i.target = menuTarget
                out.append(i)
            }
        }
        return out
    }

    private lazy var menuTarget = DeckMenuTarget(owner: self)
}

/// Menu items need an Objective-C target; this one forwards to the Deck.
final class DeckMenuTarget: NSObject {
    weak var owner: DeckController?
    init(owner: DeckController) { self.owner = owner }
    @objc func focusRow(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, let owner, let row = owner.engine.item(id) else { return }
        owner.focus(row)
    }
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
        contentView = Self.chrome(text, radius: 12)
    }

    override var canBecomeKey: Bool { false }

    /// A blurred rounded card hosting `content`.
    private static func chrome(_ content: NSView, radius: CGFloat) -> NSView {
        let root = NSView()
        let blur = NSVisualEffectView()
        blur.material = .sidebar
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = radius
        blur.layer?.masksToBounds = true
        for (child, parent) in [(blur, root), (content, blur)] {
            child.translatesAutoresizingMaskIntoConstraints = false
            parent.addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
                child.topAnchor.constraint(equalTo: parent.topAnchor),
                child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            ])
        }
        return root
    }

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

enum Icons {
    private static var cache: [String: NSImage] = [:]
    static func app(_ bundleID: String) -> NSImage {
        if let i = cache[bundleID] { return i }
        let img: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            img = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            img = NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        }
        img.size = NSSize(width: 32, height: 32)
        cache[bundleID] = img
        return img
    }
}
