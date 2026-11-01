import AppKit
import Combine
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
    @Published var topDrag = TopDragWatcher.enabled
    var onTopDragChange: ((Bool) -> Void)?
    @Published var cmdTab = MissionControlKeys.cmdTabMode
    var onCmdTabChange: ((MissionControlKeys.CmdTabMode) -> Void)?
    @Published var workspaceDock = WorkspaceDock.enabled
    var onWorkspaceDockChange: ((Bool) -> Void)?
    @Published var dockEdge = WorkspaceDock.edge
    var onDockEdgeChange: ((DockEdge) -> Void)?
    @Published var dockAgentStatus = WorkspaceDock.agentStatus
    var onDockAgentStatusChange: ((Bool) -> Void)?
    /// Whether Claude Code and Grok report to BaneySpaces; agent badges need it.
    enum HookState { case on, off, noClaudeCode, unreadable }
    var hooksInstalled: () -> HookState = { .on }
    var onInstallHooks: (() -> Void)?
    @Published var hooks: HookState = .on
    @Published var tab: SettingsTab = .general {
        // The app list changes while the window is open; it's read when you look at it.
        didSet {
            if tab == .automation { reloadParked() }
            if tab == .updates { onUpdatesShown?() }
        }
    }
    var onUninstall: (() -> Void)?
    /// Everything the menu bar menu's Options, Updates and About items used to do (2026-10-31).
    var onBringBack: (() -> Void)?
    var onAbout: (() -> Void)?
    /// An app that can be kept usable by automation: its windows are parked, not hidden.
    struct ParkedRow: Identifiable, Equatable {
        let id: String
        let name: String
        var on: Bool
        /// It slides its windows when moved, so it is hidden even with the box checked.
        var animates: Bool
    }
    @Published var parkedRows: [ParkedRow] = []
    /// The parked list is read when the tab appears, the window takes the keyboard, or an app
    /// launches or quits (`SetupWindowController`), not on every tick: it walks every window.
    var parkedApps: () -> [ParkedRow] = { [] }
    /// BaneySpaces has started (Accessibility allowed, AeroSpace gone). Automation waits for it.
    @Published var started = true
    var isStarted: () -> Bool = { true }
    /// Why Automation can't act yet, or nil.
    var automationReason: String? { AutomationGate.reason(trusted: trusted, aeroSpaceRunning: aeroSpaceRunning, started: started) }
    var onToggleParked: ((String) -> Void)?
    /// BaneySpaces' own updates: the build you have, the channel, and any release waiting.
    struct UpdateInfo: Equatable {
        var have = ""
        var channel = UpdateChannel.stable
        var daily = true
        var nightlyNeedsTools = false
        /// A release waiting, or installing.
        var notice: UpdateNotice?
    }
    @Published var update = UpdateInfo()
    var updateInfo: () -> UpdateInfo = { UpdateInfo() }
    /// The Updates tab came up: look again for the command line tools, which a Mac can gain while this runs.
    var onUpdatesShown: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onOfferUpdate: (() -> Void)?
    var onSetUpdateChannel: ((UpdateChannel) -> Void)?
    var onSetCheckDaily: ((Bool) -> Void)?
    /// Agents that finished while you were away, newest to oldest; a click goes to the agent.
    struct FinishedRow: Identifiable, Equatable { let id: String; let label: String }
    @Published var finished: [FinishedRow] = []
    var finishedRows: () -> [FinishedRow] = { [] }
    var onFocusFinished: ((String) -> Void)?

    /// Goes to the agent, which marks it seen; the list drops it at once instead of at the next tick.
    func focusFinished(_ id: String) {
        onFocusFinished?(id)
        finished = finishedRows()
    }
    @Published var launcherOnCmdSpace = Launcher.onCmdSpace
    @Published var searchEngine = Launcher.searchEngine { didSet { Launcher.searchEngine = searchEngine } }
    @Published var agent = Launcher.agent { didSet { Launcher.agent = agent } }
    @Published var customBangs = Launcher.readCustomBangs().bangs
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
        hooks = hooksInstalled()
        let info = updateInfo()
        if info != update { update = info }
        let rows = finishedRows()
        if rows != finished { finished = rows }
        let running = isStarted()
        if running != started { started = running }
    }

    func reloadParked() {
        let rows = parkedApps()
        if rows != parkedRows { parkedRows = rows }
    }

    func toggleParked(_ id: String) {
        onToggleParked?(id)
        reloadParked()
    }

    func setUpdateChannel(_ channel: UpdateChannel) {
        onSetUpdateChannel?(channel)
        update = updateInfo()
    }

    func setCheckDaily(_ on: Bool) {
        onSetCheckDaily?(on)
        update = updateInfo()
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

    func setTopDrag(_ on: Bool) {
        topDrag = on
        onTopDragChange?(on)
    }

    func setCmdTab(_ mode: MissionControlKeys.CmdTabMode) {
        cmdTab = mode
        onCmdTabChange?(mode)
    }

    func setWorkspaceDock(_ on: Bool) {
        workspaceDock = on
        onWorkspaceDockChange?(on)
    }

    func setDockAgentStatus(_ on: Bool) {
        dockAgentStatus = on
        onDockAgentStatusChange?(on)
    }

    func installHooks() {
        onInstallHooks?()
        hooks = hooksInstalled()
    }

    func setLauncher(_ on: Bool) {
        launcherOnCmdSpace = on
        onLauncherChange?(on)
    }

    func addBang() {
        if let why = Bangs.problem(trigger: newTrigger, name: newName, url: newURL) { bangProblem = why; return }
        let bang = Bang(trigger: newTrigger, name: newName, url: newURL, agent: newIsAgent)
        do {
            customBangs = try Launcher.updateCustomBangs { Bangs.adding(bang, to: $0) ?? $0 }
            newTrigger = ""; newName = ""; newURL = ""; newIsAgent = false
            bangProblem = nil
        } catch {
            bangProblem = error.localizedDescription
        }
    }

    func removeBang(_ trigger: String) {
        do {
            customBangs = try Launcher.updateCustomBangs { $0.filter { $0.trigger != trigger } }
            bangProblem = nil
        } catch {
            bangProblem = error.localizedDescription
        }
    }

    /// Bangs changed elsewhere (the file, an agent) show up when setup opens.
    func reloadBangs() {
        let read = Launcher.readCustomBangs()
        customBangs = read.bangs
        bangProblem = read.problems.first
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

/// The settings window's tabs. General comes first: it's where a new Mac starts.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General", keys = "Keys", dock = "Dock", appearance = "Appearance", launcher = "Launcher",
         automation = "Automation", updates = "Updates"
    var id: Self { self }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .keys: "keyboard"
        case .dock: "dock.rectangle"
        case .appearance: "paintpalette"
        case .launcher: "magnifyingglass"
        case .automation: "gearshape.2"
        case .updates: "arrow.down.circle"
        }
    }
}

