import AppKit
import ApplicationServices
import BaneySpacesCore
import Carbon.HIToolbox
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let spaces = Spaces()
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
        d.onTurnOff = { [weak self] in self?.setWorkspaceDock(false) }
        return d
    }()
    private lazy var switcher = WorkspaceSwitcher(spaces: spaces)
    private lazy var missionControlKeys: MissionControlKeys = {
        let keys = MissionControlKeys { [weak self] in self?.viewer.toggle() }
        keys.onCmdTab = { [weak self] forward in
            guard let self, self.started, !self.viewer.isOpen else {
                Trace.log("cmdTab ignored started=\(self?.started ?? false) viewerOpen=\(self?.viewer.isOpen ?? false)")
                MissionControlKeys.inGesture = false
                return
            }
            self.switcher.step(forward: forward)
        }
        keys.onCmdReleased = { [weak self] in self?.switcher.commit() }
        keys.onCancel = { [weak self] in self?.switcher.cancel() }
        return keys
    }()
    private lazy var setup: SetupWindowController = {
        let c = SetupWindowController()
        c.model.onModifierChange = { [weak self] _ in self?.registerShortcuts() }
        c.model.viewerKeysActive = { [weak self] in self?.missionControlKeys.isActive ?? false }
        c.model.onViewerKeysChange = { [weak self] on in
            MissionControlKeys.enabled = on
            guard let self, self.started else { return }
            self.restartKeyWatcher()
        }
        c.model.onWorkspaceDockChange = { [weak self] on in self?.setWorkspaceDock(on) }
        c.model.onCmdTabChange = { [weak self] on in
            MissionControlKeys.cmdTabEnabled = on
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
            exit(0)
        }
        // `BaneySpaces --restore-dock`: the uninstaller's way to put the macOS Dock back if the
        // Workspace Dock had it out of sight.
        if CommandLine.arguments.contains("--restore-dock") {
            SystemDock.restore()
            exit(0)
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
            guard let self, self.started,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.spaces.appActivated(app)
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
        if started { spaces.restoreAll() }
        spaces.flushWrites()
    }

    // MARK: Accessibility

    /// Moving other apps' windows needs Accessibility access. Ask once, then wait for it, and for
    /// AeroSpace to quit, since two managers moving the same windows would fight.
    private func startWhenTrusted() {
        if canStart { return start() }
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
        hotkeys.removeAll()
        missionControlKeys.stop()
        viewer.close()
        dock.stop(restoreSystemDock: true)
        spaces.suspend()
        started = false
        updateIcon()
        showSetup()
        startWhenTrusted()
        return false
    }

    /// The shortcuts are taken only once they work, so the keys keep their usual meaning in other
    /// apps until then. Picking a different modifier in setup re-registers them.
    private func registerShortcuts() {
        guard started else { return }
        hotkeys.removeAll()
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
                menu.addItem(item("Set Up BaneySpaces…", #selector(showSetup)))
            }
            menu.addItem(.separator())
            menu.addItem(item("Quit BaneySpaces", #selector(quit), key: "q"))
            return
        }
        spaces.refresh()
        for n in Workspaces.range {
            let apps = spaces.apps(on: n)
            let title = apps.isEmpty ? "Workspace \(n)" : "Workspace \(n)  ·  \(apps.joined(separator: ", "))"
            let it = item(title, #selector(pick(_:)), key: "\(n)")
            it.keyEquivalentModifierMask = Modifier.current.menuFlags
            it.tag = n
            it.state = n == spaces.model.current ? .on : .off
            menu.addItem(it)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Add ⇧ to send the front window there", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(item("Show All Workspaces", #selector(showViewer)))
        menu.addItem(item("Bring Every Window Back", #selector(bringBack)))
        menu.addItem(parkedAppsItem())
        let dockItem = item("Workspace Dock", #selector(toggleWorkspaceDock))
        dockItem.state = WorkspaceDock.enabled ? .on : .off
        dockItem.toolTip = "A dock of your workspaces in place of the macOS Dock. Rest the pointer on the bottom edge of the screen to show it."
        menu.addItem(dockItem)
        menu.addItem(item("Set Up BaneySpaces…", #selector(showSetup), key: ","))
        menu.addItem(.separator())
        menu.addItem(updateItem())
        menu.addItem(channelItem())
        menu.addItem(item("About BaneySpaces", #selector(about)))
        menu.addItem(item("Quit BaneySpaces", #selector(quit), key: "q"))
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

    /// Turns the Workspace Dock on or off; off brings the macOS Dock back as it was.
    func setWorkspaceDock(_ on: Bool) {
        WorkspaceDock.enabled = on
        if setup.model.workspaceDock != on { setup.model.workspaceDock = on }
        if on, started { dock.start() } else if !on { dock.stop(restoreSystemDock: true) }
    }

    // MARK: Updates

    /// "Update to …" when a newer build is waiting, "Updating to …" while it installs,
    /// otherwise a manual check.
    private func updateItem() -> NSMenuItem {
        if let r = updater.installing {
            let it = NSMenuItem(title: "Updating to \(r.isNightly ? "the nightly build" : r.name)…", action: nil, keyEquivalent: "")
            it.isEnabled = false
            return it
        }
        guard let r = updater.available else { return item("Check for Updates…", #selector(checkForUpdates)) }
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
        sub.addItem(item("Check Now", #selector(checkForUpdates)))
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
        case "dock":
            switch url.lastPathComponent {
            case "show": run { _ in dock.pin(true) }
            case "hide": run { _ in dock.pin(false) }
            case "on": run { _ in setWorkspaceDock(true) }
            case "off": run { _ in setWorkspaceDock(false) }
            default: NSLog("BaneySpaces: unknown command %@", text)
            }
        default: NSLog("BaneySpaces: unknown command %@", text)
        }
    }
}
