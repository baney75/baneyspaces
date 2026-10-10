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
    /// False after `suspend()`: nothing moves until `start()` runs again.
    private var active = false
    /// Timing of the switch in progress, for timing.log.
    private var clock = SwitchClock()
    /// Work requested mid-switch runs in order once it finishes. Workspace switches collapse to
    /// the last one pressed, so ⌘2 ⌘3 ⌘4 in quick succession lands on 4 without stopping at 2 and 3.
    private var queued: [() -> Void] = []
    private var queuedSwitch: (n: Int, focus: Bool, announce: Bool)?
    /// An app activation arrived mid-switch that BaneySpaces didn't cause: check once afterwards.
    private var followPending = false
    /// The app our own switch is bringing forward. Its activation is ours, not the person's.
    private var expectedFront: pid_t?
    private var settleUntil = Date.distantPast
    /// Window layer-0 numbers and app pids at the last full Accessibility scan.
    private var lastScan: (windows: Set<WindowID>, pids: Set<pid_t>)?
    /// Windows that ignored every request to leave macOS full screen. Asking again only stalls.
    private var refusedFullScreen = Set<WindowID>()
    private lazy var watcher = FocusWatcher { [weak self] pid in self?.focusMovedWithin(pid) }
    private let hud = SwitchHUD()
    private var screensWork: DispatchWorkItem?
    var onChange: (() -> Void)?

    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BaneySpaces")
    static let framesURL = folder.appendingPathComponent("frames.json")
    static let stateURL = folder.appendingPathComponent("state.json")
    private static let writer = DispatchQueue(label: "com.baney.baneyspaces.persist", qos: .utility)

    init() {
        saved = SavedFrames.load(from: Spaces.framesURL)
    }

    /// Takes stock of every window. Windows a crash left hidden go back to their saved frame;
    /// any other window that is mostly off screen (another window manager's leftovers, an
    /// unplugged display) is centered.
    func start() {
        active = true
        for pid in saved.hiddenApps { NSRunningApplication(processIdentifier: pid)?.unhide() }
        refresh(full: true)
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

    /// Puts every window back and stops managing them, for when macOS withdraws permission.
    /// `start()` picks up again.
    func suspend() {
        guard active else { return }
        restoreAll()
        active = false
        switching = false
        queued.removeAll()
        queuedSwitch = nil
        followPending = false
        watcher.removeAll()
        emptyHolder.orderOut(nil)
    }

    /// Brings the window list up to date. Unless `full`, the Accessibility scan (one round trip
    /// per app, the slowest part of a switch) is skipped when no app window opened or closed
    /// and no app launched or quit since the last scan.
    func refresh(full: Bool = false) {
        let pids = RunningApps.regular
        let snap = Windows.snapshot(apps: pids)
        clock.mark(.snap)
        if !full, let last = lastScan, last.windows == snap.appWindows, last.pids == pids {
            prune(alive: snap.alive)
            clock.scan = "skip"
            return
        }
        clock.scan = lastScan == nil ? "first" : last(lastScan!, snap.appWindows, pids)
        let list = Windows.all(owners: snap.owners)
        // Accessibility lists only the windows on the macOS desktop being shown. A window it
        // missed keeps the handle from an earlier listing; that handle still moves the window.
        var next = windows.filter { snap.alive.contains($0.key) }
        for w in list { next[w.id] = w }
        windows = next
        let added = model.sync(seen: list.map(\.id), alive: snap.alive)
        prune(alive: snap.alive)
        lastScan = (snap.appWindows, pids)
        watcher.sync(pids)
        let screens = Windows.screens()
        // An app that autosaves its window position can reopen a window at the hiding spot.
        for id in added {
            guard let w = windows[id], !w.isMinimized, let f = w.frame, Geometry.isStranded(f, screens: screens) else { continue }
            w.setFrame(Geometry.restoreFrame(saved: nil, size: f.size, screens: screens))
        }
        // A window recorded as parked on the workspace being shown, yet back in plain sight
        // (an app that applied our move late), is simply shown. Its old record would otherwise
        // send it back to a stale spot later.
        for id in saved.frames.keys where model.workspace(of: id) == model.current {
            if let f = windows[id]?.frame, !Geometry.isStranded(f, screens: screens) { saved.frames[id] = nil }
        }
    }

    /// Why a full scan ran, for timing.log.
    private func last(_ l: (windows: Set<WindowID>, pids: Set<pid_t>), _ w: Set<WindowID>, _ p: Set<pid_t>) -> String {
        if l.pids != p { return "apps" }
        return "windows+\(w.subtracting(l.windows).count)-\(l.windows.subtracting(w).count)"
    }

    private func prune(alive: Set<WindowID>) {
        windows = windows.filter { alive.contains($0.key) }
        model.sync(seen: [], alive: alive)
        saved.frames = saved.frames.filter { alive.contains($0.key) }
        saved.hiddenApps = saved.hiddenApps.filter { NSRunningApplication(processIdentifier: $0).map { !$0.isTerminated } ?? false }
        refusedFullScreen.formIntersection(alive)
    }

    /// `takeFocus: false` rearranges windows without touching focus, for moves made from the
    /// viewer while it holds the keyboard. `announce` flashes the workspace HUD.
    func switchTo(_ n: Int, takeFocus moveFocus: Bool = true, announce: Bool = true) {
        guard active, Workspaces.range.contains(n) else { return }
        if switching { queuedSwitch = (n, moveFocus, announce); return }
        if announce, moveFocus { hud.show(n) }
        clock = SwitchClock(target: n)
        refresh()
        clock.mark(.scanned)
        let focused = Windows.focused(in: Array(windows.values))
        if let f = focused, model.workspace(of: f.id) == model.current { model.noteFocus(f.id) }
        let plan = model.switchTo(n)
        switching = true
        // The menu bar number changes the moment the key is pressed, not when the work is done.
        onChange?()

        // Full screen is flattened as soon as it happens (see flattenFullScreen). This catches the
        // window in front having gone full screen in the moment before a switch.
        guard let f = focused, plan.hide.contains(f.id), !refusedFullScreen.contains(f.id), f.isFullScreen else {
            return apply(plan, moveFocus: moveFocus)
        }
        leaveFullScreen([f]) { [self] refused in
            // A window that won't leave full screen stays with you rather than strand you on its desktop.
            for w in refused { model.assign(w.id, to: n) }
            // Back on the regular desktop, Accessibility can list windows it couldn't see from the
            // full-screen one. Plan again with all of them.
            refresh(full: true)
            apply(model.switchTo(n), moveFocus: moveFocus)
        }
    }

    /// macOS full screen moves a window to a desktop of its own, where BaneySpaces can't hide or
    /// show it, and Mission Control fills up with extra desktops. So in BaneySpaces, full screen
    /// means filling the screen: a window that goes full screen comes back out and fills it.
    /// Runs at launch and whenever macOS changes desktops.
    func flattenFullScreen() {
        guard active else { return }
        if switching { return queued.append { [weak self] in self?.flattenFullScreen() } }
        refresh(full: true)
        let fullScreen = windows.values.filter { !refusedFullScreen.contains($0.id) && $0.isFullScreen }
        guard !fullScreen.isEmpty else { return }
        switching = true
        leaveFullScreen(fullScreen) { [self] _ in
            refresh(full: true)
            persist()
            finish()
        }
    }

    /// Takes windows out of full screen and fills the screen with each. Calls back with the
    /// windows that refused, which are remembered so they aren't asked again.
    private func leaveFullScreen(_ fullScreen: [Window], then: @escaping ([Window]) -> Void) {
        fullScreen.forEach { $0.exitFullScreen() }
        // Some apps (Chromium browsers among them) ignore the request. Their green button doesn't.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            fullScreen.filter(\.isFullScreen).forEach { $0.pressFullScreenButton() }
        }
        waitUntil(timeout: 4, interval: 0.05, { fullScreen.allSatisfy { !$0.isFullScreen } }) {
            // The exit animation keeps resizing the window for a moment after the flag flips.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
                var refused: [Window] = []
                for w in fullScreen {
                    if w.isFullScreen {
                        refused.append(w)
                        refusedFullScreen.insert(w.id)
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
        guard active, Workspaces.range.contains(n) else { return }
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
    /// and land on the window that was picked. Activations BaneySpaces caused are ignored.
    func appActivated(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard active, pid != getpid() else { return }
        if switching {
            if pid != expectedFront { followPending = true }
            return
        }
        if pid == expectedFront, Date() < settleUntil { return }
        followFocus()
    }

    private func followFocus() {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return }
        refresh()
        guard let w = Windows.focused(of: app.processIdentifier, in: Array(windows.values)),
              let n = model.workspace(of: w.id) else { return }
        model.noteFocus(w.id)
        if n != model.current { switchTo(n, announce: true) } else { persist() }
    }

    /// The front app moved focus to another of its windows without an app switch, as after ⌘W
    /// or ⌘`. If that window belongs to another workspace, typing would land in a window you
    /// can't see. Stay on this workspace: focus the app's window here, or hide the app if it
    /// has none.
    private func focusMovedWithin(_ pid: pid_t) {
        guard active, !switching, Date() > settleUntil,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
        refresh()
        guard let w = Windows.focused(of: pid, in: Array(windows.values)),
              let n = model.workspace(of: w.id), n != model.current || saved.frames[w.id] != nil else { return }
        if let here = model.windows(on: model.current).compactMap({ windows[$0] })
            .first(where: { $0.pid == pid && !$0.isMinimized && saved.frames[$0.id] == nil }) {
            expectedFront = pid
            settleUntil = Date().addingTimeInterval(0.3)
            here.focus()
        } else {
            switchTo(model.current, announce: false)
        }
    }

    /// Every window onto workspace 1, all visible. The way out of any tangle.
    func gatherOnOne() {
        guard active else { return }
        if switching { return queued.append { [weak self] in self?.gatherOnOne() } }
        refresh(full: true)
        for id in model.home.keys { model.assign(id, to: 1) }
        switchTo(1)
    }

    /// Puts every hidden window back on screen. Runs on quit, so BaneySpaces never strands a
    /// window. A window it can't reach right now keeps its saved frame for the next launch.
    func restoreAll() {
        refresh(full: true)
        let screens = Windows.screens()
        for (id, frame) in saved.frames {
            guard let w = windows[id], restore(w, to: frame, screens: screens) else { continue }
            saved.frames[id] = nil
        }
        for pid in saved.hiddenApps { NSRunningApplication(processIdentifier: pid)?.unhide() }
        saved.hiddenApps = []
        persist()
    }

    /// The display layout changed: put hidden windows at the new hiding spot. macOS sends a burst
    /// of these on wake and on plugging in a display, so act once, after it settles, and leave
    /// focus where it is (a dialog may hold it).
    func screensChanged() {
        screensWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active else { return }
            if self.switching { return self.queued.append { [weak self] in self?.screensChanged() } }
            self.switchTo(self.model.current, takeFocus: false, announce: false)
        }
        screensWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
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
        guard active else { return }
        if switching { return queued.append { [weak self] in self?.focus(id, on: n) } }
        // Picking a minimized window in the viewer means wanting it back.
        if let w = windows[id], w.isMinimized { w.unminimize() }
        model.noteFocus(id)
        switchTo(n)
    }

    /// Sends one window to workspace `n` without going there.
    func move(_ id: WindowID, to n: Int) {
        guard active, Workspaces.range.contains(n) else { return }
        if switching { return queued.append { [weak self] in self?.move(id, to: n) } }
        model.assign(id, to: n)
        switchTo(model.current, takeFocus: false, announce: false)
    }

    /// App names on workspace `n`, for the menu.
    func apps(on n: Int) -> [String] {
        var seen = Set<String>()
        return model.windows(on: n).compactMap { windows[$0]?.appName }.filter { seen.insert($0).inserted }
    }

    private func apply(_ plan: SwitchPlan, moveFocus: Bool = true) {
        let screens = Windows.screens()
        let how = Concealment(plan: plan, owner: windows.mapValues(\.pid))
        let oldFront = NSWorkspace.shared.frontmostApplication?.processIdentifier
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
        // 2. Everything else leaves at once, except the app in front. Hiding a background app
        //    changes nothing about focus, so there's no reason to wait for it.
        let deferred: Set<pid_t> = moveFocus ? Set([oldFront].compactMap { $0 }).intersection(how.hideApps) : []
        conceal(how, apps: how.hideApps.subtracting(deferred), screens: screens)
        // 3. Focus moves to this workspace. Only then does the old front app hide: hiding the app
        //    in front makes macOS activate another app on its own, which would look like the
        //    person picking it.
        let target = ([plan.focus].compactMap { $0 } + plan.show)
            .compactMap { windows[$0] }.first { !$0.isMinimized && saved.frames[$0.id] == nil }
        let frontPid = target?.pid ?? getpid()
        expectedFront = frontPid
        if moveFocus {
            if let target {
                emptyHolder.orderOut(nil)
                target.focus()
            } else {
                takeFocus()
            }
        }
        clock.mark(.shown)
        let done = { [self] in
            clock.mark(.focused)
            conceal(how, apps: deferred, screens: screens)
            if moveFocus, target == nil, Windows.focusedPid() != getpid() {
                // Finder is the last resort, unless it was just hidden: activating a hidden app
                // brings back its windows from other workspaces.
                takeFocus(finderFallback: !how.hideApps.contains(Self.finderPid ?? -1))
            }
            clock.mark(.done)
            clock.log(to: Spaces.folder.appendingPathComponent("timing.log"))
            persist()
            settleUntil = Date().addingTimeInterval(0.3)
            finish()
        }
        // Nothing left that depends on focus: finish now, without waiting a timer tick.
        if deferred.isEmpty || Windows.focusedPid() == frontPid { return done() }
        waitUntil(timeout: 0.5, interval: 0.01, { Windows.focusedPid() == frontPid }, then: done)
    }

    /// Ends a switch and runs what queued up during it: actions in order, then the last
    /// workspace pressed, then one check of an activation BaneySpaces didn't cause.
    private func finish() {
        switching = false
        onChange?()
        while !switching, !queued.isEmpty { queued.removeFirst()() }
        if !switching, let next = queuedSwitch {
            queuedSwitch = nil
            switchTo(next.n, takeFocus: next.focus, announce: next.announce)
        }
        if !switching, followPending {
            followPending = false
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != expectedFront { followFocus() }
        }
    }

    private func conceal(_ how: Concealment, apps: Set<pid_t>, screens: [CGRect]) {
        // Apps with nothing here are hidden whole, as ⌘H does.
        for pid in apps {
            guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
            // hide() can report failure and still hide the app, so record every request.
            app.hide()
            saved.hiddenApps.insert(pid)
        }
        // A hidden app's parked windows can go home now; nobody sees them move.
        for (id, frame) in saved.frames {
            guard let w = windows[id], apps.contains(w.pid) else { continue }
            if restore(w, to: frame, screens: screens) { saved.frames[id] = nil }
        }
        // Only windows whose app also has a window here need parking out of view. Parking
        // doesn't touch focus, so it happens with the first batch.
        guard apps != [] || how.park.isEmpty == false else { return }
        let spot = Geometry.hidingSpot(screens: screens)
        for id in how.park {
            guard let w = windows[id], !w.isMinimized, saved.frames[id] == nil || w.frame.map({ !Geometry.isStranded($0, screens: screens) }) == true else { continue }
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
        w.place(Geometry.restoreFrame(saved: frame, size: f.size, screens: screens), currentSize: f.size)
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

    /// Saves the parked-window record and state.json. The snapshot is taken here; the disk
    /// writes happen off the main thread so they never delay a switch.
    private func persist() {
        let frames = saved
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
        Spaces.writer.async {
            frames.save(to: Spaces.framesURL)
            if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: Spaces.stateURL, options: .atomic)
            }
        }
    }

    private func waitUntil(timeout: TimeInterval, interval: TimeInterval, _ done: @escaping () -> Bool, then: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
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
    enum Phase: String { case snap, scanned, shown, focused, done }
    var target = 0
    var scan = "full"
    private let start = CFAbsoluteTimeGetCurrent()
    private var marks: [(Phase, Double)] = []

    init(target: Int = 0) { self.target = target }

    mutating func mark(_ p: Phase) { marks.append((p, (CFAbsoluteTimeGetCurrent() - start) * 1000)) }

    func log(to url: URL) {
        let parts = marks.map { "\($0.0.rawValue)=\(Int($0.1.rounded()))" }.joined(separator: " ")
        let line = "\(Int(Date().timeIntervalSince1970)) ws=\(target) scan=\(scan) \(parts)\n"
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        lines.append(String(line.dropLast()))
        try? (lines.suffix(500).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

