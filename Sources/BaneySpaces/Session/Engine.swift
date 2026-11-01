import AppKit
import BaneySpacesCore

/// Knows every wrapped app and what's in it. Accessibility notifications and hook events trigger
/// a refresh of just the app that changed; a slow sweep catches what macOS doesn't announce
/// (a Claude turn ending in a background Ghostty tab, when no hook reports it).
final class Engine {
    struct Tracked {
        let spec: AppSpec
        let app: NSRunningApplication
        var items: [Item] = []
        var windows: [NativeWindow] = []
        var ghostty: Snapshot?
        var scripted: ScriptedSnapshot?
        /// When each snapshot last answered (`Sweep.snapshotToShow` won't show an old one).
        var ghosttyAt = Date.distantPast.timeIntervalSinceReferenceDate
        var scriptedAt = Date.distantPast.timeIntervalSinceReferenceDate
        var refreshing = false
        var dirty = false
        var last = Date.distantPast
        var ms = 0
        /// Script reads since launch, for `session.json`: how often the engine wakes this app.
        var reads = 0
        /// When a script was last sent to it, answered or not, and whether it answered (`Sweep`).
        /// A refusal (no Automation permission) isn't a try: the next read asks again.
        var scriptTriedAt = Date.distantPast
        var lastScriptOK = true
    }

    private(set) var specs: [AppSpec] = []
    private(set) var tracked: [pid_t: Tracked] = [:]
    private(set) var items: [Item] = []
    private(set) var attention = Attention()
    private(set) var sessions = AgentSessions()
    /// BaneySpaces' answer to "which workspace is this window on", and which one is showing.
    var workspaceOf: (UInt32) -> Int? = { _ in nil }
    var currentWorkspace: () -> Int = { 1 }
    /// Rows that don't come from an app's windows: phones.
    var extraItems: () -> [Item] = { [] }
    private(set) var defaultBrowser: String?
    let watcher = Watcher()
    private var scripts: [String: OSA] = [:]
    private var sweep: Timer?
    /// Rows a hook or `notify` attached a message to.
    private var notices: [String: String] = [:]
    private var answered = AnsweredQuestions()
    private var idleTitles = IdleTitles()
    private var shownSessions = ShownSessions()

    /// Called on the main thread after every merge.
    var onUpdate: () -> Void = {}
    /// A wrapped window appeared, so the layout may need to place it.
    var onNewWindow: (pid_t) -> Void = { _ in }

    // MARK: lifecycle

    private var observers: [NSObjectProtocol] = []
    private(set) var running = false

