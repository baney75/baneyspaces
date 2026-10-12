import AppKit
import BaneySpacesCore
import ApplicationServices
import ServiceManagement
import SwiftUI

/// Live state for the setup window. While the window is open it re-reads permission four times a
/// second, so flipping the switch in System Settings shows up here almost at once.
final class SetupModel: ObservableObject {
    @Published var trusted = AXIsProcessTrusted()
    @Published var modifier = Modifier.current
    @Published var conflicts: [String] = SystemShortcuts.conflicts(for: Modifier.current)
    @Published var desktops = Desktops.count
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled
    @Published var viewerKeys = MissionControlKeys.enabled
    @Published var cmdTab = MissionControlKeys.cmdTabMode
    var onCmdTabChange: ((MissionControlKeys.CmdTabMode) -> Void)?
    @Published var workspaceDock = WorkspaceDock.enabled
    var onWorkspaceDockChange: ((Bool) -> Void)?
    @Published var dockEdge = WorkspaceDock.edge
    var onDockEdgeChange: ((DockEdge) -> Void)?
    @Published var launcherOnCmdSpace = Launcher.onCmdSpace
    @Published var searchEngine = Launcher.searchEngine { didSet { Launcher.searchEngine = searchEngine } }
    @Published var agent = Launcher.agent { didSet { Launcher.agent = agent } }
    @Published var customBangs = Launcher.customBangs
    @Published var newTrigger = ""
    @Published var newName = ""
    @Published var newURL = ""
    @Published var newIsAgent = false
    @Published var bangProblem: String?
    var onLauncherChange: ((Bool) -> Void)?
    @Published var aeroSpaceRunning = SetupModel.isAeroSpaceRunning
    @Published var loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    @Published var screenshotsFreed = SystemShortcuts.hasFreed
    /// The Mission Control key is switched on but macOS refused the key watcher.
    @Published var viewerKeysFailed = false
    /// The person asked for access a while ago and macOS still says no: most likely an old
    /// permission from an earlier copy of the app, which only a reset clears.
    @Published var staleGrant = false
    @Published var fixing = false
    @Published var freeing = false
    /// Shown once, the moment everything required turns green.
    @Published var justEnabled = false

    var onModifierChange: ((Modifier) -> Void)?
    var onViewerKeysChange: ((Bool) -> Void)?
    /// Asked by the window controller; true while the Mission Control key watcher is running.
    var viewerKeysActive: () -> Bool = { true }
    /// Called when every required step turns green while the window is open.
    var onReady: (() -> Void)?

    private var timer: Timer?
    private var ticks = 0
    private var askedAt: Date?

    /// Required to work at all. Desktops, login and keys are optional notices.
    var ready: Bool { trusted && !aeroSpaceRunning }