/// BaneySpaces' settings: a tab for each part, so nothing sits below the bottom of a laptop
/// screen. It opens on General until BaneySpaces has what it needs to run.
struct SetupView: View {
    @ObservedObject var model: SetupModel
    @ObservedObject private var appearance = Appearance.shared
    var close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.tab) {
                ForEach(SettingsTab.allCases) { t in Label(t.rawValue, systemImage: t.symbol).tag(t) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 4)
            VStack(alignment: .leading, spacing: 18) {
                switch model.tab {
                case .general: general
                case .keys: keys
                case .dock: dock
                case .appearance: appearanceTab
                case .launcher: launcher
                case .automation: automation
                case .updates: updates
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(24)
            Divider()
            HStack {
                // About the app as a whole, so only under General; on another tab it read like a stray note.
                if model.tab == .general {
                    Text("Full screen works as usual; switching workspaces takes a window out of it first. Change anything later with Settings… in the menu bar icon's menu (⌘,).")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 560)
    }

    // MARK: General

    @ViewBuilder private var general: some View {
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

        step(done: true, title: "Uninstall", symbol: "trash") {
            // Text across the full width, the button under it, as the Allow step lays out; side by
            // side, the text wrapped into a narrow four-line column beside a floating button.
            Text("Puts back your windows, the macOS Dock, the screenshot and Spotlight shortcuts and your Claude Code settings as they were, then removes BaneySpaces.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Uninstall BaneySpaces…") { model.onUninstall?() }
        }
    }

    // MARK: Keys

    @ViewBuilder private var keys: some View {
        section("Workspace keys") {
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

        section("See every workspace at once") {
            Toggle("The Mission Control key and ⌃↑ open BaneySpaces' overview", isOn: Binding(get: { model.viewerKeys }, set: { model.setViewerKeys($0) }))
            if model.viewerKeysFailed {
                Text("macOS didn't let BaneySpaces watch those keys, so they still open Mission Control. Turn the switch off and on to try again. The overview is always in the menu bar menu (Show All Workspaces).")
                    .font(.callout).foregroundStyle(.orange)
            } else {
                Text("Turn this off to give both keys back to Mission Control and to apps that use ⌃↑. The overview stays in the menu bar menu.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Toggle("Dragging a window to the top of the screen opens the overview", isOn: Binding(get: { model.topDrag }, set: { model.setTopDrag($0) }))
            Text("Let go over a workspace to send the window there; let go at the top and it fills the screen. Mission Control for that drag stays off while this is on, and comes back when you turn it off.")
                .font(.callout).foregroundStyle(.secondary)
        }

        section("⌘Tab") {
            Picker("⌘Tab switches", selection: Binding(get: { model.cmdTab }, set: { model.setCmdTab($0) })) {
                ForEach(MissionControlKeys.CmdTabMode.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()
            Text(cmdTabNote).font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: Dock

    @ViewBuilder private var dock: some View {
        section("Workspace Dock") {
            Toggle("Workspace Dock in place of the macOS Dock", isOn: Binding(get: { model.workspaceDock }, set: { model.setWorkspaceDock($0) }))
            Text("Rest the pointer on the dock's edge of the screen to see your workspaces, each with its apps; click one to go there. At the top it waits a moment longer, so reaching for the menu bar doesn't bring it up. The macOS Dock stays out of sight while this is on and comes back as it was when you turn it off or quit BaneySpaces.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("Position on screen", selection: Binding(get: { model.dockEdge }, set: { model.dockEdge = $0; model.onDockEdgeChange?($0) })) {
                ForEach(DockEdge.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .fixedSize().disabled(!model.workspaceDock)
        }

        section("Agent status") {
            Toggle("Show what coding agents are doing on their app icons", isOn: Binding(get: { model.dockAgentStatus }, set: { model.setDockAgentStatus($0) }))
                .disabled(!model.workspaceDock)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                legend(AgentStatusBadge(state: .working, size: 16), "Working")
                legend(AgentStatusBadge(state: .asking, size: 16), "Asking you something, such as a permission")
                legend(AgentStatusBadge(state: .failed, size: 16), "Stopped on an error")
                legend(Text("1").font(.system(size: 10, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                        .frame(width: 16, height: 16).background(Circle().fill(Color.orange)),
                       "Finished while you were away (on the workspace's corner)")
            }
            .opacity(model.dockAgentStatus && model.workspaceDock ? 1 : 0.4)
            Text("Click an app with a badge to go straight to that agent's tab. Off, the dock shows apps only.")
                .font(.callout).foregroundStyle(.secondary)
        }

        if !model.finished.isEmpty {
            section("Finished while you were away") {
                ForEach(model.finished) { row in
                    Button { model.focusFinished(row.id) } label: {
                        Label(row.label, systemImage: "checkmark.circle").lineLimit(1)
                    }
                    .buttonStyle(.link)
                }
            }
        }

        section("Agent hooks") {
            if model.hooks == .noClaudeCode {
                Text("Claude Code isn't set up on this Mac (there's no ~/.claude/settings.json). Once it is, install the hooks here.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Install Claude Code and Grok Hooks", action: model.installHooks)
            } else if model.hooks == .unreadable {
                Text("~/.claude/settings.json isn't valid JSON, so BaneySpaces leaves it alone. Fix it, then come back here.")
                    .font(.callout).foregroundStyle(.orange)
            } else if model.hooks == .on {
                Label("Claude Code and Grok report to BaneySpaces.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text("Hooks let Claude Code and Grok say when they start, finish, ask for permission or hit an error. Without them BaneySpaces reads only terminal titles.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Install Claude Code and Grok Hooks", action: model.installHooks)
            }
        }
    }

    private func legend<Badge: View>(_ badge: Badge, _ text: String) -> some View {
        GridRow {
            badge.frame(width: 18, alignment: .center)
            Text(text).font(.callout)
        }
    }

    // MARK: Automation

    @ViewBuilder private var automation: some View {
        section("Keep usable by automation") {
            Text("Checked apps aren't hidden on other workspaces, so tools like Cua can still click and type in them. Their windows are parked just out of view instead.")
                .font(.callout).foregroundStyle(.secondary)
            if let why = model.automationReason {
                Text(why).font(.callout).foregroundStyle(.orange)
            }
            if model.parkedRows.isEmpty {
                if model.automationReason == nil { Text("No apps with windows yet.").font(.callout).foregroundStyle(.secondary) }
            } else {
                // Past eight, the list scrolls, so the window never runs off a laptop screen.
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.parkedRows) { row in
                            Toggle(row.on && row.animates ? "\(row.name) (hidden: it animates window moves)" : row.name,
                                   isOn: Binding(get: { row.on }, set: { _ in model.toggleParked(row.id) }))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: CGFloat(min(model.parkedRows.count, 8)) * 24)
                .disabled(model.automationReason != nil)
            }
        }

        section("If windows get tangled") {
            Text("Gathers every window onto workspace 1, all visible. It gets you out of any tangle.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Bring Every Window Back") { model.onBringBack?() }.disabled(model.automationReason != nil)
        }
    }

    // MARK: Updates

    @ViewBuilder private var updates: some View {
        section("Software update") {
            Text("You have \(model.update.have).").foregroundStyle(.secondary)
            if let notice = model.update.notice, notice.installing {
                Label(notice.menuTitle, systemImage: "arrow.down.circle")
            } else if let notice = model.update.notice {
                HStack {
                    Label(notice.sentence, systemImage: "arrow.down.circle.fill").font(.headline)
                    Spacer()
                    Button(notice.menuTitle) { model.onOfferUpdate?() }
                }
                Text("Shows what's new first. Nothing installs until you press Update Now.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Picker("Follow", selection: Binding(get: { model.update.channel }, set: { model.setUpdateChannel($0) })) {
                Text("Stable: tested releases").tag(UpdateChannel.stable)
                Text(model.update.nightlyNeedsTools ? "Nightly: needs Apple's command line tools" : "Nightly: newest changes, every night").tag(UpdateChannel.nightly)
            }
            .pickerStyle(.radioGroup)
            Toggle("Check for updates daily", isOn: Binding(get: { model.update.daily }, set: { model.setCheckDaily($0) }))
            Button("Check for Updates Now…") { model.onCheckForUpdates?() }
        }

        section("About") {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("BaneySpaces").font(.title3.bold())
                    Text("Nine workspaces on one keyboard row.").foregroundStyle(.secondary)
                    Text("\(model.modifier.symbol)1–\(model.modifier.symbol)9 to switch. Add ⇧ to bring the window along.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Button("About BaneySpaces…") { model.onAbout?() }
        }
    }

    // MARK: Appearance

    @ViewBuilder private var appearanceTab: some View {
        appearancePreview

        section("Accent") {
            HStack(spacing: 7) {
                ForEach(AccentPreset.allCases, id: \.self) { p in
                    swatch(Appearance.color(p.rgb), selected: appearance.settings.accent == .preset(p), name: p.title) {
                        appearance.settings.accent = .preset(p)
                    }
                }
                Divider().frame(height: 18)
                Button { appearance.settings.accent = .system } label: {
                    HStack(spacing: 5) {
                        Circle().fill(Appearance.color(Appearance.systemAccent)).frame(width: 10, height: 10)
                        Text("System").font(.callout)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().strokeBorder(appearance.settings.accent == .system ? Color.primary : Color.secondary.opacity(0.35),
                                                       lineWidth: appearance.settings.accent == .system ? 2 : 1))
                }
                .buttonStyle(.plain)
                .help("Follow the accent color in System Settings")
                ColorPicker("Custom accent", selection: Binding(
                    get: { Appearance.color(appearance.settings.accentRGB(system: Appearance.systemAccent)) },
                    set: { picked in
                        // The picker also answers with the color it was shown; that isn't a pick.
                        guard let rgb = Appearance.rgb(picked) else { return }
                        let shown = appearance.accentRGB
                        guard abs(rgb.r - shown.r) + abs(rgb.g - shown.g) + abs(rgb.b - shown.b) > 0.01 else { return }
                        appearance.settings.accent = .custom(rgb)
                    }), supportsOpacity: false)
                    .labelsHidden()
                    .help("Pick any color")
            }
        }

        section("Workspace colors") {
            HStack(spacing: 12) {
                Picker("Workspace colors", selection: Binding(get: { appearance.settings.palette }, set: { appearance.settings.palette = $0 })) {
                    ForEach(WorkspacePalette.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 280)
                Spacer()
                Button("Reset") { appearance.settings.resetOverrides() }
                    .disabled(appearance.settings.overrides.isEmpty)
                    .help("Clear the colors picked for single workspaces")
            }
            HStack(spacing: 6) {
                ForEach(1...9, id: \.self) { n in
                    VStack(spacing: 1) {
                        ColorPicker("Workspace \(n)", selection: Binding(
                            get: { Chrome.workspace(n) },
                            set: { picked in
                                // The picker also answers with the color it was shown; that isn't a pick.
                                guard let rgb = Appearance.rgb(picked) else { return }
                                let shown = appearance.settings.workspaceColor(n, accent: appearance.accentRGB).rgb
                                guard abs(rgb.r - shown.r) + abs(rgb.g - shown.g) + abs(rgb.b - shown.b) > 0.01 else { return }
                                appearance.settings.overrides[n] = rgb
                            }), supportsOpacity: false)
                            .labelsHidden()
                        Text("\(n)").font(.caption2.weight(.semibold)).foregroundStyle(appearance.settings.overrides[n] == nil ? Color.secondary : Color.primary)
                    }
                }
            }
            Text("Click a color to change one workspace. Bright colors are dimmed so the numbers stay readable.")
                .font(.callout).foregroundStyle(.secondary)
        }

        section("Panels") {
            HStack(spacing: 12) {
                Picker("Panel style", selection: Binding(get: { appearance.settings.panelStyle }, set: { appearance.settings.panelStyle = $0 })) {
                    ForEach(PanelStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                Slider(value: Binding(get: { appearance.settings.panelOpacity }, set: { appearance.settings.panelOpacity = $0 }),
                       in: AppearanceSettings.panelOpacityRange)
                    .accessibilityLabel("Panel opacity")
                    .frame(width: 120)
                    .disabled(appearance.settings.panelStyle == .solid)
                Text("\(Int((appearance.settings.effectivePanelOpacity * 100).rounded()))%")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
            }
            Text("Dock, ⌘Tab, launcher, overview and switch overlay. Solid is always opaque.")
                .font(.callout).foregroundStyle(.secondary)
        }

        section("Dock size") {
            Picker("Dock size", selection: Binding(get: { appearance.settings.dockSize }, set: { appearance.settings.dockSize = $0 })) {
                ForEach(DockSize.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 220)
        }
    }

    /// A small dock in the current look, so changes show without opening the real one.
    private var appearancePreview: some View {
        let k = CGFloat(appearance.settings.dockSize.scale)
        return HStack(spacing: 8) {
            ForEach(1...3, id: \.self) { n in
                let current = n == 2
                let tint = Chrome.workspace(n)
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(current ? tint.opacity(0.26) : Color.white.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(current ? Chrome.accent : Color.white.opacity(0.08), lineWidth: current ? 2 : 1))
                        .overlay(Image(systemName: "app.fill").font(.system(size: 18 * k)).foregroundStyle(.white.opacity(0.35)))
                        .frame(width: 44 * k, height: 44 * k)
                    WorkspaceBadge(n: n, size: 16)
                }
            }
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
        .background(Chrome.panelBackground(cornerRadius: 18))
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the Workspace Dock")
    }

    private func swatch(_ color: Color, selected: Bool, name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle().fill(color).frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.9 : 0.15), lineWidth: selected ? 2 : 1))
                .padding(2)
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Launcher

    @ViewBuilder private var launcher: some View {
        section("Find and install apps") {
            Toggle("⌘Space opens the BaneySpaces launcher instead of Spotlight", isOn: Binding(get: { model.launcherOnCmdSpace }, set: { model.setLauncher($0) }))
            Text("Open apps, install and remove them, find files, terminal tabs and splits, browser tabs and agent windows, search the web and ask an agent, from one box. ⌃⌘K opens it from any app. Off gives ⌘Space back to Spotlight; the launcher stays in the menu bar, the Workspace Dock and ⌃⌘K.")
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
        }
        section("Your bangs\(model.customBangs.isEmpty ? "" : " (\(model.customBangs.count))")") { bangEditor }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Notes wrap instead of trailing off.
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Your own bangs: each a trigger, a name and an address with {q} where the words go.
    private var bangEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Past six, the list scrolls, so the window never runs off a laptop screen.
            ScrollView {
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
                }
            }
            .frame(height: model.customBangs.isEmpty ? 0 : CGFloat(min(model.customBangs.count, 6)) * 22)
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

    private func step<Content: View>(done: Bool, title: String, symbol: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol ?? (done ? "checkmark.circle.fill" : "circle"))
                .font(.title3)
                .foregroundStyle(symbol != nil ? Color.secondary : done ? Color.green : Color.secondary)
                .frame(width: 22)
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
    /// The window taking the keyboard, and apps launching or quitting: kept so `deinit` can remove them.
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var sizing: AnyCancellable?

    convenience init() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        self.init(window: window)
        window.title = "BaneySpaces Settings"
        window.delegate = self
        let host = NSHostingView(rootView: SetupView(model: model) { [weak window] in window?.close() })
        // Its size comes from the content. With .preferredContentSize the hosting view reported
        // 0×0 on macOS 27 and the window opened invisible (2026-10-16, on main too).
        host.sizingOptions = [.intrinsicContentSize]
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.center()
        // The window grows and shrinks with the tab and the steps shown, its top edge holding still.
        // Many changes land at once (the 0.25 s permission check reassigns several), so they're
        // folded into one refit per pass of the main loop.
        var pending = false
        sizing = model.objectWillChange.sink { [weak window, weak host] _ in
            guard !pending else { return }
            pending = true
            DispatchQueue.main.async {
                pending = false
                guard let window, let host else { return }
                host.layoutSubtreeIfNeeded()
                let size = host.fittingSize
                guard size.height > 0, size != window.contentRect(forFrameRect: window.frame).size else { return }
                let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
                window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - frame.height, width: frame.width, height: frame.height),
                                display: true, animate: window.isVisible)
            }
        }
        // On grant: come forward, celebrate, then get out of the way.
        model.onReady = { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.window?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.model.ready, self.window?.isVisible == true else { return }
                self.window?.close()
            }
        }
        // The window taking the keyboard (opened, or clicked back to) reads the lists again.
        observers.append((NotificationCenter.default, NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            self?.model.reload()
            self?.model.reloadParked()
        }))
        // An app launching or quitting changes the list on the Automation tab; a launch has no
        // windows for a moment, so it's read again after the first scan.
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, delay) in [(NSWorkspace.didLaunchApplicationNotification, 1.5), (NSWorkspace.didTerminateApplicationNotification, 0.3)] {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard let self, self.window?.isVisible == true, self.model.tab == .automation else { return }
                    self.model.reloadParked()
                }
            }))
        }
        // Coming back from System Settings re-checks at once instead of waiting for the next tick.
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            guard self?.window?.isVisible == true else { return }
            self?.model.reload()
        }
    }

    deinit {
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        for o in observers { o.center.removeObserver(o.token) }
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        model.justEnabled = false
        if !model.ready { model.tab = .general }
        model.dockAgentStatus = WorkspaceDock.agentStatus
        model.reload()
        model.reloadParked()
        if model.tab == .updates { model.onUpdatesShown?() }
        model.reloadBangs()
        model.startWatching()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ n: Notification) {
        model.stopWatching()
        model.finish()
    }
}