    func start() {
        guard !running else { return }
        running = true
        defaultBrowser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
            .flatMap { Bundle(url: $0)?.bundleIdentifier }
        let config = Config.load()
        specs = Catalog.wrapped(defaultBrowser: defaultBrowser, extra: config.extra, excluded: config.excluded)
        watcher.onChange = { [weak self] pid, change, element in self?.changed(pid, change, element) }
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.syncApps() })
        }
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                // Activation changes which row is focused in the app losing focus too.
                if self.tracked[app.processIdentifier] != nil { self.refresh(app.processIdentifier) }
                for (pid, t) in self.tracked where pid != app.processIdentifier && t.items.contains(where: \.focused) { self.refresh(pid) }
            })
        }
        syncApps()
        scheduleSweep(visible: false)
    }

    /// Everything off: no timer, no observers, no reads. Rows are forgotten.
    func stop() {
        guard running else { return }
        running = false
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        sweep?.invalidate()
        sweep = nil
        for pid in tracked.keys { watcher.unwatch(pid) }
        tracked.removeAll()
        items.removeAll()
    }

    /// Starts tracking wrapped apps that launched, forgets ones that quit.
    func syncApps() {
        guard self.running else { return }
        let running = NSWorkspace.shared.runningApplications
        let wanted = Dictionary(specs.map { ($0.bundleID, $0) }, uniquingKeysWith: { a, _ in a })
        var alive = Set<pid_t>()
        for app in running {
            guard let b = app.bundleIdentifier, let spec = wanted[b], !app.isTerminated else { continue }
            alive.insert(app.processIdentifier)
            if tracked[app.processIdentifier] == nil {
                // A second copy of a scripted app (an agent's own Ghostty): AppleScript would answer
                // for the first copy, listing your terminals twice. Its windows stand in.
                var spec = spec
                let firstCopy = running.filter { $0.bundleIdentifier == b && !$0.isTerminated }
                    .min { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
                if spec.adapter != .windows, let firstCopy, firstCopy.processIdentifier != app.processIdentifier {
                    spec = AppSpec(bundleID: spec.bundleID, name: spec.name + " (agent)", role: spec.role, adapter: .windows)
                }
                tracked[app.processIdentifier] = Tracked(spec: spec, app: app)
                watcher.watch(app.processIdentifier)
                refresh(app.processIdentifier)
            }
        }
        for pid in tracked.keys where !alive.contains(pid) {
            // A yes from before it quit isn't known to hold for the next launch.
            if let b = tracked[pid]?.spec.bundleID { Automation.forget(b) }
            tracked[pid] = nil
            watcher.unwatch(pid)
        }
        merge()
    }

    /// Re-adds Accessibility observers once the permission arrives.
    func retryWatching() { for pid in tracked.keys where !watcher.watching.contains(pid) { watcher.watch(pid) } ; refreshAll() }

    /// The engine's own timer (see `Sweep`). `visible` is no longer used: what's on screen is
    /// announced through Accessibility, and the launcher reads every app as it opens.
    func scheduleSweep(visible: Bool) {
        guard sweep == nil else { return }
        sweep = Timer.scheduledTimer(withTimeInterval: Sweep.tick, repeats: true) { [weak self] _ in self?.sweepScripted() }
        sweep?.tolerance = Sweep.tick / 2
    }

    /// Scripted apps only: their background tabs change without any window notification.
    private func sweepScripted() {
        let forgot = sessions.expire(now: Date().timeIntervalSince1970)
        // Each app by its own rows: an agent in T3 Code, on a phone or in another terminal app
        // says nothing about this terminal's background tabs.
        let working = Set(items.filter { $0.activity == .working }.map(\.id))
        let now = Date()
        let scripted = tracked.filter { $0.value.spec.adapter != .windows }
            .map { (id: $0.key, role: $0.value.spec.role, lastRead: $0.value.scriptTriedAt.timeIntervalSinceReferenceDate,
                    agentWorking: $0.value.items.contains { working.contains($0.id) }, lastOK: $0.value.lastScriptOK) }
        let due = Sweep.due(scripted, now: now.timeIntervalSinceReferenceDate)
        for pid in due { refresh(pid) }
        // Each read merges; with none, merge anyway so a stale report on an app's window clears.
        if due.isEmpty && (forgot || !sessions.sessions.isEmpty) { merge() }
    }

    func refreshAll() { for pid in tracked.keys { refresh(pid) } }

    /// The status and label each window's title last showed, so a spinner frame (◐ to ◓) isn't news.
    private var titleSeen: [UInt32: String] = [:]

    private func changed(_ pid: pid_t, _ change: Watcher.Change, _ element: AXUIElement) {
        if change == .frame { return }
        if change == .title {
            let title = element.string(kAXTitleAttribute) ?? ""
            let key = "\(Activity.of(title: title)) \(Activity.label(of: title))"
            let n = element.windowNumber
            if n != 0, titleSeen[n] == key { return }
            if n != 0 { titleSeen[n] = key }
        }
        if change == .windows { onNewWindow(pid) }
        refresh(pid)
    }

    // MARK: reading

    func script(for spec: AppSpec) -> OSA? {
        if let s = scripts[spec.bundleID] { return s }
        let s: OSA?
        switch spec.adapter {
        case .ghostty: s = Scripts.ghostty()
        case .chromium: s = Scripts.chromium(spec.bundleID)
        case .terminalApp: s = Scripts.terminalApp()
        case .iterm: s = Scripts.iterm()
        case .windows: s = nil
        }
        scripts[spec.bundleID] = s
        return s
    }

    /// Reads one app again. Coalesced: a burst of title changes (Claude's spinner retitles several
    /// times a second) becomes one read, and a scripted app is read at most every 250 ms.
    func refresh(_ pid: pid_t) {
        guard running, var t = tracked[pid] else { return }
        if t.refreshing { t.dirty = true; tracked[pid] = t; return }
        let minGap: TimeInterval = t.spec.adapter == .windows ? 0.03 : 0.25
        let wait = minGap - Date().timeIntervalSince(t.last)
        if wait > 0 {
            t.refreshing = true
            tracked[pid] = t
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.tracked[pid]?.refreshing = false
                self?.refresh(pid)
            }
            return
        }
        t.refreshing = true
        t.dirty = false
        tracked[pid] = t
        let spec = t.spec
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        // An app whose last script failed is sent no script until the slow pass, whoever asked: a
        // notification, an activation, this method's own re-run, not just the timer and hooks. Its rows
        // come from the last good snapshot paired with fresh windows.
        let backingOff = Sweep.backingOff(lastTried: t.scriptTriedAt.timeIntervalSinceReferenceDate, lastOK: t.lastScriptOK,
                                          now: Date().timeIntervalSinceReferenceDate)
        let script = spec.adapter == .windows || backingOff ? nil : script(for: spec)
        // The last good snapshots: what the rows keep showing while a script is backing off or failing.
        let lastGhostty = t.ghostty, lastScripted = t.scripted
        let lastGhosttyAt = t.ghosttyAt, lastScriptedAt = t.scriptedAt
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let wins = NativeWindow.list(pid: pid)
            let focusedWin: AXUIElement? = AX.app(pid).value(kAXFocusedWindowAttribute)
            let frontNumber = focusedWin?.windowNumber ?? 0
            var ghostty: Snapshot?
            var scripted: ScriptedSnapshot?
            var items: [Item]
            let native = wins.map { (number: $0.number, title: $0.title) }
            // Scripted only once macOS says yes; until then the app's windows stand in.
            let scriptable = script != nil && Automation.allowed(spec.bundleID)
            var refused = false
            // When the script ran on `OSA.queue`, not when this read began: a backlog there isn't a try.
            var ranAt: Date?
            switch scriptable || backingOff ? spec.adapter : .windows {
            case .ghostty:
                let raw = script.flatMap { s in Self.snapshot(s, spec.bundleID) }
                refused = raw?.refused ?? false
                ranAt = raw?.ranAt
                ghostty = raw?.out.map(Snapshot.parse)
                if let g = Sweep.snapshotToShow(answered: ghostty, last: lastGhostty, lastAt: lastGhosttyAt, now: Date().timeIntervalSinceReferenceDate, backingOff: backingOff, scriptable: scriptable, refused: refused) {
                    items = Build.ghostty(spec, g, numbers: WindowMatch.pair(scripted: g.windowTitles, native: native), front: front)
                } else {
                    items = Build.windows(spec, native, front: front, frontWindowNumber: frontNumber)
                }
            case .chromium, .terminalApp, .iterm:
                let raw = script.flatMap { s in Self.snapshot(s, spec.bundleID) }
                refused = raw?.refused ?? false
                ranAt = raw?.ranAt
                scripted = raw?.out.map(ScriptedSnapshot.parse)
                if let s = Sweep.snapshotToShow(answered: scripted, last: lastScripted, lastAt: lastScriptedAt, now: Date().timeIntervalSinceReferenceDate, backingOff: backingOff, scriptable: scriptable, refused: refused) {
                    let pairs = WindowMatch.pair(scripted: s.windows.map { ($0.id, $0.title) }, native: native)
                    items = Build.scripted(spec, s, numbers: pairs, front: front, frontWindowNumber: frontNumber)
                } else {
                    items = Build.windows(spec, native, front: front, frontWindowNumber: frontNumber)
                }
            case .windows:
                items = Build.windows(spec, native, front: front, frontWindowNumber: frontNumber)
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            DispatchQueue.main.async { [weak self] in
                guard let self, var t = self.tracked[pid] else { return }
                t.items = items
                t.windows = wins
                let answeredAt = (ranAt ?? started).timeIntervalSinceReferenceDate
                if let ghostty { t.ghostty = ghostty; t.ghosttyAt = answeredAt }
                if let scripted { t.scripted = scripted; t.scriptedAt = answeredAt }
                if scriptable && !refused {
                    t.reads += 1
                    t.scriptTriedAt = ranAt ?? started
                    t.lastScriptOK = ghostty != nil || scripted != nil
                }
                t.refreshing = false
                t.last = Date()
                t.ms = ms
                let again = t.dirty
                self.tracked[pid] = t
                self.merge()
                if again { self.refresh(pid) }
            }
        }
    }

    /// An app's snapshot script. Refused by macOS (-1743) or waiting on the person to answer
    /// (-1744): Automation's remembered yes is dropped, so the next read asks again.
    /// `ranAt` is when `Sweep` counts the try from: the script's start on `OSA.queue` if it answered,
    /// its end if it failed (see `Sweep.triedAt`).
    private static func snapshot(_ s: OSA, _ bundleID: String) -> (out: String?, refused: Bool, ranAt: Date) {
        var ranAt = Date()
        let r = OSA.queue.sync { () -> (out: String?, error: Int) in
            ranAt = Date()
            return s.run("snapshot")
        }
        let refused = r.error == -1743 || r.error == -1744
        if refused { Automation.forget(bundleID) }
        return (r.error == 0 ? r.out : nil, refused, Sweep.triedAt(started: ranAt, finished: Date(), ok: r.error == 0))
    }

    // MARK: merging

    /// Every app's rows in one list (terminals, then agents, browser, other apps), with hook state
    /// and the "finished while you were away" list applied.
    func merge() {
        let current = currentWorkspace()
        let order = Role.allCases
        var all: [Item] = []
        let ordered = tracked.values.sorted {
            let a = order.firstIndex(of: $0.spec.role)!, b = order.firstIndex(of: $1.spec.role)!
            return a != b ? a < b : $0.spec.name < $1.spec.name
        }
        for t in ordered {
            let hidden = t.app.isHidden
            let offscreen = Set(t.windows.filter { !$0.onScreen && !$0.minimized }.map(\.number))
            for var item in t.items {
                if let n = workspaceOf(item.windowNumber), n != current { item.workspace = n }
                else if hidden || offscreen.contains(item.windowNumber) { item.workspace = -1 }
                all.append(item)
            }
        }
        all += extraItems()
        let now = Date().timeIntervalSince1970
        idleTitles.update(all, now: now)
        let bound = sessions.resolve(all, now: now)
        for i in all.indices {
            if let e = bound[all[i].id] {
                all[i].activity = AgentSessions.activity(all[i], e, now: now, idleSince: idleTitles.since(all[i].id))
                all[i].agent = e.agent
                all[i].notice = answered.notice(for: all[i].id, e, focused: all[i].focused && !sessions.followed.contains(all[i].id))
            }
            if let n = notices[all[i].id] { all[i].notice = n }
        }
        answered.keep(Set(bound.keys))
        let focused = all.first { $0.focused }?.id
        let forAttention = all.map { r in
            (r.id, shownSessions.attention(r.id, bound[r.id], AgentSessions.forAttention(r.activity, bound[r.id])))
        }
        shownSessions.keep(Set(bound.keys))
        attention.update(forAttention, focused: focused)
        notices = notices.filter { k, _ in attention.unseen.contains(k) }
        if items != all { items = all }
        onUpdate()
    }

    // MARK: agents

    func apply(_ e: AgentEvent) {
        sessions.apply(e, receivedAt: Date().timeIntervalSince1970)
        merge()
        // A hook usually means the title changed too: read the app it came from now, and again once
        // the title has caught up, which is when an unbound session gets narrowed to its terminal.
        let apps = tracked.filter { $0.value.spec.adapter != .windows }
            .map { (id: $0.key, bundleID: $0.value.spec.bundleID, role: $0.value.spec.role,
                    byTTY: $0.value.spec.adapter == .terminalApp || $0.value.spec.adapter == .iterm, ttys: Set($0.value.items.map(\.tty).filter { !$0.isEmpty })) }
        // An app whose script keeps failing waits out its backoff here too.
        let now = Date().timeIntervalSinceReferenceDate
        let read = Sweep.forHook(apps, eventApp: e.app, tty: e.tty).filter { pid in
            tracked[pid].map { !Sweep.backingOff(lastTried: $0.scriptTriedAt.timeIntervalSinceReferenceDate, lastOK: $0.lastScriptOK, now: now) } ?? false
        }
        guard !read.isEmpty else { return }
        for pid in read { refresh(pid) }
        DispatchQueue.main.asyncAfter(deadline: .now() + AgentSessions.settle + 0.15) { [weak self] in
            for pid in read { self?.refresh(pid) }
        }
    }

    /// `baneyspaces notify`: light up the row the command ran in.
    func notify(_ e: AgentEvent) -> Item? {
        // A session already bound to a row and run from this terminal (same tty, or same app and
        // folder) says which row it is; else the one row whose tty or folder matches exactly.
        // Nothing else: lighting up a guess would send you to the wrong terminal.
        let bound = sessions.binding.first { key, itemID in
            guard let s = sessions.sessions[key], item(itemID) != nil else { return false }
            if !e.tty.isEmpty { return s.tty == e.tty }
            return !e.app.isEmpty && s.app == e.app && !e.cwd.isEmpty && s.cwd == e.cwd
        }?.value
        let exact = items.filter { $0.kind == .terminal && (e.app.isEmpty || $0.bundleID == e.app) && AgentSessions.exact($0, e) }
        guard let id = bound ?? (exact.count == 1 ? exact[0].id : nil) else { return nil }
        attention.flag(id)
        if !e.message.isEmpty { notices[id] = e.message }
        merge()
        return items.first { $0.id == id }
    }

    func seen(_ id: String) { attention.seen(id); notices[id] = nil }

    // MARK: finding

    func item(_ id: String) -> Item? { items.first { $0.id == id } }

    /// An item by exact ID, else the best fuzzy match on its label, app and folder or host.
    func find(_ query: String) -> Item? {
        if let exact = item(query) { return exact }
        return SessionRank.rank(query, items) { [$0.label, "\($0.appName) \($0.label)", $0.detail] }.first
    }

    /// The copy of the app the row came from: two Ghostty processes share a bundle ID.
    func trackedApp(for item: Item) -> Tracked? {
        tracked.values.first { $0.items.contains { $0.id == item.id } } ?? tracked.values.first { $0.spec.bundleID == item.bundleID }
    }

    func nativeWindow(for item: Item) -> NativeWindow? {
        guard let t = trackedApp(for: item) else { return nil }
        return t.windows.first { $0.number == item.windowNumber && item.windowNumber != 0 }
    }

    // MARK: acting

    private var focusToken = 0

    /// Brings `item` forward. The window comes up right away through Accessibility; the tab or
    /// split inside it is selected through the app's script just after. A newer request wins.
    func focus(_ item: Item) {
        seen(item.id)
        guard let t = trackedApp(for: item) else { return }
        if let w = nativeWindow(for: item) {
            w.ax.raise()
            AXUIElementSetAttributeValue(w.ax, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        t.app.activate()
        focusToken += 1
        let token = focusToken
        // A tab or split selected after you've moved on would pull the app forward over your new
        // workspace: dropped if the workspace changed or it waited too long behind other scripts.
        let ws = currentWorkspace()
        let deadline = Date().addingTimeInterval(1.5)
        guard let script = script(for: t.spec), Automation.allowed(t.spec.bundleID) else { merge(); return }
        let parts = item.id.split(separator: ":", maxSplits: 3).map(String.init)
        let ref = t.scripted?.tabs.first { parts.count == 4 && $0.windowID == parts[2] && $0.id == parts[3] }
        OSA.queue.async { [weak self] in
            guard Date() < deadline,
                  DispatchQueue.main.sync(execute: { self?.focusToken == token && self?.currentWorkspace() == ws }) else { return }
            switch t.spec.adapter {
            case .ghostty: _ = script.call("focusTerm", [String(item.id.dropFirst("ghostty:".count))])
            case .chromium, .terminalApp: if let ref { _ = script.call("focusTab", [ref.windowID, String(ref.index)]) }
            case .iterm: if let ref { _ = script.call("focusTab", [ref.windowID, String(ref.index), ref.id]) }
            case .windows: break
            }
        }
        merge()
    }

    enum CloseWhat: String { case terminal, tab, window }

    func close(_ item: Item, _ what: CloseWhat) {
        guard let t = trackedApp(for: item) else { return }
        let script = Automation.allowed(t.spec.bundleID) ? script(for: t.spec) : nil
        let parts = item.id.split(separator: ":", maxSplits: 3).map(String.init)
        let ref = t.scripted?.tabs.first { parts.count == 4 && $0.windowID == parts[2] && $0.id == parts[3] }
        if t.spec.adapter == .ghostty, let script {
            OSA.queue.async { _ = script.call("closeTerm", [String(item.id.dropFirst("ghostty:".count)), what.rawValue]) }
        } else if t.spec.adapter == .chromium, what == .tab, let ref, let script {
            OSA.queue.async { _ = script.call("closeTab", [ref.windowID, String(ref.index)]) }
        } else if let w = nativeWindow(for: item), let button: AXUIElement = w.ax.value(kAXCloseButtonAttribute) {
            // Pressing the window's own close button, so the app asks first if it would lose something.
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
    }

    /// Types `text` into a Ghostty terminal as if pasted. Other terminals don't offer this.
    func send(_ item: Item, _ text: String) -> Bool {
        guard item.id.hasPrefix("ghostty:"), let t = trackedApp(for: item), Automation.allowed(t.spec.bundleID),
              let script = script(for: t.spec) else { return false }
        OSA.queue.async { _ = script.call("sendText", [String(item.id.dropFirst("ghostty:".count)), text]) }
        return true
    }

    /// A terminal for agent work, opened from behind in Terminal, not your Ghostty. Every way of
    /// getting a Ghostty window without bringing Ghostty forward failed on 2026-10-14: scripting
    /// your Ghostty to open one froze all its terminals for seven minutes (AppKit folding the new
    /// window into its tab group), a second Ghostty started with `-e` shows "Allow Ghostty to
    /// execute?" in the middle of your screen every time, and one started without `-e` opens no
    /// window until it's brought forward. Terminal runs a `.command` script from behind with no
    /// prompt, in a process that can't stall your terminals. `opened` gets Terminal's pid and the
    /// script's name, which its window carries in its title, to claim it.
    func newAgentTerminal(in dir: String?, command: String, opened: @escaping (pid_t, String) -> Void) -> Bool {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: TerminalChoice.terminal) else { return false }
        let folder = Wire.supportDir.appendingPathComponent("agent-runs")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = "agent-\(UUID().uuidString.prefix(8).lowercased()).command"
        let script = folder.appendingPathComponent(name)
        let cd = dir.map { "cd '\($0.replacingOccurrences(of: "'", with: "'\\''"))' || exit 1\n" } ?? "cd ~\n"
        // A login shell, so it gets your PATH; a shell stays open when the command is done.
        let body = "#!/bin/zsh -l\n\(cd)\(command)\nexec \"${SHELL:-/bin/zsh}\" -l\n"
        guard FileManager.default.createFile(atPath: script.path, contents: Data(body.utf8), attributes: [.posixPermissions: 0o700]) else { return false }
        let running = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == TerminalChoice.terminal }
        if let running { opened(running.processIdentifier, name) }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.addsToRecentItems = false
        NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: cfg) { app, _ in
            guard let app, running == nil else { return }
            DispatchQueue.main.async { opened(app.processIdentifier, name) }
        }
        // Terminal has read it by then; the folder doesn't fill up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { try? FileManager.default.removeItem(at: script) }
        return true
    }

    /// A new Ghostty window in `dir`, optionally running `command`.
    func newTerminal(in dir: String?, command: String = "") {
        guard let s = script(for: Catalog.known[0]) else { return }
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.mitchellh.ghostty" }) {
            OSA.queue.async { _ = s.call("newWindow", [dir ?? "", command]) }
        } else {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty")
            if let url { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
        }
    }

    var statusInfo: [String: String] {
        var info: [String: String] = [:]
        for t in tracked.values { info["read.\(t.spec.name)"] = "\(t.ms) ms, \(t.items.count) rows, \(t.reads) reads" }
        info["sessions"] = "\(sessions.sessions.count) agent sessions"
        info["accessibility"] = AX.isTrusted ? "allowed" : "not allowed"
        info["browser"] = defaultBrowser ?? "unknown"
        info["workspace"] = "\(currentWorkspace())"
        return info
    }
}

/// `~/.config/baneyspaces/session.json`: more apps to wrap, apps to leave out.
///
///     { "apps": [{ "bundleID": "com.example.App", "name": "Example", "role": "agent" }],
///       "exclude": ["com.apple.Safari"] }
struct Config {
    var extra: [AppSpec] = []
    var excluded: Set<String> = []

    static var url: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/baneyspaces/session.json") }

    static func load() -> Config {
        guard let d = FileManager.default.contents(atPath: url.path),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return Config() }
        var c = Config()
        for a in obj["apps"] as? [[String: Any]] ?? [] {
            guard let b = a["bundleID"] as? String else { continue }
            let known = Catalog.known.first { $0.bundleID == b }
            c.extra.append(AppSpec(bundleID: b, name: a["name"] as? String ?? known?.name ?? b,
                                   role: Role(rawValue: a["role"] as? String ?? "") ?? known?.role ?? .other,
                                   adapter: known?.adapter ?? .windows))
        }
        c.excluded = Set(obj["exclude"] as? [String] ?? [])
        return c
    }
}