    static var isAeroSpaceRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "bobko.aerospace").isEmpty
    }

    func startWatching() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stopWatching() { timer?.invalidate() }

    private func tick() {
        ticks += 1
        let wasReady = ready
        trusted = AXIsProcessTrusted()
        aeroSpaceRunning = SetupModel.isAeroSpaceRunning
        if let askedAt, !trusted, Date().timeIntervalSince(askedAt) > 8 { staleGrant = true }
        if trusted { staleGrant = false }
        if !wasReady && ready { becameReady() }
        // The slower checks once a second.
        if ticks % 4 == 0 { reloadOptional() }
    }

    func reload() {
        trusted = AXIsProcessTrusted()
        aeroSpaceRunning = SetupModel.isAeroSpaceRunning
        reloadOptional()
    }

    private func reloadOptional() {
        conflicts = SystemShortcuts.conflicts(for: modifier)
        screenshotsFreed = SystemShortcuts.hasFreed
        desktops = Desktops.count
        let status = SMAppService.mainApp.status
        openAtLogin = status == .enabled
        loginNeedsApproval = status == .requiresApproval
        viewerKeysFailed = trusted && viewerKeys && !viewerKeysActive()
    }

    private func becameReady() {
        justEnabled = true
        askedAt = nil
        onReady?()
    }

    /// Adds BaneySpaces to the Accessibility list with macOS's own prompt, then opens the list so
    /// the only thing left is one switch.
    func allow() {
        askedAt = Date()
        staleGrant = false
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        SetupModel.openAccessibilitySettings()
    }

    /// Clears the old permission macOS kept for an earlier copy of BaneySpaces, then asks again.
    func fixPermission() {
        fixing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            p.arguments = ["reset", "Accessibility", "com.baney.baneyspaces"]
            try? p.run()
            p.waitUntilExit()
            DispatchQueue.main.async {
                self?.fixing = false
                self?.allow()
            }
        }
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func quitAeroSpace() {
        NSRunningApplication.runningApplications(withBundleIdentifier: "bobko.aerospace").forEach { $0.terminate() }
    }

    func pick(_ m: Modifier) {
        modifier = m
        Modifier.current = m
        onModifierChange?(m)
        reloadOptional()
    }

    /// `defaults` and `activateSettings` can take seconds, so they run off the main thread.
    func freeShortcuts() {
        freeing = true
        let m = modifier
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            SystemShortcuts.free(for: m)
            DispatchQueue.main.async { self?.freeing = false; self?.reloadOptional() }
        }
    }

    func restoreShortcuts() {
        freeing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            SystemShortcuts.restore()
            DispatchQueue.main.async { self?.freeing = false; self?.reloadOptional() }
        }
    }

    func setViewerKeys(_ on: Bool) {
        viewerKeys = on
        onViewerKeysChange?(on)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.reloadOptional() }
    }

    func setCmdTab(_ mode: MissionControlKeys.CmdTabMode) {
        cmdTab = mode
        onCmdTabChange?(mode)
    }

    func setWorkspaceDock(_ on: Bool) {
        workspaceDock = on
        onWorkspaceDockChange?(on)
    }

    func setLauncher(_ on: Bool) {
        launcherOnCmdSpace = on
        onLauncherChange?(on)
    }

    func addBang() {
        if let why = Bangs.problem(trigger: newTrigger, name: newName, url: newURL) { bangProblem = why; return }
        guard let list = Bangs.adding(Bang(trigger: newTrigger, name: newName, url: newURL, agent: newIsAgent), to: Launcher.customBangs) else { return }
        Launcher.customBangs = list
        customBangs = list
        newTrigger = ""; newName = ""; newURL = ""; newIsAgent = false
        bangProblem = nil
    }

    func removeBang(_ trigger: String) {
        let list = Launcher.customBangs.filter { $0.trigger != trigger }
        Launcher.customBangs = list
        customBangs = list
    }

    func setOpenAtLogin(_ on: Bool) {
        UserDefaults.standard.set(true, forKey: "loginItemChosen")
        do {
            try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        } catch {
            NSLog("BaneySpaces: open at login failed: %@", error.localizedDescription)
        }
        reloadOptional()
    }

    /// Setup's last act: start with the Mac unless the person already decided.
    func finish() {
        let defaults = UserDefaults.standard
        // Someone who already decided (here, or in 0.1, which recorded "loginItemOffered") keeps
        // their choice; so does anyone whose login item macOS already knows about.
        guard !defaults.bool(forKey: "loginItemChosen"), !defaults.bool(forKey: "loginItemOffered"),
              SMAppService.mainApp.status == .notRegistered else { return }
        defaults.set(true, forKey: "loginItemChosen")
        try? SMAppService.mainApp.register()
    }
}

