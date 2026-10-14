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
        var refreshing = false
        var dirty = false
        var last = Date.distantPast
        var ms = 0
    }

    private(set) var specs: [AppSpec] = []
    private(set) var tracked: [pid_t: Tracked] = [:]
    private(set) var items: [Item] = []
    private(set) var attention = Attention()
    private(set) var sessions = AgentSessions()
    /// BaneySpaces' answer to "which workspace is this window on", and which one is showing.
    var workspaceOf: (UInt32) -> Int? = { _ in nil }
    var currentWorkspace: () -> Int = { 1 }
    private(set) var defaultBrowser: String?
    let watcher = Watcher()
    private var scripts: [String: OSA] = [:]
    private var sweep: Timer?
    /// Rows a hook or `notify` attached a message to.
    private var notices: [String: String] = [:]

    /// Called on the main thread after every merge.
    var onUpdate: () -> Void = {}
    /// A wrapped window appeared, so the layout may need to place it.
    var onNewWindow: (pid_t) -> Void = { _ in }

    // MARK: lifecycle

    func start() {
        defaultBrowser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
            .flatMap { Bundle(url: $0)?.bundleIdentifier }
        let config = Config.load()
        specs = Catalog.wrapped(defaultBrowser: defaultBrowser, extra: config.extra, excluded: config.excluded)
        watcher.onChange = { [weak self] pid, change in self?.changed(pid, change) }
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.syncApps() }
        }
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                // Activation changes which row is focused in the app losing focus too.
                if self.tracked[app.processIdentifier] != nil { self.refresh(app.processIdentifier) }
                for (pid, t) in self.tracked where pid != app.processIdentifier && t.items.contains(where: \.focused) { self.refresh(pid) }
            }
        }
        syncApps()
        scheduleSweep(visible: false)
    }

    /// Starts tracking wrapped apps that launched, forgets ones that quit.
    func syncApps() {
        let running = NSWorkspace.shared.runningApplications
        let wanted = Dictionary(specs.map { ($0.bundleID, $0) }, uniquingKeysWith: { a, _ in a })
        var alive = Set<pid_t>()
        for app in running {
            guard let b = app.bundleIdentifier, let spec = wanted[b], !app.isTerminated else { continue }
            alive.insert(app.processIdentifier)
            if tracked[app.processIdentifier] == nil {
                tracked[app.processIdentifier] = Tracked(spec: spec, app: app)
                watcher.watch(app.processIdentifier)
                refresh(app.processIdentifier)
            }
        }
        for pid in tracked.keys where !alive.contains(pid) {
            tracked[pid] = nil
            watcher.unwatch(pid)
        }
        merge()
    }

    /// Re-adds Accessibility observers once the permission arrives.
    func retryWatching() { for pid in tracked.keys where !watcher.watching.contains(pid) { watcher.watch(pid) } ; refreshAll() }

    func scheduleSweep(visible: Bool) {
        let interval: TimeInterval = visible ? 2 : 5
        guard sweep?.timeInterval != interval else { return }
        sweep?.invalidate()
        sweep = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.sweepScripted() }
        sweep?.tolerance = interval / 4
    }

    /// Scripted apps only: their background tabs change without any window notification.
    private func sweepScripted() {
        sessions.expire(now: Date().timeIntervalSince1970)
        for (pid, t) in tracked where t.spec.adapter != .windows { refresh(pid) }
    }

    func refreshAll() { for pid in tracked.keys { refresh(pid) } }

    private func changed(_ pid: pid_t, _ change: Watcher.Change) {
        if change == .frame { return }
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
        guard var t = tracked[pid] else { return }
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
        let script = spec.adapter == .windows ? nil : script(for: spec)
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
            switch scriptable ? spec.adapter : .windows {
            case .ghostty:
                let raw = script.flatMap { s in OSA.queue.sync { s.call("snapshot") } }
                ghostty = raw.map(Snapshot.parse)
                if let g = ghostty {
                    items = Build.ghostty(spec, g, numbers: WindowMatch.pair(scripted: g.windowTitles, native: native), front: front)
                } else {
                    items = Build.windows(spec, native, front: front, frontWindowNumber: frontNumber)
                }
            case .chromium, .terminalApp, .iterm:
                let raw = script.flatMap { s in OSA.queue.sync { s.call("snapshot") } }
                scripted = raw.map(ScriptedSnapshot.parse)
                if let s = scripted {
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
                if let ghostty { t.ghostty = ghostty }
                if let scripted { t.scripted = scripted }
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
        let bound = sessions.resolve(all, now: Date().timeIntervalSince1970)
        for i in all.indices {
            if let e = bound[all[i].id] {
                all[i].activity = Activity(e.state)
                all[i].agent = e.agent
                all[i].notice = e.state == .waiting ? e.message : ""
            }
            if let n = notices[all[i].id] { all[i].notice = n }
        }
        let focused = all.first { $0.focused }?.id
        attention.update(all.map { ($0.id, $0.activity) }, focused: focused)
        notices = notices.filter { k, _ in attention.unseen.contains(k) }
        if items != all { items = all }
        onUpdate()
    }

    // MARK: agents

    func apply(_ e: AgentEvent) {
        sessions.apply(e)
        merge()
        // A hook usually means the title changed too: read it now, and again once the title has
        // caught up, which is when an unbound session gets narrowed to its terminal.
        for (pid, t) in tracked where t.spec.adapter != .windows { refresh(pid) }
        DispatchQueue.main.asyncAfter(deadline: .now() + AgentSessions.settle + 0.15) { [weak self] in
            guard let self else { return }
            for (pid, t) in self.tracked where t.spec.adapter != .windows { self.refresh(pid) }
        }
    }

    /// `baneyspaces notify`: light up the row the command ran in.
    func notify(_ e: AgentEvent) -> Item? {
        var probe = AgentSessions()
        probe.apply(e)
        let bound = probe.resolve(items)
        guard let id = bound.keys.first ?? items.first(where: { $0.focused })?.id else { return nil }
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
        return DeckRank.rank(query, items) { [$0.label, "\($0.appName) \($0.label)", $0.detail] }.first
    }

    func trackedApp(for item: Item) -> Tracked? { tracked.values.first { $0.spec.bundleID == item.bundleID } }

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
        guard let script = script(for: t.spec), Automation.allowed(t.spec.bundleID) else { merge(); return }
        let parts = item.id.split(separator: ":", maxSplits: 3).map(String.init)
        let ref = t.scripted?.tabs.first { parts.count == 4 && $0.windowID == parts[2] && $0.id == parts[3] }
        OSA.queue.async { [weak self] in
            guard DispatchQueue.main.sync(execute: { self?.focusToken == token }) else { return }
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
        for t in tracked.values { info["read.\(t.spec.name)"] = "\(t.ms) ms, \(t.items.count) rows" }
        info["sessions"] = "\(sessions.sessions.count) agent sessions"
        info["accessibility"] = AX.isTrusted ? "allowed" : "not allowed"
        info["browser"] = defaultBrowser ?? "unknown"
        info["workspace"] = "\(currentWorkspace())"
        return info
    }
}

/// `~/.config/baneyspaces/deck.json`: more apps to wrap, apps to leave out.
///
///     { "apps": [{ "bundleID": "com.example.App", "name": "Example", "role": "agent" }],
///       "exclude": ["com.apple.Safari"] }
struct Config {
    var extra: [AppSpec] = []
    var excluded: Set<String> = []

    static var url: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/baneyspaces/deck.json") }

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
