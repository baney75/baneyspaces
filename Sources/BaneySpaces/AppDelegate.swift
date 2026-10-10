import AppKit
import ApplicationServices
import BaneySpacesCore
import Carbon.HIToolbox
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let spaces = Spaces()
    private let hotkeys = Hotkeys()
    private var statusItem: NSStatusItem!
    private var started = false
    private var trustTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        spaces.onChange = { [weak self] in self?.updateIcon() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            guard let self, self.started,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.spaces.appActivated(app)
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
        openAtLoginOnFirstRun()
        startWhenTrusted()
    }

    func applicationWillTerminate(_ n: Notification) {
        if started { spaces.restoreAll() }
    }

    // MARK: Accessibility

    /// Moving other apps' windows needs Accessibility access. Ask once, then wait for it, and for
    /// AeroSpace to quit, since two managers moving the same windows would fight.
    private func startWhenTrusted() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        if canStart { return start() }
        updateIcon()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
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
        // The shortcuts are taken only once they work, so ⌘1–⌘9 keep their usual meaning in
        // other apps until then.
        for (i, code) in Hotkeys.digitKeyCodes.enumerated() {
            let n = i + 1
            hotkeys.register(keyCode: code, modifiers: cmdKey) { [weak self] in self?.spaces.switchTo(n) }
            hotkeys.register(keyCode: code, modifiers: cmdKey | shiftKey) { [weak self] in self?.spaces.moveFocused(to: n) }
        }
        started = true
        spaces.start()
        updateIcon()
    }

    private func run(_ action: (Spaces) -> Void) {
        guard started else { return NSSound.beep() }
        action(spaces)
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
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
                menu.addItem(withTitle: "BaneySpaces needs Accessibility access", action: nil, keyEquivalent: "")
                menu.addItem(item("Open Accessibility Settings…", #selector(openAccessibilitySettings)))
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
            it.tag = n
            it.state = n == spaces.model.current ? .on : .off
            menu.addItem(it)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "⇧ with a number sends the front window there", action: nil, keyEquivalent: "")
        menu.addItem(item("Bring Every Window Back", #selector(bringBack)))
        let login = item("Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("About BaneySpaces", #selector(about)))
        menu.addItem(item("Quit BaneySpaces", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        return it
    }

    @objc private func pick(_ sender: NSMenuItem) { spaces.switchTo(sender.tag) }

    @objc private func bringBack() { spaces.gatherOnOne() }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSLog("BaneySpaces: open at login failed: %@", error.localizedDescription)
        }
    }

    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "Nine workspaces on one keyboard row.\n⌘1–⌘9 to switch. ⌘⇧1–⌘⇧9 to move a window."),
        ])
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func openAtLoginOnFirstRun() {
        guard !UserDefaults.standard.bool(forKey: "loginItemOffered") else { return }
        UserDefaults.standard.set(true, forKey: "loginItemOffered")
        try? SMAppService.mainApp.register()
    }

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
        default: NSLog("BaneySpaces: unknown command %@", text)
        }
    }
}
