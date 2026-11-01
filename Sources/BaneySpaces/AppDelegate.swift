import AppKit
import ApplicationServices
import BaneySpacesCore
import Carbon.HIToolbox
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let spaces = Spaces()
    /// Terminal splits, browser tabs and agents for the launcher and the dock's badges, plus the `baneyspaces` command.
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
        d.notMenus = { [weak self] in self?.switcher.windowNumber.map { [$0] } ?? [] }
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
            if let timer = settling.removeValue(forKey: w) {
                if timer.isValid { Trace.log("drop cancelled window=\(w)") }
                timer.invalidate()
            }
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
            self.dropCarried(grab, on: n)
        }
        // The same drag taken down to the Workspace Dock: let go on a tile, it goes there.
        t.onCarry = { [weak self] grab, _ in
            guard let self, self.started else { return }
            self.dock.carryMoved(grab)
        }
        t.onCarryEnd = { [weak self] grab, p in
            guard let self, let n = self.dock.endCarry(grab, at: p), p != nil else { return }
            self.dropCarried(grab, on: n)
        }
        return t
    }()

    /// A window dragged by its title bar and let go over workspace `n` in the overview or the
    /// dock. The window server and the app finish their own drop first: the window moves once
    /// it has held still for 60 ms (four looks 20 ms apart), no sooner than 0.1 s after the
    /// release and no later than 0.5 s.
    private func dropCarried(_ grab: TopDrag.Grab, on n: Int) {
        let id = grab.window
        cancelSettling(id)
        let gen = dropGeneration[id, default: 0]
        var last = TopDragWatcher.bounds(of: id)
        var looks = 0, still = 0
        let began = ProcessInfo.processInfo.systemUptime
        Trace.log("drop settling window=\(id) to=\(n)")
        settling[id] = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] timer in
            looks += 1
            let now = TopDragWatcher.bounds(of: id)
            still = now == last ? still + 1 : 0
            last = now
            let heldStill = looks >= 5 && still >= 3
            guard heldStill || looks >= 25 else { return }
            timer.invalidate()
            let ms = Int((ProcessInfo.processInfo.systemUptime - began) * 1000)
            guard let self, now != nil, self.dropGeneration[id, default: 0] == gen else {
                let why = self.map { "stale=\($0.dropGeneration[id, default: 0] != gen)" } ?? "self=nil"
                Trace.log("drop dropped window=\(id) after \(ms) ms looks=\(looks) gone=\(now == nil) \(why)")
                return
            }
            // Ended still, or gave up waiting for it to be (the move runs either way).
            if heldStill {
                Trace.log("drop settled window=\(id) after \(ms) ms looks=\(looks) still=\(still) settled=true")
            } else {
                Trace.log("drop gave up waiting window=\(id) after \(ms) ms looks=\(looks) still=\(still) settled=false")
            }
            self.settling[id] = nil
            self.spaces.moveCarried(id, to: n, from: grab.frame) { [weak self] in self?.dropGeneration[id, default: 0] == gen }
        }
    }
    /// Building the launcher scans every app, so the Deck's updates don't build it early.
    private var launcherBuilt = false
    /// The focused terminal's folder when the launcher opened, for New Terminal.
    private var terminalFolder: String?
    private lazy var launcher: LauncherController = {
        launcherBuilt = true
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
        a.willShow = { [weak self] in
            guard let self else { return }
            // New Terminal opens where you were working, read before the launcher takes focus.
            // Only a terminal in front says where you were working; a focused row in another app doesn't.
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            self.terminalFolder = Item.workingFolder(self.deck.engine.items, front: front)
            self.deck.engine.refreshAll()
        }
        a.newClaude = { [weak self] in self?.deck.newClaude(in: self?.terminalFolder) }
        a.newTerminal = { [weak self] in self?.deck.engine.newTerminal(in: self?.terminalFolder) }
        a.bringBack = { [weak self] in self?.bringBack() }
        a.toggleDock = { [weak self] in self?.toggleWorkspaceDock() }
        a.dockOn = { WorkspaceDock.enabled }
        a.checkForUpdates = { [weak self] in self?.checkForUpdates() }
        a.showSetup = { [weak self] in self?.showSetup() }
        return LauncherController(actions: a)
    }()
    private lazy var trackpadSwipe: TrackpadSwipe = {
        let s = TrackpadSwipe()
        s.onSwipe = { [weak self] direction in
            guard let self, self.started else { return }
            switch direction {
            case .up: if !self.viewer.isOpen { self.viewer.open() }
            case .down: if self.viewer.isOpen { self.viewer.toggle() }
            }
        }
        return s
    }()
    private var missionControlTicks = 0
    private lazy var hotCorners: HotCornerWatcher = {
        let w = HotCornerWatcher()
        w.onOpen = { [weak self] in
            guard let self, self.started, !self.viewer.isOpen else { return }
            self.viewer.open()
        }
        return w
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
        c.model.onBringBack = { [weak self] in self?.bringBack() }
        c.model.onAbout = { [weak self] in self?.about() }
        c.model.isStarted = { [weak self] in self?.started ?? false }
        c.model.parkedApps = { [weak self] in self?.parkedRows() ?? [] }
        c.model.onToggleParked = { [weak self] id in self?.toggleParked(id) }
        c.model.updateInfo = { [weak self] in self?.updateInfo() ?? .init() }
        c.model.onUpdatesShown = { [weak self] in self?.refreshCommandLineTools() }
        c.model.onCheckForUpdates = { [weak self] in self?.checkForUpdates() }
        c.model.onOfferUpdate = { [weak self] in if let r = self?.updater.available { self?.updater.offer(r) } }
        c.model.onSetUpdateChannel = { [weak self] in self?.updater.channel = $0 }
        c.model.onSetCheckDaily = { [weak self] in self?.updater.checksAutomatically = $0 }
        c.model.finishedRows = { [weak self] in
            guard let self, self.deck.started else { return [] }
            return self.deck.finishedRows().map { .init(id: $0.id, label: $0.label) }
        }
        c.model.onFocusFinished = { [weak self] id in self?.deck.focusFinished(id) }
        c.model.viewerKeysActive = { [weak self] in self?.missionControlKeys.isActive ?? false }
        c.model.trackpadProblem = { [weak self] in self?.trackpadSwipe.problem }
        c.model.missionControlProblem = { SystemMissionControl.problem }
        c.model.onViewerKeysChange = { [weak self] on in
            MissionControlKeys.enabled = on
            guard let self else { return }
            if self.started { self.restartKeyWatcher() }
            self.syncMissionControl()
        }
        c.model.onWorkspaceDockChange = { [weak self] on in self?.setWorkspaceDock(on) }
        c.model.onTopDragChange = { [weak self] on in self?.setTopDrag(on) }
        c.model.onDockEdgeChange = { [weak self] e in self?.setDockEdge(e) }
        c.model.onDockAgentStatusChange = { [weak self] on in self?.setDockAgentStatus(on) }
        // Every event, not just any: an older install lacks StopFailure, which the red badge needs.
        c.model.hooksInstalled = {
            guard let d = FileManager.default.contents(atPath: NSHomeDirectory() + "/.claude/settings.json") else { return .noClaudeCode }
            guard let settings = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return .unreadable }
            return HookSettings.installed(settings).count == HookSettings.events.count ? .on : .off
        }
        c.model.onInstallHooks = { [weak self] in self?.deck.installHooks() }
        c.model.onLauncherChange = { [weak self] on in self?.setLauncherOnCmdSpace(on) }
        c.model.onCmdTabChange = { [weak self] mode in
            MissionControlKeys.cmdTabMode = mode
            guard let self, self.started else { return }
            self.restartKeyWatcher()
        }
        return c
    }()

    private var mcBackAtDock = 0

    /// While Mission Control is held off: the person may have turned it back on (the README's
    /// `defaults delete`, a profile), and the launch agent may have been switched off (the
    /// Background Item notice). Neither may leave BaneySpaces answering beside macOS's view, or
    /// holding it off with no way back.
    private func checkMissionControlHeld() {
        // The key watcher can stop while Accessibility is still granted; then nothing answers the key.
        guard missionControlKeys.isActive else {
            Trace.log("mission control: the key watcher stopped; giving Mission Control back")
            return syncMissionControl()
        }
        if SystemMissionControl.isOffAtDock {
            mcBackAtDock = 0
        } else {
            // Twice in a row, so one unlucky read of the Dock's settings doesn't undo it.
            mcBackAtDock += 1
            if mcBackAtDock >= 2 {
                mcBackAtDock = 0
                Trace.log("mission control: turned back on at the Dock; BaneySpaces' overview switched off")
                return setup.model.setViewerKeys(false)
            }
        }
        guard missionControlTicks % 15 == 0 else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard !SystemMissionControl.isArmed else { return }
            DispatchQueue.main.async {
                Trace.log("mission control: the launch agent is no longer loaded")
                self?.syncMissionControl()
            }
        }
    }

    /// The key watcher reads its settings when it starts, so a change restarts it.
    private func restartKeyWatcher() {
        missionControlKeys.stop()
        missionControlKeys.start()
    }

    /// macOS's Mission Control is off while BaneySpaces' overview answers its keys, its trackpad
    /// swipe and its hot corners; switched off, without Accessibility, or while macOS won't let the
    /// key watcher run (nothing would answer the key), all of it goes back.
    private func syncMissionControl() {
        guard missionControlWanted else { return giveMissionControlBack() }
        // The launch agent is set up off the main thread; one attempt at a time.
        guard !armingMissionControl else { return }
        armingMissionControl = true
        SystemMissionControl.takeOver(stillWanted: { [weak self] in self?.missionControlWanted ?? false }) { [weak self] taken in
            guard let self else { return }
            self.armingMissionControl = false
            guard taken else { return self.giveMissionControlBack() }
            self.trackpadSwipe.start()
            self.hotCorners.set(corners: SystemMissionControl.answeredCorners())
        }
    }

    private var armingMissionControl = false

    /// Accessibility granted, the switch on, and the key watcher running: something answers the keys.
    private var missionControlWanted: Bool { started && MissionControlKeys.enabled && missionControlKeys.isActive }

    /// Not wanted, or not safe: without the launch agent that puts it back, Mission Control stays
    /// on (and the swipe and corners stay quiet, since it would open beside the overview).
    private func giveMissionControlBack() {
        let why = missionControlWanted ? SystemMissionControl.problem : nil
        trackpadSwipe.stop()
        hotCorners.stop()
        // The agent goes with the switch, and only then; Accessibility lost or a quit leaves it loaded.
        SystemMissionControl.restore(keeping: why, removeAgent: !MissionControlKeys.enabled)
    }

    /// An app dragged out of the disk image never ran the installer's other steps: AeroSpace stepping
    /// aside, the `baneyspaces` command in ~/.local/bin, Ghostdeck going to the Trash. The first
    /// launch from Applications does them, once: the bundled install-app.sh with --in-place, run
    /// off the main thread. It runs only when the command is missing or points somewhere else, and
    /// only from an Applications folder (never from the disk image or a build folder).
    private func linkCommandIfNeeded() {
        let bundle = Bundle.main.bundleURL.path
        let home = NSHomeDirectory()
        guard bundle.hasPrefix("/Applications/") || bundle.hasPrefix("\(home)/Applications/"),
              let script = Bundle.main.url(forResource: "install-app", withExtension: "sh") else { return }
        let link = "\(home)/.local/bin/baneyspaces"
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link), target.hasPrefix(bundle + "/") { return }
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script.path, "--in-place", bundle]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do {
                try p.run()
                let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
                Trace.log("install-app --in-place exit \(p.terminationStatus): \(out.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))")
            } catch {
                Trace.log("install-app --in-place didn't start: \(error.localizedDescription)")
            }
        }
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
            SystemMissionControl.restore()
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
        linkCommandIfNeeded()
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
        // `baneyspaces set` and `get` answer from launch on, before Accessibility: looks and the dock switch
        // only store a choice then; the dock starts with the rest once BaneySpaces does.
        deck.readSetting = { [weak self] in self?.settingValue($0) }
        deck.writeSetting = { [weak self] k, v in self?.applySetting(k, v) ?? false }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        spaces.onChange = { [weak self] in
            self?.updateIcon()
            self?.dock.reload()
        }
        // A new theme redraws the menu bar indicator as well as the panels.
        NotificationCenter.default.addObserver(forName: Appearance.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.updateIcon()
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
            // An activation an agent's launch or action caused isn't Donovan using the app.
            UserActivity.shared.activated(app.processIdentifier, byAgent: AgentActivity.shared.causedByAnyAction(pid: app.processIdentifier, bundle: app.bundleIdentifier))
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
        // ⌃⌘K (registered in `registerShortcuts`) opens the launcher, which searches the Deck's rows.
        deck.onSearch = { [weak self] in self?.launcher.toggle() }
        deck.onItemsChange = { [weak self] in if self?.launcherBuilt == true { self?.launcher.rowsChanged() } }
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
        // Mission Control comes back with the Dock, so there's always a way to see the desktops.
        // Quitting for an update is the exception: the new build takes over, and if it never
        // starts the launch agent puts Mission Control back after 30 seconds.
        if SystemMissionControl.isTakenByUs {
            if UserDefaults.standard.dictionary(forKey: "updatingTo") != nil { SystemMissionControl.leaveForUpdate() }
            else { SystemMissionControl.restore() }
        }
        if started { spaces.restoreAll() }
        // ⌘Space goes back to Spotlight while BaneySpaces isn't running; the next launch takes it again.
        SystemShortcuts.spotlightQueue.sync { SystemShortcuts.restoreSpotlight() }
        spaces.flushWrites()
        // Last: a fault in the private framework while letting go must not skip anything above.
        trackpadSwipe.stop()
        hotCorners.stop()
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
        SystemMissionControl.restore()
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

    /// A press anywhere tells Spaces which display you're on: in other apps and on the desktop
    /// (global), and on BaneySpaces' own dock, overview and launcher (local, before the press is
    /// handled, so a dock tile switches the dock's display).
    private var clickMonitors: [Any] = []
    private func watchClicksForDisplay() {
        guard clickMonitors.isEmpty else { return }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in self?.spaces.usePointerDisplay() }) {
            clickMonitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] e in self?.spaces.usePointerDisplay(); return e }) {
            clickMonitors.append(l)
        }
    }

    private func start() {
        // Applies to every Accessibility call, so one frozen app can't stall a switch.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        started = true
        registerShortcuts()
        missionControlKeys.start()
        syncMissionControl()
        spaces.start()
        watchClicksForDisplay()
        if WorkspaceDock.enabled { dock.start() }
        // macOS's own top-of-screen drag goes quiet first, so only one view answers the gesture.
        // Off, settings left taken over (a crash, a change while it wasn't running) go back.
        if TopDragWatcher.enabled { SystemTopDrag.takeOver() } else { SystemTopDrag.restore() }
        syncWindowDrags()
        startDeck()
        updateIcon()
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.stillTrusted() else { return }
            // A key watcher macOS refused earlier gets another chance.
            if (MissionControlKeys.enabled || MissionControlKeys.cmdTabEnabled) && !self.missionControlKeys.isActive {
                self.missionControlKeys.start()
                if self.missionControlKeys.isActive { self.syncMissionControl() }
            }
            // Every ten seconds: proof of life for the launch agent, and System Settings changes
            // to hot corners and trackpad gestures. Nothing here lists devices.
            self.missionControlTicks += 1
            if self.missionControlTicks % 5 == 0 {
                if SystemMissionControl.isTakenByUs {
                    SystemMissionControl.beat()
                    self.trackpadSwipe.refreshSettings()
                    self.hotCorners.set(corners: SystemMissionControl.answeredCorners())
                    self.checkMissionControlHeld()
                } else if self.started, MissionControlKeys.enabled, self.missionControlKeys.isActive,
                          SystemMissionControl.problem == nil || self.missionControlTicks % 150 == 0 {
                    // Taken back by the launch agent while this ran, or not armed yet: try again
                    // (every five minutes when the safety net failed, so macOS isn't asked again and again).
                    self.syncMissionControl()
                }
            }
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
        // Not watching any more, so macOS answers the drag, the swipe and the corners again until BaneySpaces is back.
        SystemTopDrag.restore()
        trackpadSwipe.stop()
        hotCorners.stop()
        SystemMissionControl.restore()
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

    /// Windows dragged by their title bars are followed while the drag to the top opens the
    /// overview or the Workspace Dock takes them. macOS's own top-of-screen drag is the top
    /// drag's to turn off and on (`setTopDrag`), never the dock's: turning the dock on or off
    /// leaves those settings, and the Dock process, alone.
    private func syncWindowDrags() {
        guard started else { return }
        topDrag.topEnabled = TopDragWatcher.enabled
        if DockSwitch<DockPanel>.windowDragsNeeded(topDrag: TopDragWatcher.enabled, dockEnabled: WorkspaceDock.enabled) {
            topDrag.start()
        } else {
            topDrag.stop()
            cancelSettling()
        }
    }

    private func setTopDrag(_ on: Bool) {
        TopDragWatcher.enabled = on
        if on, started { SystemTopDrag.takeOver() } else if !on { SystemTopDrag.restore() }
        syncWindowDrags()
    }

    /// The shortcuts are taken only once they work, so the keys keep their usual meaning in other
    /// apps until then. Picking a different modifier in setup re-registers them.
    private func registerShortcuts() {
        hotkeys.removeAll()
        if Launcher.onCmdSpace, !SystemShortcuts.spotlightOwnsCmdSpace {
            hotkeys.register(keyCode: kVK_Space, modifiers: cmdKey) { [weak self] in self?.launcher.toggle() }
        }
        // ⌃⌘K opens the launcher from any app, with or without Accessibility.
        hotkeys.register(keyCode: kVK_ANSI_K, modifiers: controlKey | cmdKey) { [weak self] in self?.deck.onSearch() }
        // ⌃⌘U goes to the agent that finished, from any app.
        hotkeys.register(keyCode: kVK_ANSI_U, modifiers: controlKey | cmdKey) { [weak self] in
            if self?.deck.started == true { self?.deck.jumpToFinished() }
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
        let description = started ? "BaneySpaces, workspace \(spaces.model.current)" : "BaneySpaces needs Accessibility access"
        // The BaneySpaces theme keeps the numbered square it has always shown; the others draw their indicator.
        let image = (started ? MenuBarMark.image(workspace: spaces.model.current, description: description) : nil)
            ?? NSImage(systemSymbolName: name, accessibilityDescription: description)
        image?.isTemplate = true
        statusItem.button?.image = image
        // Agents that finished while you were elsewhere, counted beside the workspace number.
        let n = started && deck.started ? deck.unseenCount : 0
        statusItem.button?.title = n > 0 ? " \(n)" : ""
        statusItem.button?.imagePosition = .imageLeading
    }

    private func startDeck() {
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
        h.pidOf = { [weak self] id in self?.spaces.handsLive(id)?.pid }
        h.occupied = { [weak self] n in self?.spaces.isOccupied(n) ?? false }
        deck.agentHost = h
        // The agent hands: what the scope guard needs from the workspaces, and what to do when a lend changes.
        // The engine's state folder is set here, once, on the main thread, before any engine queue exists.
        HandsEngine.prepareEnvironment()
        deck.hands.host = HandsHost(
            agentWorkspace: { Spaces.agentWorkspace },
            windows: { [weak self] in self?.spaces.handsWindows(fresh: false) ?? [] },
            freshWindows: { [weak self] in self?.spaces.handsWindows(fresh: true) ?? [] },
            live: { [weak self] in self?.spaces.handsLive($0) },
            titles: { [weak self] in self?.spaces.handsTitles($0) ?? [:] },
            inspect: { [weak self] in self?.spaces.handsInspect($0) ?? (nil, false) },
            agentOwned: { AgentOwned.shared.pids },
            askToLend: { app, minutes, takeBack in LendConsent.ask(app: app, minutes: minutes, takeBack: takeBack) },
            open: { [weak self] args in self?.deck.agent("open", args) ?? Wire.Reply(ok: false, error: "not ready") })
        HandsLends.shared.onChange = { [weak self] in
            DispatchQueue.main.async {
                // A lent app is parked, not hidden, while it is lent: the workspace is applied again.
                self?.spaces.saveState()
                self?.run { $0.reapply() }
            }
        }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in HandsLends.shared.expire() }
        deck.onWorkingChange = { [weak self] in self?.dock.reload() }
        // A moment after launch: setting up an observer per app costs the main thread a few
        // hundred milliseconds, which would otherwise land on your first workspace switch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.started else { return }
            self.deck.start(workspaceOf: { [weak self] in self?.spaces.model.workspace(of: $0) },
                            currentWorkspace: { [weak self] in self?.spaces.model.current ?? 1 })
        }
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
        let entries = MenuLayout.entries(rows: MenuLayout.rows(current: spaces.model.current, apps: apps),
                                         finished: deck.started ? deck.unseenCount : 0, update: updateNotice(),
                                         dockOn: WorkspaceDock.enabled)
        for entry in entries { menu.addItem(menuItem(for: entry)) }
    }

    /// Each entry `MenuLayout.entries` lists, as the one menu item it is. Every item the menu holds
    /// is built here or in `item(_:_:key:)`, which `MenuLayoutTests` counts.
    private func menuItem(for entry: MenuEntry) -> NSMenuItem {
        switch entry {
        case .workspace(let row):
            let it = item(row.title, #selector(pick(_:)), key: "\(row.workspace)")
            it.keyEquivalentModifierMask = Modifier.current.menuFlags
            it.tag = row.workspace
            it.state = row.isCurrent ? .on : .off
            it.toolTip = row.fullList
            return it
        case .showAll:
            return item("Show All Workspaces", #selector(showViewer))
        case .find:
            let find = item("Find or Install an App…", #selector(showLauncher))
            if Launcher.onCmdSpace { find.keyEquivalent = " "; find.keyEquivalentModifierMask = [.command] }
            return find
        case .dock(let on):
            return item(on ? "Turn Off Workspace Dock" : "Turn On Workspace Dock", #selector(toggleDockFromMenu))
        case .settings:
            return item("Settings…", #selector(showSetup), key: ",")
        case .quit:
            return item("Quit BaneySpaces", #selector(quit), key: "q")
        case .finished(let count):
            // Clicking an agent goes to it and marks it seen, which drops it from this list.
            return deck.finishedMenuItem(title: MenuLayout.finishedTitle(count))
        case .update(let notice):
            let it = item(notice.menuTitle, #selector(offerUpdate))
            if notice.installing {
                it.action = nil
                it.isEnabled = false
            } else {
                it.attributedTitle = NSAttributedString(string: it.title, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
            }
            return it
        case .separator:
            return .separator()
        }
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        return it
    }

    /// A release waiting or installing, if any: the menu's "Update to …" row and Settings > Updates.
    private func updateNotice() -> UpdateNotice? {
        if let r = updater.installing { return UpdateNotice(name: r.name, isNightly: r.isNightly, installing: true) }
        return updater.available.map { UpdateNotice(name: $0.name, isNightly: $0.isNightly, installing: false) }
    }

    @objc private func toggleDockFromMenu() { toggleWorkspaceDock() }

    @objc private func offerUpdate() { if let r = updater.available { updater.offer(r) } }

    @objc private func pick(_ sender: NSMenuItem) { spaces.switchTo(sender.tag) }

    /// Apps whose windows are parked instead of hidden, so automation can still use them: Settings >
    /// Automation. Apps with windows, plus every app already on the list, so any of them can be unchecked.
    private func parkedRows() -> [SetupModel.ParkedRow] {
        let on = ParkedApps.bundleIDs
        let slow = SlowMovers.bundleIDs
        // The window list as it is now, as the menu did: an app's late first window shows.
        if started { spaces.refresh() }
        var apps = started ? spaces.appsWithWindows() : []
        for id in on where !apps.contains(where: { $0.bundleID == id }) {
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
            apps.append((name, id))
        }
        // An app that slides its windows when moved is hidden anyway, so nothing moves on screen.
        return apps.map { .init(id: $0.bundleID, name: $0.name, on: on.contains($0.bundleID), animates: slow.contains($0.bundleID)) }
    }

    // MARK: Workspace Dock

    private func toggleWorkspaceDock() { setWorkspaceDock(!WorkspaceDock.enabled) }

    /// Moves the Workspace Dock to another side of the screen; setup follows.
    func setDockEdge(_ e: DockEdge) {
        dock.setEdge(e)
        if setup.model.dockEdge != e { setup.model.dockEdge = e }
    }

    /// Asks, then hands off to the bundled uninstall.sh and quits; quitting brings every window
    /// back, and the script waits for that before it removes anything.
    private func uninstall() {
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

    /// Shows or hides agent badges on the Workspace Dock; settings follow.
    func setDockAgentStatus(_ on: Bool) {
        WorkspaceDock.agentStatus = on
        dock.model.agentStatus = on
        if setup.model.dockAgentStatus != on { setup.model.dockAgentStatus = on }
        dock.reload()
    }

    /// `dock.enabled`, `appearance.theme` and `appearance.palette` by name: what `baneyspaces get` reads.
    func settingValue(_ key: SettingKey) -> String? {
        switch key {
        case .theme: Appearance.shared.settings.theme.rawValue
        case .palette: Appearance.shared.settings.colorPalette
        case .dockEnabled: WorkspaceDock.enabled ? "true" : "false"
        }
    }

    /// What `baneyspaces set` and Settings do: applied at once, no restart. False when the app can't (it is going away).
    @discardableResult
    func applySetting(_ key: SettingKey, _ value: String) -> Bool {
        switch key {
        case .theme: Appearance.shared.settings.theme = ThemeID(rawValue: value) ?? .macDefault
        case .palette: Appearance.shared.settings.colorPalette = value
        case .dockEnabled: setWorkspaceDock(value == "true")
        }
        return true
    }

    /// Turns the Workspace Dock on or off (`dock.enabled`). Off, there is no dock window at all and
    /// the macOS Dock comes back as it was; on, the dock returns on the next reveal at its edge.
    func setWorkspaceDock(_ on: Bool) {
        WorkspaceDock.enabled = on
        if setup.model.workspaceDock != on { setup.model.workspaceDock = on }
        if on, started { dock.start() } else if !on { dock.stop(restoreSystemDock: true) }
        syncWindowDrags()
    }

    // MARK: Launcher

    @objc private func showLauncher() { launcher.show() }

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

    /// What Settings > Updates shows: the build you have, the channel, and any release waiting.
    private func updateInfo() -> SetupModel.UpdateInfo {
        .init(have: Updater.buildDescription, channel: updater.channel, daily: updater.checksAutomatically,
              nightlyNeedsTools: !commandLineTools, notice: updateNotice())
    }

    /// Whether Apple's command line tools are installed, as of the last look: `refreshCommandLineTools`
    /// looks again (it runs a process, so off the main thread) whenever Settings > Updates appears.
    private var commandLineTools = true

    private func refreshCommandLineTools() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = Updater.hasCommandLineTools
            DispatchQueue.main.async {
                guard let self, self.commandLineTools != found else { return }
                self.commandLineTools = found
                self.setup.model.reload()
            }
        }
    }

    private func checkForUpdates() { updater.check(manual: true) }

    private func toggleParked(_ id: String) {
        guard started else { return }
        ParkedApps.toggle(id)
        // Checking an app again gives it a fresh try at parking.
        if ParkedApps.bundleIDs.contains(id) { SlowMovers.bundleIDs.remove(id) }
        spaces.reapply()
    }

    private func bringBack() {
        guard started else { return }
        spaces.gatherOnOne()
    }

    @objc private func showViewer() { viewer.open() }

    private func about() {
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
            // For `scripts/dock-motion-probe.swift`: open and close the first "+N" list without the pointer.
            case "more" where checks: run { _ in _ = dock.openMoreForCheck() }
            case "lessmore" where checks: run { _ in dock.closeMoreForCheck() }
            default: NSLog("BaneySpaces: dock command refused or unknown %@", text)
            }
        default: NSLog("BaneySpaces: unknown command %@", text)
        }
    }
}
