import AppKit
import BaneySpacesCore

/// Moves real windows to match the workspace model. Hidden windows wait at the bottom-right
/// corner of the screen, so every app keeps running and nothing is minimized or closed.
///
/// A window is hidden exactly when `saved` holds its frame. That record, not where the window
/// happens to sit, decides what to show, so a display change or an app nudging its own window
/// can't make BaneySpaces lose track of it.
final class Spaces {
    private(set) var model = Workspaces()
    private var saved: SavedFrames
    private var windows: [WindowID: Window] = [:]
    private var switching = false
    /// Timing of the switch in progress, for timing.log: start, after the window scan, at the wait.
    private var clock = SwitchClock()
    /// Shortcuts pressed mid-switch run, in order, once it finishes.
    private var queued: [() -> Void] = []
    /// Until then, app activations come from BaneySpaces' own switch, not the person.
    private var settleUntil = Date.distantPast
    /// Bumped on every switch, so a late focus check from an older switch stands down.
    private var generation = 0
    var onChange: (() -> Void)?

    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BaneySpaces")
    static let framesURL = folder.appendingPathComponent("frames.json")
    static let stateURL = folder.appendingPathComponent("state.json")

    init() {
        saved = SavedFrames.load(from: Spaces.framesURL)
    }

    /// Takes stock of every window. Windows a crash left hidden go back to their saved frame;
    /// any other window that is mostly off screen (another window manager's leftovers, an
    /// unplugged display) is centered.
    func start() {
        for pid in saved.hiddenApps { NSRunningApplication(processIdentifier: pid)?.unhide() }
        refresh()
        let screens = Windows.screens()
        for w in windows.values {
            // Only stranded windows move. Window numbers are reused after a logout, so a saved
            // frame must never move a window that is already in plain sight.
            guard !w.isMinimized, let f = w.frame, Geometry.isStranded(f, screens: screens) else { continue }
            w.setFrame(Geometry.restoreFrame(saved: saved.frames[w.id], size: f.size, screens: screens))
        }
        saved = SavedFrames()
        persist()
        flattenFullScreen()
    }

    func refresh() {
        let list = Windows.all()
        let alive = Windows.alive()
        // Accessibility lists only the windows on the macOS desktop being shown. A window it
        // missed keeps the handle from an earlier listing; that handle still moves the window.
        var next = windows.filter { alive.contains($0.key) }
        for w in list { next[w.id] = w }
        windows = next
        let added = model.sync(seen: list.map(\.id), alive: alive)
        saved.frames = saved.frames.filter { alive.contains($0.key) }
        saved.hiddenApps = saved.hiddenApps.filter { NSRunningApplication(processIdentifier: $0).map { !$0.isTerminated } ?? false }
        // An app that autosaves its window position can reopen a window at the hiding spot.
        let screens = Windows.screens()
        for id in added {
            guard let w = windows[id], !w.isMinimized, let f = w.frame, Geometry.isStranded(f, screens: screens) else { continue }
            w.setFrame(Geometry.restoreFrame(saved: nil, size: f.size, screens: screens))
        }
    }

    /// `takeFocus: false` rearranges windows without touching focus, for moves made from the
    /// viewer while it holds the keyboard.
    func switchTo(_ n: Int, takeFocus moveFocus: Bool = true) {
        guard Workspaces.range.contains(n) else { return }
        if switching { return queued.append { [weak self] in self?.switchTo(n, takeFocus: moveFocus) } }
        clock = SwitchClock(target: n)
        refresh()
        clock.mark(.scanned)
        if let f = Windows.focused(in: Array(windows.values)), model.workspace(of: f.id) == model.current {
            model.noteFocus(f.id)
        }
        let plan = model.switchTo(n)
        switching = true
        generation += 1

        // Full screen is normally flattened as soon as it happens (see flattenFullScreen). This
        // catches a window that went full screen in the moment before a switch.
        let fullScreen = plan.hide.compactMap { windows[$0] }.filter(\.isFullScreen)
        guard !fullScreen.isEmpty else { return apply(plan, moveFocus: moveFocus) }
        leaveFullScreen(fullScreen) { [self] refused in
            // A window that won't leave full screen stays with you rather than strand you on its desktop.
            for w in refused { model.assign(w.id, to: n) }
            // Back on the regular desktop, Accessibility can list windows it couldn't see from the
            // full-screen one. Plan again with all of them.
            refresh()
            apply(model.switchTo(n), moveFocus: moveFocus)
        }
    }

