import AppKit
import ApplicationServices
import BaneySpacesCore
import Carbon.HIToolbox
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let spaces = Spaces()
    /// Terminal splits, browser tabs and agents in one sidebar, plus the `baneyspaces` command.
    private let deck = DeckController()
    private let hotkeys = Hotkeys()
    private let updater = Updater()
    private var statusItem: NSStatusItem!
    private var started = false { didSet { MissionControlKeys.appStarted = started } }
    private var trustTimer: Timer?
    /// While running, checks every 2 s that macOS still trusts BaneySpaces.
    private var watchdog: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private lazy var viewer = ViewerController(spaces: spaces)
    private lazy var dock: WorkspaceDock = {
        let d = WorkspaceDock(spaces: spaces)
        d.onShowOverview = { [weak self] in self?.viewer.open() }
        d.onShowLauncher = { [weak self] in self?.launcher.show() }
        d.onSetEdge = { [weak self] e in self?.setDockEdge(e) }
        d.onTurnOff = { [weak self] in self?.setWorkspaceDock(false) }
        d.onSetAgentStatus = { [weak self] on in self?.setDockAgentStatus(on) }
        d.model.agents = { [weak self] in
            guard let self, self.deck.started else { return [] }
            return self.deck.dockAgents()
        }
        d.model.onFocusAgent = { [weak self] a, n in
            guard let self, !self.deck.focusAgent(a.id) else { return }
            if a.window != 0 { self.spaces.focus(a.window, on: n) } else { self.spaces.switchTo(n, announce: false) }
        }
        return d
    }()
    private lazy var switcher = WorkspaceSwitcher(spaces: spaces)
    /// Carried windows let go over a workspace, each waiting for its drop to settle. Picking
    /// one up again bumps its generation, so its stale move never runs, even one queued.
    private var settling: [WindowID: Timer] = [:]
    private var dropGeneration: [WindowID: Int] = [:]

    /// Cancels the drop waiting for window `id`, or every one.
    private func cancelSettling(_ id: WindowID? = nil) {
        for w in id.map({ [$0] }) ?? Array(Set(settling.keys).union(dropGeneration.keys)) {
            dropGeneration[w, default: 0] += 1
            settling.removeValue(forKey: w)?.invalidate()
        }
    }
    /// A window dragged to the top of the screen opens the overview, in place of Mission Control.
    private lazy var topDrag: TopDragWatcher = {
        let t = TopDragWatcher()
        t.onOpen = { [weak self] grab, p in
            guard let self, self.started else { return false }
            if self.spaces.switching { return nil }
            return self.viewer.openCarrying(grab.window, at: p)
        }
        t.onMove = { [weak self] p in self?.viewer.carryMoved(to: p) }
        // Picking the window up again makes its drop still waiting to settle stale, even one
        // already queued behind a switch. A click anywhere else leaves the drop alone.
        t.onPress = { [weak self] id in
            guard let self, let id else { return }
            self.cancelSettling(id)
        }
        t.onRelease = { [weak self] grab, drop in
            guard let self, let n = self.viewer.endCarrying(), drop else { return }
            // The window server and the app finish their own drop first: the window moves once
            // it has held still for 60 ms (four looks 20 ms apart), no sooner than 0.1 s after
            // the release and no later than 0.5 s.
            let id = grab.window
            self.cancelSettling(id)
            let gen = self.dropGeneration[id, default: 0]
            var last = TopDragWatcher.bounds(of: id)
            var looks = 0, still = 0
            self.settling[id] = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] timer in
                looks += 1
                let now = TopDragWatcher.bounds(of: id)
                still = now == last ? still + 1 : 0
                last = now
                guard (looks >= 5 && still >= 3) || looks >= 25 else { return }
                timer.invalidate()
                guard let self, now != nil, self.dropGeneration[id, default: 0] == gen else { return }
                self.settling[id] = nil
                self.spaces.moveCarried(id, to: n, from: grab.frame) { [weak self] in self?.dropGeneration[id, default: 0] == gen }
            }
        }
        return t
    }()
    private lazy var launcher: LauncherController = {
        var a = LauncherActions()
        a.focusApp = { [weak self] pid, n in self?.spaces.focusApp(pid, on: n) }
        a.openWindowHere = { [weak self] pid in self?.started == true && self?.spaces.openWindowHere(pid) == true }
        a.canOpenWindow = { pid in Windows.newWindowItem(pid) != nil }
        a.current = { [weak self] in self?.spaces.model.current ?? 1 }
        a.switchTo = { [weak self] n in self?.run { $0.switchTo(n) } }
        a.appsOn = { [weak self] n in self?.spaces.apps(on: n) ?? [] }
        a.workspacesByApp = { [weak self] in
            guard let self, self.started else { return [:] }
            self.spaces.refresh()
            var out: [String: [Int]] = [:]
            for n in Workspaces.range {
                for e in self.spaces.entries(on: n) {
                    guard let path = NSRunningApplication(processIdentifier: e.pid)?.bundleURL?.path else { continue }
                    if out[path]?.contains(n) != true { out[path, default: []].append(n) }
                }
            }
            return out
        }
        a.showOverview = { [weak self] in self?.viewer.open() }
        a.deckItems = { [weak self] q in self?.deck.launcherItems(q) ?? [] }
        a.bringBack = { [weak self] in self?.bringBack() }
        a.toggleDock = { [weak self] in self?.toggleWorkspaceDock() }
        a.dockOn = { WorkspaceDock.enabled }
        a.checkForUpdates = { [weak self] in self?.checkForUpdates() }
        a.showSetup = { [weak self] in self?.showSetup() }
        return LauncherController(actions: a)
    }()
    private lazy var missionControlKeys: MissionControlKeys = {
        let keys = MissionControlKeys { [weak self] in self?.viewer.toggle() }
        keys.onCmdTab = { [weak self] forward, isRepeat, time in
            guard let self, self.started, !self.viewer.isOpen else {
                Trace.log("cmdTab ignored started=\(self?.started ?? false) viewerOpen=\(self?.viewer.isOpen ?? false)")
                MissionControlKeys.inGesture = false
                return
            }
            self.switcher.step(forward: forward, isRepeat: isRepeat, at: time)
        }
        keys.onTabUp = { [weak self] in self?.switcher.tabReleased() }
        keys.onCmdReleased = { [weak self] in self?.switcher.commit() }
        keys.onCancel = { [weak self] in self?.switcher.cancel() }
        return keys
    }()
    private lazy var setup: SetupWindowController = {
        let c = SetupWindowController()
        c.model.onModifierChange = { [weak self] _ in self?.registerShortcuts() }
        c.model.onUninstall = { [weak self] in self?.uninstall() }
        c.model.viewerKeysActive = { [weak self] in self?.missionControlKeys.isActive ?? false }
        c.model.onViewerKeysChange = { [weak self] on in
            MissionControlKeys.enabled = on
            guard let self, self.started else { return }
            self.restartKeyWatcher()
        }
        c.model.onWorkspaceDockChange = { [weak self] on in self?.setWorkspaceDock(on) }
        c.model.onTopDragChange = { [weak self] on in self?.setTopDrag(on) }
        c.model.onDockEdgeChange = { [weak self] e in self?.setDockEdge(e) }
        c.model.onDockAgentStatusChange = { [weak self] on in self?.setDockAgentStatus(on) }
        c.model.onDeckChange = { [weak self] on in if DeckController.enabled != on { self?.toggleDeck() } }
        // Every event, not just any: an older install lacks StopFailure, which the red badge needs.
        c.model.hooksInstalled = {
            guard let d = FileManager.default.contents(atPath: NSHomeDirectory() + "/.claude/settings.json") else { return .noClaudeCode }
            guard let settings = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return .unreadable }
            return HookSettings.installed(settings).count == HookSettings.events.count ? .on : .off
        }
        c.model.onInstallHooks = { [weak self] in self?.deck.installHooks() }
        c.model.onDeckEdgeChange = { [weak self] on in self?.deck.setEdgeOpens(on) }
        deck.onEdgeOpensChange = { [weak c] on in c?.model.deckEdge = on }
        c.model.onLauncherChange = { [weak self] on in self?.setLauncherOnCmdSpace(on) }
        c.model.onCmdTabChange = { [weak self] mode in
            MissionControlKeys.cmdTabMode = mode
            guard let self, self.started else { return }
            self.restartKeyWatcher()
        }
        return c
    }()

    /// The key watcher reads its settings when it starts, so a change restarts it.
    private func restartKeyWatcher() {
        missionControlKeys.stop()
        missionControlKeys.start()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        // `BaneySpaces --restore-shortcuts`: the uninstaller's way to turn macOS's screenshot
        // shortcuts back on before the app's settings are deleted.
        if CommandLine.arguments.contains("--restore-shortcuts") {
            SystemShortcuts.restore()
            SystemShortcuts.spotlightQueue.sync { SystemShortcuts.restoreSpotlight() }
            // Still recorded means still off: the uninstaller says so instead of claiming success.
            let left = !(UserDefaults.standard.array(forKey: "freedShortcuts") ?? []).isEmpty || SystemShortcuts.spotlightFreed
            exit(left ? 1 : 0)
        }
        // `BaneySpaces --restore-dock`: the uninstaller's way to put the macOS Dock back if the
        // Workspace Dock had it out of sight.
        if CommandLine.arguments.contains("--restore-dock") {
            SystemDock.restore()
            SystemTopDrag.restore()
            exit(0)
        }
        // `BaneySpaces --check-settings`: opens the settings window on each tab and exits 1 if any
        // comes up empty or taller than the screen. It opened 0×0, invisible, on macOS 27.
        if CommandLine.arguments.contains("--check-settings") {
            // The app's own controller, wired as the app wires it.
            let c = setup
            c.show()
            let screen = NSScreen.main?.visibleFrame.height ?? 800
            var ok = true
            var heights = Set<Int>()
            for t in SettingsTab.allCases {
                c.model.tab = t
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                let f = c.window!.frame
                let fits = f.width >= 400 && f.height >= 200 && f.height <= screen
                print("\(t.rawValue): \(Int(f.width))×\(Int(f.height))\(fits ? "" : "  FAIL")")
                ok = ok && fits
                heights.insert(Int(f.height))
            }
            // Every tab the same height means the window never refit to its tab.
            if heights.count < 2 { print("FAIL: every tab is \(heights.first ?? 0) tall; the window didn't refit"); ok = false }
            exit(ok ? 0 : 1)
        }
        // `BaneySpaces --unregister-login`: the uninstaller's way to take it out of Login Items.
        if CommandLine.arguments.contains("--unregister-login") {
            // Never registered is as good as removed.
            let app = SMAppService.mainApp
            if app.status == .notRegistered || app.status == .notFound { exit(0) }
            exit((try? app.unregister()) != nil ? 0 : 1)
        }
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        spaces.onChange = { [weak self] in
            self?.updateIcon()
            self?.dock.reload()
        }
        for name in [NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didHideApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.spaces.appLeft(app.processIdentifier)
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.switcher.noteActivated(app.processIdentifier)
            guard self.started else { return }
            self.spaces.appActivated(app)
            self.deck.appChanged()
        }
        // Once another app is in front, the viewer and the empty-workspace holder step aside.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self, self.started else { return }
            self.viewer.close()
            self.spaces.dropEmptyHolder()
        }
        // A BaneySpaces window of its own (setup, About) taking the keyboard ends the holder's job too.
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                               object: nil, queue: .main) { [weak self] note in
            guard let self, self.started, let w = note.object as? NSWindow, !(w is KeyablePanel) else { return }
            self.spaces.dropEmptyHolder()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self, self.started else { return }
            self.spaces.screensChanged()
        }
        // `kill`, logout and `launchctl stop` still bring every window back.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
        startWhenTrusted()
        // ⌘Space works with or without Accessibility; Spotlight hands it over first.
        if Launcher.onCmdSpace { setLauncherOnCmdSpace(true) } else { registerShortcuts() }
        updater.onChange = { [weak self] in self?.updateIcon() }
        updater.isBusy = { [weak self] in self?.spaces.switching ?? false }
        updater.start()
        // The first launch walks through setup, and so does any launch without permission (an
        // update that macOS no longer trusts). Otherwise it's one click away in the menu.
        if !UserDefaults.standard.bool(forKey: "setupShown") || !AXIsProcessTrusted()
            || CommandLine.arguments.contains("--setup") {
            UserDefaults.standard.set(true, forKey: "setupShown")
            showSetup()
        }
    }

    /// Opening BaneySpaces again from Finder, Spotlight or Launchpad shows setup.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSetup()
        return false
    }

    @objc private func showSetup() { setup.show() }

    func applicationWillTerminate(_ n: Notification) {
        // The macOS Dock comes back with everything else; the next launch tucks it away again.
        dock.stop(restoreSystemDock: true)
        topDrag.stop()
        if started { spaces.restoreAll() }
        // ⌘Space goes back to Spotlight while BaneySpaces isn't running; the next launch takes it again.
        SystemShortcuts.spotlightQueue.sync { SystemShortcuts.restoreSpotlight() }
        spaces.flushWrites()
    }

    // MARK: Accessibility

    /// Moving other apps' windows needs Accessibility access. Ask once, then wait for it, and for
    /// AeroSpace to quit, since two managers moving the same windows would fight.
    private func startWhenTrusted() {
        if canStart { return start() }
        // Left out of sight by a crash, the macOS Dock comes back while BaneySpaces waits; the
        // Workspace Dock takes over again once it starts. The same goes for the drag to the top.
        SystemDock.restore()
        SystemTopDrag.restore()
        updateIcon()
        trustTimer?.invalidate()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self, self.canStart else { return }
            timer.invalidate()
            self.start()
        }
    }

    private var aeroSpaceRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "bobko.aerospace").isEmpty
    }

    private var canStart: Bool { AXIsProcessTrusted() && !aeroSpaceRunning }

    private func start() {
        // Applies to every Accessibility call, so one frozen app can't stall a switch.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        started = true
        registerShortcuts()
        missionControlKeys.start()
        spaces.start()
        if WorkspaceDock.enabled { dock.start() }
        if TopDragWatcher.enabled { startTopDrag() }
        startDeck()
        updateIcon()
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.stillTrusted() else { return }
            // A key watcher macOS refused earlier gets another chance.
            if (MissionControlKeys.enabled || MissionControlKeys.cmdTabEnabled) && !self.missionControlKeys.isActive { self.missionControlKeys.start() }
        }
    }

    /// True while macOS trusts BaneySpaces. The moment it doesn't (switched off in System
    /// Settings, or an update with a new signature), every shortcut goes back to the other apps,
    /// every hidden window comes back, and setup opens to put it right.
    @discardableResult
    private func stillTrusted() -> Bool {
        guard started else { return false }
        if AXIsProcessTrusted() { return true }
        watchdog?.invalidate()
        missionControlKeys.stop()
        topDrag.stop()
        cancelSettling()
        // Not watching any more, so macOS answers the drag again until BaneySpaces is back.
        SystemTopDrag.restore()
        viewer.close()
        dock.stop(restoreSystemDock: true)
        deck.stop()
        spaces.suspend()
        started = false
        registerShortcuts()
        updateIcon()
        showSetup()
        startWhenTrusted()
        return false
    }

    /// macOS's own top-of-screen drag goes quiet first, so only one view answers the gesture.
    private func startTopDrag() {
        SystemTopDrag.takeOver()
        topDrag.start()
    }

    private func setTopDrag(_ on: Bool) {
        TopDragWatcher.enabled = on
        if on {
            if started { startTopDrag() }
        } else {
            topDrag.stop()
            cancelSettling()
            SystemTopDrag.restore()
        }
    }

    /// The shortcuts are taken only once they work, so the keys keep their usual meaning in other
    /// apps until then. Picking a different modifier in setup re-registers them.
    private func registerShortcuts() {
        hotkeys.removeAll()
        if Launcher.onCmdSpace, !SystemShortcuts.spotlightOwnsCmdSpace {
            hotkeys.register(keyCode: kVK_Space, modifiers: cmdKey) { [weak self] in self?.launcher.toggle() }
        }
        guard started else { return }
        let mods = Modifier.current.carbon
        for (i, code) in Hotkeys.digitKeyCodes.enumerated() {
            let n = i + 1
            hotkeys.register(keyCode: code, modifiers: mods) { [weak self] in
                guard let self, self.stillTrusted() else { return }
                self.spaces.switchTo(n)
            }
            hotkeys.register(keyCode: code, modifiers: mods | shiftKey) { [weak self] in
                guard let self, self.stillTrusted() else { return }
                self.spaces.moveFocused(to: n)
            }
        }
    }

    private func run(_ action: (Spaces) -> Void) {
        guard stillTrusted() else { return NSSound.beep() }
        action(spaces)
    }

    // MARK: Menu bar

    private func updateIcon() {
        let name = started ? "\(spaces.model.current).square.fill" : "exclamationmark.triangle"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: started
            ? "BaneySpaces, workspace \(spaces.model.current)" : "BaneySpaces needs Accessibility access")
        image?.isTemplate = true
        statusItem.button?.image = image
        // Agents that finished while you were elsewhere, counted beside the workspace number.
        let n = started && deck.started ? deck.unseenCount : 0
        statusItem.button?.title = n > 0 ? " \(n)" : ""
        statusItem.button?.imagePosition = .imageLeading
    }

    private func startDeck() {
        guard DeckController.enabled else { return }
        deck.onUnseenChange = { [weak self] _ in self?.updateIcon(); self?.dock.reload() }
        var h = AgentHost()
        h.workspace = { Spaces.agentWorkspace }
        h.setWorkspace = { [weak self] n in Spaces.agentWorkspace = n; self?.run { $0.reapply() } }
        h.current = { [weak self] in self?.spaces.model.current ?? 1 }
        h.claim = { [weak self] pid, n, fresh, title in
            // A process the agent started gets the full 8 s; your running app only 3, so a claim
            // that comes to nothing can't sit waiting for your next window.
            self?.spaces.claimNextWindow(of: pid, for: n, within: fresh ? 8 : 3, newProcess: fresh, title: title)
        }
        h.unclaim = { [weak self] pid in self?.spaces.cancelClaim(of: pid) }
        h.move = { [weak self] id, n in self?.run { $0.move(id, to: n) } }
        h.windows = { [weak self] in self?.spaces.agentWindows() ?? [] }
        deck.agentHost = h
        deck.onWorkingChange = { [weak self] in self?.dock.reload() }
        // A moment after launch: setting up an observer per app costs the main thread a few
        // hundred milliseconds, which would otherwise land on your first workspace switch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.started, DeckController.enabled else { return }
            self.deck.start(workspaceOf: { [weak self] in self?.spaces.model.workspace(of: $0) },
                            currentWorkspace: { [weak self] in self?.spaces.model.current ?? 1 })
        }
    }

    @objc private func toggleDeck() {
        DeckController.enabled.toggle()
        if DeckController.enabled { startDeck() } else { deck.stop() }
        if setup.model.deck != DeckController.enabled { setup.model.deck = DeckController.enabled }
        updateIcon()
        dock.reload()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard started else {
            if aeroSpaceRunning {
                menu.addItem(withTitle: "Waiting for AeroSpace to quit", action: nil, keyEquivalent: "")
            }
            if !AXIsProcessTrusted() {
                menu.addItem(withTitle: "BaneySpaces needs permission to arrange windows", action: nil, keyEquivalent: "")
                menu.addItem(item("Allow BaneySpaces…", #selector(showSetup)))
            } else {
                menu.addItem(item("Settings…", #selector(showSetup)))
            }
            menu.addItem(.separator())
            menu.addItem(item("Quit BaneySpaces", #selector(quit), key: "q"))
            return
        }
        spaces.refresh()
        var apps: [Int: [String]] = [:]
        for n in Workspaces.range { apps[n] = spaces.apps(on: n) }
        for row in MenuLayout.rows(current: spaces.model.current, apps: apps) {
            let it = item(row.title, #selector(pick(_:)), key: "\(row.workspace)")
            it.keyEquivalentModifierMask = Modifier.current.menuFlags
            it.tag = row.workspace
            it.state = row.isCurrent ? .on : .off
            it.toolTip = row.fullList
            menu.addItem(it)
        }
        menu.addItem(.separator())
        let find = item("Find or Install an App…", #selector(showLauncher))
        if Launcher.onCmdSpace { find.keyEquivalent = " "; find.keyEquivalentModifierMask = [.command] }
        menu.addItem(find)
        menu.addItem(item("Show All Workspaces", #selector(showViewer)))
        if deck.started { deck.menuItems().forEach(menu.addItem) }
        menu.addItem(.separator())
        menu.addItem(optionsItem())
        menu.addItem(item("Settings…", #selector(showSetup), key: ","))
        menu.addItem(.separator())
        // A waiting update gets its own line; the rest of updates live in the submenu.
        if let update = updateItem() { menu.addItem(update) }
        menu.addItem(channelItem())
        menu.addItem(item("About BaneySpaces", #selector(about)))
        menu.addItem(item("Quit BaneySpaces", #selector(quit), key: "q"))
    }

    /// The switches and the rarely needed tools, one level down so the menu stays short.
    private func optionsItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Options", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let dockItem = item("Workspace Dock", #selector(toggleWorkspaceDock))
        dockItem.state = WorkspaceDock.enabled ? .on : .off
        dockItem.toolTip = "A dock of your workspaces in place of the macOS Dock. Rest the pointer on the \(WorkspaceDock.edge.title.lowercased()) edge of the screen to show it."
        sub.addItem(dockItem)
        if WorkspaceDock.enabled {
            let pos = NSMenuItem(title: "Dock Position", action: nil, keyEquivalent: "")
            let edges = NSMenu()
            for e in DockEdge.allCases {
                let it = item(e.title, #selector(pickDockEdge(_:)))
                it.representedObject = e.rawValue
                it.state = WorkspaceDock.edge == e ? .on : .off
                edges.addItem(it)
            }
            pos.submenu = edges
            sub.addItem(pos)
            let status = item("Agent Status on the Dock", #selector(toggleDockAgentStatus))
            status.state = WorkspaceDock.agentStatus ? .on : .off
            status.indentationLevel = 1
            status.toolTip = "Badges on app icons: a turning ring while an agent works, a yellow ? when it asks you something, a red ! when it stops on an error, an orange count when it finishes."
            sub.addItem(status)
        }
        let deckItem = item("Terminal and Agent Deck", #selector(toggleDeck))
        deckItem.state = DeckController.enabled ? .on : .off
        deckItem.toolTip = "A sidebar of every terminal, browser tab and coding agent here. Rest the pointer on the left edge in a terminal, browser or agent app, or press ⌃⌘B."
        sub.addItem(deckItem)
        let spaceItem = item("Launcher on ⌘Space", #selector(toggleLauncherKey))
        spaceItem.state = Launcher.onCmdSpace ? .on : .off
        spaceItem.toolTip = "⌘Space opens the BaneySpaces launcher instead of Spotlight. Turning it off gives ⌘Space back to Spotlight."
        sub.addItem(spaceItem)
        sub.addItem(.separator())
        sub.addItem(parkedAppsItem())
        let back = item("Bring Every Window Back", #selector(bringBack))
        back.toolTip = "Gathers every window onto workspace 1, all visible."
        sub.addItem(back)
        sub.addItem(.separator())
        let remove = item("Uninstall BaneySpaces…", #selector(uninstall))
        remove.toolTip = "Puts back your windows, Dock, shortcuts and agent settings, then removes BaneySpaces."
        sub.addItem(remove)
        parent.submenu = sub
        return parent
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        return it
    }

    @objc private func pick(_ sender: NSMenuItem) { spaces.switchTo(sender.tag) }

    /// Apps whose windows are parked instead of hidden, so automation can still use them.
    private func parkedAppsItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Keep Usable by Automation", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let note = NSMenuItem(title: "Checked apps aren't hidden on other workspaces, so tools like Cua can still click and type in them.", action: nil, keyEquivalent: "")
        note.isEnabled = false
        sub.addItem(note)
        sub.addItem(.separator())
        let on = ParkedApps.bundleIDs
        // Apps with windows, plus every app already on the list, so any of them can be unchecked.
        var apps = spaces.appsWithWindows()
        for id in on where !apps.contains(where: { $0.bundleID == id }) {
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
            apps.append((name, id))
        }
        let slow = SlowMovers.bundleIDs
        for app in apps {
            // An app that slides its windows when moved is hidden anyway, so nothing moves on screen.
            let title = on.contains(app.bundleID) && slow.contains(app.bundleID) ? "\(app.name) (hidden: it animates window moves)" : app.name
            let it = item(title, #selector(toggleParked(_:)))
            it.representedObject = app.bundleID
            it.state = on.contains(app.bundleID) ? .on : .off
            sub.addItem(it)
        }
        parent.submenu = sub
        return parent
    }

    // MARK: Workspace Dock

    @objc private func toggleWorkspaceDock() { setWorkspaceDock(!WorkspaceDock.enabled) }

    @objc private func pickDockEdge(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let e = DockEdge(rawValue: raw) else { return }
        setDockEdge(e)
    }

    /// Moves the Workspace Dock to another side of the screen; setup and the menu follow.
    func setDockEdge(_ e: DockEdge) {
        dock.setEdge(e)
        if setup.model.dockEdge != e { setup.model.dockEdge = e }
    }

    /// Asks, then hands off to the bundled uninstall.sh and quits; quitting brings every window
    /// back, and the script waits for that before it removes anything.
    @objc private func uninstall() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Uninstall BaneySpaces?"
        alert.informativeText = Uninstaller.summary
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try Uninstaller.start()
            NSApp.terminate(nil)
        } catch {
            let fail = NSAlert()
            fail.messageText = "BaneySpaces couldn't start the uninstaller"
            fail.informativeText = "\(error.localizedDescription)\n\nRun this in Terminal instead:\n\(Uninstaller.command)"
            fail.runModal()
        }
    }

    @objc private func toggleDockAgentStatus() { setDockAgentStatus(!WorkspaceDock.agentStatus) }

    /// Shows or hides agent badges on the Workspace Dock; settings and the menu follow.
    func setDockAgentStatus(_ on: Bool) {
        WorkspaceDock.agentStatus = on
        dock.model.agentStatus = on
        if setup.model.dockAgentStatus != on { setup.model.dockAgentStatus = on }
        dock.reload()
    }

    /// Turns the Workspace Dock on or off; off brings the macOS Dock back as it was.
    func setWorkspaceDock(_ on: Bool) {
        WorkspaceDock.enabled = on
        if setup.model.workspaceDock != on { setup.model.workspaceDock = on }
        if on, started { dock.start() } else if !on { dock.stop(restoreSystemDock: true) }
    }

    // MARK: Launcher

    @objc private func showLauncher() { launcher.show() }
    @objc private func toggleLauncherKey() { setLauncherOnCmdSpace(!Launcher.onCmdSpace) }

    /// Takes ⌘Space from Spotlight for the launcher, or gives it back. Changing macOS's shortcut
    /// takes a moment, so it happens off the main thread.
    func setLauncherOnCmdSpace(_ on: Bool) {
        Launcher.onCmdSpace = on
        if setup.model.launcherOnCmdSpace != on { setup.model.launcherOnCmdSpace = on }
        SystemShortcuts.spotlightQueue.async { [weak self] in
            if on { SystemShortcuts.freeSpotlight() } else { SystemShortcuts.restoreSpotlight() }
            DispatchQueue.main.async { self?.registerShortcuts() }
        }
    }

    // MARK: Updates

    /// "Update to …" when a newer build is waiting, "Updating to …" while it installs, otherwise
    /// nothing: the manual check is in the Updates submenu.
    private func updateItem() -> NSMenuItem? {
        if let r = updater.installing {
            let it = NSMenuItem(title: "Updating to \(r.isNightly ? "the nightly build" : r.name)…", action: nil, keyEquivalent: "")
            it.isEnabled = false
            return it
        }
        guard let r = updater.available else { return nil }
        let it = item("Update to \(r.isNightly ? "the Nightly Build" : r.name)…", #selector(offerUpdate))
        it.attributedTitle = NSAttributedString(string: it.title, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        return it
    }

    /// Stable or Nightly, and whether to look for updates by itself. Nothing installs without
    /// pressing Update Now.
    private func channelItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Updates", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let current = NSMenuItem(title: "You have \(Updater.buildDescription)", action: nil, keyEquivalent: "")
        current.isEnabled = false
        sub.addItem(current)
        sub.addItem(.separator())
        for (channel, title) in [(UpdateChannel.stable, "Stable: tested releases"), (.nightly, "Nightly: newest changes, every night")] {
            let it = item(title, #selector(pickChannel(_:)))
            it.representedObject = channel.rawValue
            it.state = updater.channel == channel ? .on : .off
            sub.addItem(it)
        }
        sub.addItem(.separator())
        let auto = item("Check for Updates Daily", #selector(toggleAutoCheck))
        auto.state = updater.checksAutomatically ? .on : .off
        sub.addItem(auto)
        sub.addItem(item("Check for Updates Now…", #selector(checkForUpdates)))
        parent.submenu = sub
        return parent
    }

    @objc private func checkForUpdates() { updater.check(manual: true) }
    @objc private func offerUpdate() { if let r = updater.available { updater.offer(r) } }
    @objc private func toggleAutoCheck() { updater.checksAutomatically.toggle() }
    @objc private func pickChannel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let channel = UpdateChannel(rawValue: raw) else { return }
        updater.channel = channel
    }

    @objc private func toggleParked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        ParkedApps.toggle(id)
        // Checking an app again gives it a fresh try at parking.
        if ParkedApps.bundleIDs.contains(id) { SlowMovers.bundleIDs.remove(id) }
        spaces.reapply()
    }

    @objc private func bringBack() { spaces.gatherOnOne() }

    @objc private func showViewer() { viewer.open() }

    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "Nine workspaces on one keyboard row.\n\(Modifier.current.symbol)1–\(Modifier.current.symbol)9 to switch. Add ⇧ to bring the window along."),
        ])
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: URL commands

    /// `open baneyspaces://switch/2`, `baneyspaces://move/3`, `baneyspaces://restore`.
    /// The same actions as the shortcuts, for scripts and checks.
    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text), url.scheme == "baneyspaces" else { return }
        let n = Int(url.lastPathComponent) ?? 0
        switch url.host {
        case "switch": run { $0.switchTo(n) }
        case "move": run { $0.moveFocused(to: n) }
        case "restore": run { _ in bringBack() }
        case "viewer": run { _ in viewer.toggle() }
        // Opening it changes nothing on its own, so a web page may: every action inside needs a key press.
        case "launcher": launcher.show(scope: LauncherModel.Scope(rawValue: url.lastPathComponent) ?? .root, takeKeys: false)
        case "dock":
            // Turning it off or hiding it is always allowed: a pinned dock must never outlive
            // its check (2026-10-14, a hide that raced the setting going off left it stuck up).
            // Showing it or turning it on (which hides the macOS Dock) is for checks, only when
            // `defaults write com.baney.baneyspaces dockURLCommands -bool true` says so, so a
            // web page can't do either.
            let checks = UserDefaults.standard.bool(forKey: "dockURLCommands")
            switch url.lastPathComponent {
            case "off": run { _ in setWorkspaceDock(false) }
            case "show" where checks: run { _ in dock.pin(true) }
            case "hide": run { _ in dock.pin(false) }
            case "on" where checks: run { _ in setWorkspaceDock(true) }
            default: NSLog("BaneySpaces: dock command refused or unknown %@", text)
            }
        default: NSLog("BaneySpaces: unknown command %@", text)
        }
    }
}