struct SetupView: View {
    @ObservedObject var model: SetupModel
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("BaneySpaces").font(.title2.bold())
                    Text("Nine workspaces. One row of keys.").foregroundStyle(.secondary)
                }
            }

            if model.justEnabled && model.ready {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill").font(.title2).foregroundStyle(.green)
                    Text("BaneySpaces is on. Try \(model.modifier.symbol)2.").font(.title3.bold())
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.12)))
            }

            step(done: model.trusted, title: "Let BaneySpaces arrange windows") {
                if model.trusted {
                    Text("Allowed.").foregroundStyle(.secondary)
                } else {
                    Text("Accessibility lets BaneySpaces show, hide and move other apps' windows. It can't read what you type.")
                        .foregroundStyle(.secondary)
                    Button(action: model.allow) {
                        Text("Allow BaneySpaces").frame(minWidth: 160)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    Text("macOS opens its settings. Turn on BaneySpaces in the list and come back; this window updates by itself.")
                        .font(.callout).foregroundStyle(.secondary)
                    if model.staleGrant {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Already switched on and still not working?").font(.callout.bold())
                            Text("macOS kept an old permission from an earlier copy of BaneySpaces. Fixing it removes the old entry and asks again.")
                                .font(.callout).foregroundStyle(.secondary)
                            Button(model.fixing ? "Fixing…" : "Fix Permission", action: model.fixPermission)
                                .disabled(model.fixing)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
                    }
                }
            }

            if model.aeroSpaceRunning {
                step(done: false, title: "Quit AeroSpace") {
                    Text("AeroSpace is running and uses the same keys. BaneySpaces starts as soon as it quits.")
                        .foregroundStyle(.secondary)
                    Button("Quit AeroSpace", action: model.quitAeroSpace)
                }
            }

            step(done: true, title: "Your keys") {
                Picker("", selection: Binding(get: { model.modifier }, set: { model.pick($0) })) {
                    ForEach(Modifier.allCases) { Text($0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow { Text("\(model.modifier.symbol)1 – \(model.modifier.symbol)9").monospaced(); Text("go to a workspace") }
                    GridRow { Text("\(model.modifier.symbol)⇧1 – \(model.modifier.symbol)⇧9").monospaced(); Text("send the front window there") }
                }
                Text(model.modifier.tradeoff).font(.callout).foregroundStyle(.secondary)
                ForEach(model.conflicts, id: \.self) { c in
                    HStack {
                        Text(c).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button(model.freeing ? "Working…" : "Free Them", action: model.freeShortcuts).disabled(model.freeing)
                    }
                }
                if model.screenshotsFreed && model.conflicts.isEmpty {
                    HStack {
                        Text("macOS's own shortcuts for these keys are off.").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button(model.freeing ? "Working…" : "Turn Them Back On", action: model.restoreShortcuts).disabled(model.freeing)
                    }
                }
            }

            step(done: !model.viewerKeysFailed, title: "See every workspace at once") {
                Toggle("The Mission Control key and ⌃↑ open BaneySpaces' overview", isOn: Binding(get: { model.viewerKeys }, set: { model.setViewerKeys($0) }))
                if model.viewerKeysFailed {
                    Text("macOS didn't let BaneySpaces watch those keys, so they still open Mission Control. Turn the switch off and on to try again. The overview is always in the menu bar menu.")
                        .font(.callout).foregroundStyle(.orange)
                } else {
                    Text("Turn this off to give both keys back to Mission Control and to apps that use ⌃↑. The overview stays in the menu bar menu.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Text("⌘Tab switches")
                    Picker("", selection: Binding(get: { model.cmdTab }, set: { model.setCmdTab($0) })) {
                        ForEach(MissionControlKeys.CmdTabMode.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Text(cmdTabNote).font(.callout).foregroundStyle(.secondary)
                HStack {
                    Toggle("Workspace Dock in place of the macOS Dock", isOn: Binding(get: { model.workspaceDock }, set: { model.setWorkspaceDock($0) }))
                    Spacer()
                    Picker("", selection: Binding(get: { model.dockEdge }, set: { model.dockEdge = $0; model.onDockEdgeChange?($0) })) {
                        ForEach(DockEdge.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize().disabled(!model.workspaceDock)
                }
                Text("Rest the pointer on the dock's edge of the screen to see your workspaces, each with its apps; click one to go there. At the top it waits a moment longer, so reaching for the menu bar doesn't bring it up. The macOS Dock stays out of sight while this is on and comes back as it was when you turn it off or quit BaneySpaces.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            step(done: true, title: "Find and install apps") {
                Toggle("⌘Space opens the BaneySpaces launcher instead of Spotlight", isOn: Binding(get: { model.launcherOnCmdSpace }, set: { model.setLauncher($0) }))
                Text("Open apps, install and remove them, search the web and ask an agent, from one box. Off gives ⌘Space back to Spotlight; the launcher stays in the menu bar and the Workspace Dock.")
                    .font(.callout).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        Text("Search the web with")
                        Picker("", selection: $model.searchEngine) { ForEach(Bangs.engines, id: \.trigger) { Text($0.name).tag($0.trigger) } }
                            .labelsHidden().fixedSize()
                    }
                    GridRow {
                        Text("Ask questions (?) with")
                        Picker("", selection: $model.agent) { ForEach(Bangs.agents, id: \.trigger) { Text($0.name).tag($0.trigger) } }
                            .labelsHidden().fixedSize()
                    }
                }
                Text("Type !yt cats, !i sunsets or ? a question. Type ! to see every bang.")
                    .font(.callout).foregroundStyle(.secondary)
                DisclosureGroup("Your bangs\(model.customBangs.isEmpty ? "" : " (\(model.customBangs.count))")") { bangEditor.padding(.top, 6) }
            }

            if model.desktops > 1 {
                step(done: false, title: "Optional: keep one macOS desktop") {
                    Text("You have \(model.desktops) desktops in Mission Control. Windows on the others are out of reach. Open Mission Control, hover each extra desktop at the top, and click its close button.")
                        .foregroundStyle(.secondary)
                    Button("Open Mission Control") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
                    }
                }
            }

            step(done: model.openAtLogin, title: "Start with your Mac") {
                Toggle("Open BaneySpaces at login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
                if model.loginNeedsApproval {
                    HStack {
                        Text("macOS needs you to approve it in Login Items.").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Approve in Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            }

            Divider()
            HStack {
                Text("Full screen works as usual; switching workspaces takes a window out of it first. Change anything later from the menu bar icon.")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    /// Your own bangs: each a trigger, a name and an address with {q} where the words go.
    private var bangEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.customBangs, id: \.trigger) { b in
                HStack {
                    Text("!\(b.trigger)").monospaced().frame(width: 70, alignment: .leading)
                    Text(b.name + (b.isAgent ? " (agent)" : "")).lineLimit(1)
                    Text(b.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { model.removeBang(b.trigger) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Remove !\(b.trigger)")
                }
            }
            HStack {
                TextField("trigger", text: $model.newTrigger).frame(width: 70)
                TextField("Name", text: $model.newName).frame(width: 100)
                TextField("https://example.com/search?q={q}", text: $model.newURL)
            }
            .textFieldStyle(.roundedBorder)
            HStack {
                Toggle("It's an AI agent", isOn: $model.newIsAgent)
                Spacer()
                Button("Add Bang", action: model.addBang)
            }
            if let why = model.bangProblem { Text(why).font(.callout).foregroundStyle(.orange) }
            Text(verbatim: "A bang with a built-in's trigger replaces it. Agents and scripts can add them too:")
                .font(.caption).foregroundStyle(.secondary)
            Text(verbatim: "~/Applications/BaneySpaces.app/Contents/MacOS/BaneySpaces --bangs add jira Jira 'https://acme.atlassian.net/browse/{q}'")
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private var cmdTabNote: String {
        switch model.cmdTab {
        case .off: "macOS's own app switcher. It only reaches apps on the workspace you're on."
        case .apps: "Hold ⌘ and tap Tab to step through every app with a window, on any workspace, most recent first; let go to go straight to it. ⌘⇧Tab steps back and Esc cancels."
        case .workspaces: "Hold ⌘ and tap Tab to step through your workspaces, most recent first; let go to go there. ⌘⇧Tab steps back and Esc cancels."
        }
    }

    private func step<Content: View>(done: Bool, title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(done ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content()
            }
        }
    }
}

final class SetupWindowController: NSWindowController, NSWindowDelegate {
    let model = SetupModel()
    private var activeObserver: NSObjectProtocol?

    convenience init() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        self.init(window: window)
        window.title = "Set Up BaneySpaces"
        window.delegate = self
        let host = NSHostingView(rootView: SetupView(model: model) { [weak window] in window?.close() })
        // The window grows and shrinks with the steps shown.
        host.sizingOptions = [.preferredContentSize]
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.center()
        // On grant: come forward, celebrate, then get out of the way.
        model.onReady = { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.window?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.model.ready, self.window?.isVisible == true else { return }
                self.window?.close()
            }
        }
        // Coming back from System Settings re-checks at once instead of waiting for the next tick.
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            guard self?.window?.isVisible == true else { return }
            self?.model.reload()
        }
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        model.justEnabled = false
        model.reload()
        model.startWatching()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ n: Notification) {
        model.stopWatching()
        model.finish()
    }
}