    /// macOS full screen moves a window to a desktop of its own, where BaneySpaces can't hide or
    /// show it, and Mission Control fills up with extra desktops. So in BaneySpaces, full screen
    /// means filling the screen: a window that goes full screen comes back out and fills it.
    /// Runs at launch and whenever macOS changes desktops.
    func flattenFullScreen() {
        if switching { return queued.append { [weak self] in self?.flattenFullScreen() } }
        refresh()
        let fullScreen = windows.values.filter(\.isFullScreen)
        guard !fullScreen.isEmpty else { return }
        switching = true
        generation += 1
        leaveFullScreen(fullScreen) { [self] _ in
            refresh()
            persist()
            switching = false
            onChange?()
            while !switching, !queued.isEmpty { queued.removeFirst()() }
        }
    }

    /// Takes windows out of full screen and fills the screen with each. Calls back with the
    /// windows that refused.
    private func leaveFullScreen(_ fullScreen: [Window], then: @escaping ([Window]) -> Void) {
        fullScreen.forEach { $0.exitFullScreen() }
        // Some apps (Chromium browsers among them) ignore the request. Their green button doesn't.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            fullScreen.filter(\.isFullScreen).forEach { $0.pressFullScreenButton() }
        }
        waitUntil(timeout: 4, { fullScreen.allSatisfy { !$0.isFullScreen } }) {
            // The exit animation keeps resizing the window for a moment after the flag flips.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                var refused: [Window] = []
                for w in fullScreen {
                    if w.isFullScreen {
                        refused.append(w)
                        NSSound.beep()
                    } else if let f = w.frame {
                        w.setFrame(Windows.visibleArea(near: f))
                    }
                }
                then(refused)
            }
        }
    }

    /// Sends the focused window to workspace `n` and follows it there.
    func moveFocused(to n: Int) {
        guard Workspaces.range.contains(n) else { return }
        if switching { return queued.append { [weak self] in self?.moveFocused(to: n) } }
        refresh()
        guard let w = Windows.focused(in: Array(windows.values)) else {
            NSLog("BaneySpaces: no window to move (focused app pid %d)", Windows.focusedPid() ?? -1)
            return NSSound.beep()
        }
        model.assign(w.id, to: n)
        switchTo(n)
    }

    /// Clicking a Dock icon or using ⌘Tab can focus a window on another workspace. Go there,
    /// and land on the window that was picked.
    func appActivated(_ app: NSRunningApplication) {
        guard app.processIdentifier != getpid(), Date() > settleUntil else { return }
        if switching { return queued.append { [weak self] in self?.followFocus() } }
        followFocus()
    }

    private func followFocus() {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return }
        refresh()
        guard let w = Windows.focused(of: app.processIdentifier, in: Array(windows.values)),
              let n = model.workspace(of: w.id) else { return }
        model.noteFocus(w.id)
        if n != model.current { switchTo(n) } else { persist() }
    }

    /// Every window onto workspace 1, all visible. The way out of any tangle.
    func gatherOnOne() {
        if switching { return queued.append { [weak self] in self?.gatherOnOne() } }
        refresh()
        for id in model.home.keys { model.assign(id, to: 1) }
        switchTo(1)
    }

    /// Puts every hidden window back on screen. Runs on quit, so BaneySpaces never strands a
    /// window. A window it can't reach right now keeps its saved frame for the next launch.
    func restoreAll() {
        refresh()
        let screens = Windows.screens()
        for (id, frame) in saved.frames {
            guard let w = windows[id], restore(w, to: frame, screens: screens) else { continue }
            saved.frames[id] = nil
        }
        for pid in saved.hiddenApps { NSRunningApplication(processIdentifier: pid)?.unhide() }
        saved.hiddenApps = []
        persist()
    }

    /// The display layout changed: put hidden windows at the new hiding spot.
    func screensChanged() {
        if switching { return queued.append { [weak self] in self?.screensChanged() } }
        switchTo(model.current)
    }

    /// One window as the viewer shows it.
    struct Entry: Identifiable {
        let id: WindowID
        let pid: pid_t
        let app: String
        let title: String
    }

    /// The windows on workspace `n`, for the viewer.
    func entries(on n: Int) -> [Entry] {
        model.windows(on: n).compactMap { id in
            windows[id].map { Entry(id: id, pid: $0.pid, app: $0.appName, title: $0.title) }
        }
    }

    /// Records the window in front, so closing the viewer (or any switch back here) returns to it.
    func rememberFocus() {
        refresh()
        if let f = Windows.focused(in: Array(windows.values)), model.workspace(of: f.id) == model.current {
            model.noteFocus(f.id)
        }
        persist()
    }

    /// Goes to workspace `n` and lands on one particular window there.
    func focus(_ id: WindowID, on n: Int) {
        if switching { return queued.append { [weak self] in self?.focus(id, on: n) } }
        // Picking a minimized window in the viewer means wanting it back.
        if let w = windows[id], w.isMinimized { w.unminimize() }
        model.noteFocus(id)
        switchTo(n)
    }

    /// Sends one window to workspace `n` without going there.
    func move(_ id: WindowID, to n: Int) {
        guard Workspaces.range.contains(n) else { return }
        if switching { return queued.append { [weak self] in self?.move(id, to: n) } }
        model.assign(id, to: n)
        switchTo(model.current, takeFocus: false)
    }

    /// App names on workspace `n`, for the menu.
    func apps(on n: Int) -> [String] {
        var seen = Set<String>()
        return model.windows(on: n).compactMap { windows[$0]?.appName }.filter { seen.insert($0).inserted }
    }

    private func apply(_ plan: SwitchPlan, moveFocus: Bool = true) {
        let screens = Windows.screens()
        let how = Concealment(plan: plan, owner: windows.mapValues(\.pid))
        // 1. Everything on this workspace comes back. That includes an app hidden with ⌘H:
        //    going to its workspace means wanting to see it.
        for pid in how.showApps {
            if let app = NSRunningApplication(processIdentifier: pid), app.isHidden { app.unhide() }
            saved.hiddenApps.remove(pid)
        }
        for id in plan.show {
            guard let frame = saved.frames[id], let w = windows[id] else { continue }
            if restore(w, to: frame, screens: screens) { saved.frames[id] = nil }
        }
        // 2. Focus moves before anything hides. Hiding the app in front makes macOS pick another
        //    app to activate, and an Electron app may un-hide itself in the shuffle. Once the new
        //    workspace's window is in front, the apps being hidden are all in the background.
        let target = ([plan.focus].compactMap { $0 } + plan.show)
            .compactMap { windows[$0] }.first { !$0.isMinimized && saved.frames[$0.id] == nil }
        let frontPid = target?.pid ?? getpid()
        if moveFocus {
            if let target {
                emptyHolder.orderOut(nil)
                target.focus()
            } else {
                takeFocus()
            }
        }
        clock.mark(.shown)
        waitUntil(timeout: moveFocus ? 0.6 : 0, { Windows.focusedPid() == frontPid }) { [self] in
            clock.mark(.focused)
            // 3. Everything else goes out of sight.
            conceal(how, screens: screens)
            if moveFocus, target == nil, Windows.focusedPid() != getpid() {
                // Finder is the last resort, unless it was just hidden: activating a hidden app
                // brings back its windows from other workspaces.
                takeFocus(finderFallback: !how.hideApps.contains(Self.finderPid ?? -1))
            }
            clock.mark(.done)
            clock.log(to: Spaces.folder.appendingPathComponent("timing.log"))
            persist()
            settleUntil = Date().addingTimeInterval(0.3)
            switching = false
            onChange?()
            while !switching, !queued.isEmpty { queued.removeFirst()() }
        }
    }

    private func conceal(_ how: Concealment, screens: [CGRect]) {
        // Apps with nothing here are hidden whole, as ⌘H does.
        for pid in how.hideApps {
            guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
            // hide() can report failure and still hide the app, so record every request.
            app.hide()
            saved.hiddenApps.insert(pid)
        }
        // A hidden app's parked windows can go home now; nobody sees them move.
        for (id, frame) in saved.frames {
            guard let w = windows[id], how.hideApps.contains(w.pid) else { continue }
            if restore(w, to: frame, screens: screens) { saved.frames[id] = nil }
        }
        // Only windows whose app also has a window here need parking out of view.
        let spot = Geometry.hidingSpot(screens: screens)
        for id in how.park {
            guard let w = windows[id], !w.isMinimized else { continue }
            if saved.frames[id] == nil {
                // Visible until now: remember where it stood. No readable frame, no parking.
                guard let f = w.frame else { continue }
                saved.frames[id] = f
            }
            w.setOrigin(spot)
        }
    }

    /// Brings a parked window back and reads it back. A busy app can drop the move, so the
    /// window only counts as shown once it is actually on screen; otherwise it stays parked in
    /// the record and the next switch tries again.
    private func restore(_ w: Window, to frame: CGRect, screens: [CGRect]) -> Bool {
        guard let f = w.frame else { return false }
        w.setFrame(Geometry.restoreFrame(saved: frame, size: f.size, screens: screens))
        guard let now = w.frame else { return false }
        return !Geometry.isStranded(now, screens: screens)
    }

    /// Called when BaneySpaces stops being the active app: the holder's job is over.
    func dropEmptyHolder() { emptyHolder.orderOut(nil) }

    private lazy var emptyHolder: NSPanel = {
        let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.alphaValue = 0.01
        p.ignoresMouseEvents = true
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        return p
    }()

    private static var finderPid: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier
    }

    /// Nothing on this workspace can take focus, so BaneySpaces takes it and typing goes nowhere.
    /// If macOS won't hand it over, Finder gets it, as on an empty Mac desktop.
    private func takeFocus(finderFallback: Bool = false) {
        Windows.makeFrontmost(getpid())
        NSApp.activate(ignoringOtherApps: true)
        // An app with no window loses focus to whatever macOS picks next, which would pull the
        // person off the empty workspace. A clear, click-through window keeps focus here.
        emptyHolder.orderFrontRegardless()
        emptyHolder.makeKey()
        guard finderFallback, Windows.focusedPid() != getpid(), let finder = Self.finderPid else { return }
        Windows.makeFrontmost(finder)
    }

    private func persist() {
        saved.save(to: Spaces.framesURL)
        // state.json is for scripts and checks: the current workspace and where each window lives.
        let state: [String: Any] = [
            "current": model.current,
            "parked": saved.frames.keys.sorted(),
            "hiddenApps": saved.hiddenApps.sorted(),
            "lastFocused": Dictionary(uniqueKeysWithValues: model.lastFocused.map { (String($0.key), $0.value) }),
            "workspaces": Dictionary(uniqueKeysWithValues: Workspaces.range.map { n in
                (String(n), model.windows(on: n).map { ["id": $0, "app": windows[$0]?.appName ?? ""] as [String: Any] })
            }),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Spaces.stateURL, options: .atomic)
        }
    }

    private func waitUntil(timeout: TimeInterval, _ done: @escaping () -> Bool, then: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            guard done() || Date() > deadline else { return }
            timer.invalidate()
            then()
        }
    }
}

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// How long one switch takes, phase by phase. Appended to timing.log so speed changes are
/// measured on real use, not guessed.
struct SwitchClock {
    enum Phase: String { case scanned, shown, focused, done }
    var target = 0
    private let start = CFAbsoluteTimeGetCurrent()
    private var marks: [(Phase, Double)] = []

    init(target: Int = 0) { self.target = target }

    mutating func mark(_ p: Phase) { marks.append((p, (CFAbsoluteTimeGetCurrent() - start) * 1000)) }

    func log(to url: URL) {
        let parts = marks.map { "\($0.0.rawValue)=\(Int($0.1.rounded()))" }.joined(separator: " ")
        let line = "\(Int(Date().timeIntervalSince1970)) ws=\(target) \(parts)\n"
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        lines.append(String(line.dropLast()))
        try? (lines.suffix(500).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

