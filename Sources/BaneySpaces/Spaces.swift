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
    private(set) var switching = false
    /// False after `suspend()`: nothing moves until `start()` runs again.
    private var active = false
    /// Timing of the switch in progress, for timing.log.
    private var clock = SwitchClock()
    /// Work requested mid-switch runs in order once it finishes. Workspace switches collapse to
    /// the last one pressed, so ⌘2 ⌘3 ⌘4 in quick succession lands on 4 without stopping at 2 and 3.
    private var queued: [Queued] = []
    private enum Queued {
        case switchTo(n: Int, focus: Bool, announce: Bool)
        case action(() -> Void)
    }
    /// Bumped by every switch and by `suspend()`. A timer or callback from an earlier switch
    /// checks it and stands down, so late work never lands on top of newer work.
    private var generation = 0
    /// An app activation arrived mid-switch that BaneySpaces didn't cause: check once afterwards.
    private var followPending = false
    /// The app our own switch is bringing forward. Its activation is ours, not the person's.
    private var expectedFront: pid_t?
    private var settleUntil = Date.distantPast
    /// Window layer-0 numbers and app pids at the last full Accessibility scan.
    /// `unsure` holds apps that scan couldn't read; once one is willing to answer again, scan again.
    /// `offscreen` is the known windows of shown apps that weren't on screen: one joining them
    /// may have been closed (see `closedWindows`), so it's worth a scan.
    private var lastScan: (windows: Set<WindowID>, pids: Set<pid_t>, unsure: Set<pid_t>, offscreen: Set<WindowID>)?
    /// Windows that ignored every request to leave macOS full screen. Asking again only stalls.
    private var refusedFullScreen = Set<WindowID>()
    private lazy var watcher = FocusWatcher { [weak self] pid in self?.focusMovedWithin(pid) }
    private let hud = SwitchHUD()
    /// Saved workspaces for windows not seen yet this launch. A hidden or busy app may not answer
    /// at startup; when its window shows up later it goes back where it was, and until then its
    /// entry stays in the saved layout instead of being forgotten.
    private var pendingLayout: [WindowID: SavedLayout.Entry] = [:]
    /// Windows dropped as closed (see `closedWindows`), with their workspace and parked frame. A
    /// tab behind another tab looks closed too. When its app lists it again out of sight (the
    /// tab in front of a parked window closed), it goes back to its workspace. One that comes back
    /// in sight was opened or picked here, and joins the workspace you're on like any new window.
    private var dormant: [WindowID: (pid: pid_t, workspace: Int, frame: CGRect?)] = [:]
    /// Workspaces from most to least recently visited, for the ⌘Tab switcher.
    private(set) var recent: [Int] = [1]
    private var screensWork: DispatchWorkItem?
    var onChange: (() -> Void)?

    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BaneySpaces")
    static let framesURL = folder.appendingPathComponent("frames.json")
    static let stateURL = folder.appendingPathComponent("state.json")
    static let layoutURL = folder.appendingPathComponent("layout.json")
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
        var unreached: [WindowID: CGRect] = [:]
        let server = Windows.serverWindows()
        for w in windows.values {
            // Only stranded windows move. Window numbers are reused after a logout, so a saved
            // frame must never move a window that is already in plain sight.
            guard let f = w.frame else {
                // A busy app keeps its parked window's record, so a later switch brings it back.
                // Only a window really sitting at the hiding spot: numbers are reused after a restart.
                if let s = saved.frames[w.id], let b = server[w.id]?.bounds, Geometry.isStranded(b, screens: screens) { unreached[w.id] = s }
                continue
            }
            guard !w.isMinimized, Geometry.isStranded(f, screens: screens) else { continue }
            w.setFrame(Geometry.restoreFrame(saved: saved.frames[w.id], size: f.size, screens: screens))
        }
        saved = SavedFrames()
        saved.frames = unreached
        // Put every window back on the workspace it had before this launch (an update, a crash,
        // a restart), and return to the workspace you were on.
        if let layout = SavedLayout.load(from: Spaces.layoutURL) {
            model.restore(current: layout.current, home: layout.homes(livePids: windows.mapValues(\.pid)),
                          lastFocused: layout.lastFocused)
            // Window numbers are reused after a restart, so a waiting window must still belong
            // to the same app; otherwise its entry would unhide a stranger.
            let server = Windows.serverWindows()
            pendingLayout = Dictionary(uniqueKeysWithValues: layout.entries
                .filter { model.workspace(of: $0.window) == nil && server[$0.window]?.pid == $0.pid }.map { ($0.window, $0) })
        }
        persist()
        switchTo(model.current, takeFocus: false, announce: false)
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
        followPending = false
        generation += 1
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
        if !full, let last = lastScan, last.windows == snap.appWindows, last.pids == pids,
           last.offscreen == offscreenKnown(snap.offscreen) {
            prune(alive: snap.alive)
            clock.scan = "skip"
            return
        }
        let firstScan = lastScan == nil
        clock.scan = firstScan ? "first" : last(lastScan!, snap.appWindows, pids)
        RunningApps.invalidate()
        let pidsNow = RunningApps.regular
        let (list, unsure, listed, partial) = Windows.all(owners: snap.owners)
        // A window the app closed but kept isn't one any more, though the window server says it's alive.
        let answered = pidsNow.intersection(snap.owners).subtracting(unsure).subtracting(partial)
        let closed = closedWindows(listed: listed, answered: answered, offscreen: snap.offscreen)
        for id in closed {
            guard let ws = model.workspace(of: id), let pid = snap.offscreen[id] else { continue }
            dormant[id] = (pid, ws, saved.frames[id])
        }
        let alive = snap.alive.subtracting(closed)
        dormant = dormant.filter { snap.alive.contains($0.key) }
        // Accessibility lists only the windows on the macOS desktop being shown. A window it
        // missed keeps the handle from an earlier listing; that handle still moves the window.
        var next = windows.filter { alive.contains($0.key) }
        for w in list { next[w.id] = w }
        windows = next
        let added = model.sync(seen: list.map(\.id), alive: alive)
        prune(alive: alive)
        // A scan that skipped a busy app can't vouch for that app's windows. It's remembered, and
        // the next refresh scans again as soon as that app is willing to answer.
        lastScan = (snap.appWindows, pidsNow, unsure, offscreenKnown(snap.offscreen))
        watcher.sync(snap.owners)
        if !unsure.isEmpty || watcher.missing { scheduleRetry() }
        let screens = Windows.screens()
        // A window from the saved layout that only now answered goes back to its workspace.
        var returned = false
        var fromLayout = Set<WindowID>()
        for id in added {
            if let d = dormant.removeValue(forKey: id), windows[id]?.pid == d.pid,
               snap.offscreen[id] != nil || windows[id]?.frame.map({ Geometry.isStranded($0, screens: screens) }) == true {
                model.assign(id, to: d.workspace, focus: false)
                // A tab parked with its window: the parked frame may sit on the tab that closed.
                let frame = d.frame ?? dormant.values.first { $0.pid == d.pid && $0.workspace == d.workspace && $0.frame != nil }?.frame
                if d.workspace != model.current, let frame { saved.frames[id] = frame }
                fromLayout.insert(id)
                returned = returned || d.workspace != model.current
                continue
            }
            guard let entry = pendingLayout.removeValue(forKey: id), windows[id]?.pid == entry.pid else { continue }
            model.assign(id, to: entry.workspace, focus: false)
            fromLayout.insert(id)
            returned = returned || entry.workspace != model.current
        }
        // At launch every window is new; the saved layout decides where they go.
        if !firstScan { adoptBackgroundWindows(added.filter { !fromLayout.contains($0) }) }
        if returned, !switching {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active, !self.switching else { return }
                self.switchTo(self.model.current, takeFocus: false, announce: false)
            }
        }
        // An app that autosaves its window position can reopen a window at the hiding spot.
        // One that belongs on another workspace isn't moved into sight here: it's recorded as
        // parked, to come back to the middle of the screen when you go there.
        for id in added {
            guard let w = windows[id], !w.isMinimized, let f = w.frame, Geometry.isStranded(f, screens: screens) else { continue }
            let to = Geometry.restoreFrame(saved: nil, size: f.size, screens: screens)
            if model.workspace(of: id) == model.current { w.setFrame(to) } else if saved.frames[id] == nil { saved.frames[id] = to }
        }
        // A window recorded as parked on the workspace being shown, yet back in plain sight
        // (an app that applied our move late), is simply shown. Its old record would otherwise
        // send it back to a stale spot later.
        for id in saved.frames.keys where model.workspace(of: id) == model.current {
            if let f = windows[id]?.frame, !Geometry.isStranded(f, screens: screens) { saved.frames[id] = nil }
        }
    }

    /// A window that opens in a parked app (see `ParkedApps`) while that app stays in the
    /// background was opened by automation, not by you: it joins the app's other windows instead
    /// of landing on the workspace you're looking at. Decided a moment later, so a link you
    /// click (which brings the app forward) still opens the window where you are.
    private func adoptBackgroundWindows(_ added: [WindowID]) {
        let ids = ParkedApps.bundleIDs
        let candidates = added.filter { id in
            guard let w = windows[id] else { return false }
            return NSRunningApplication(processIdentifier: w.pid)?.bundleIdentifier.map(ids.contains) == true
        }
        guard !candidates.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.active else { return }
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            var moved = false
            for id in candidates {
                guard let w = self.windows[id], w.pid != front, self.model.workspace(of: id) == self.model.current else { continue }
                let others = self.windows.values.filter { $0.pid == w.pid && $0.id != id }.compactMap { self.model.workspace(of: $0.id) }
                guard !others.contains(self.model.current),
                      let home = self.recent.first(where: others.contains) ?? others.min() else { continue }
                self.model.assign(id, to: home, focus: false)
                moved = true
            }
            if moved { self.reapply() }
        }
    }

    /// Why a full scan ran, for timing.log.
    private func last(_ l: (windows: Set<WindowID>, pids: Set<pid_t>, unsure: Set<pid_t>, offscreen: Set<WindowID>), _ w: Set<WindowID>, _ p: Set<pid_t>) -> String {
        if l.pids != p { return "apps" }
        if l.windows == w { return "offscreen" }
        return "windows+\(w.subtracting(l.windows).count)-\(l.windows.subtracting(w).count)"
    }

    /// Known windows (and saved-layout ones still waiting) that their app closed but keeps:
    /// Ghostty keeps every window it closes, and a tab behind another tab is one too. The window
    /// server still counts them, so without this they stayed on their workspace for good, and
    /// ⌘Tab, the docks and the launcher sent you there for a window that never came forward.
    /// A window is closed only when its app answered and didn't list it, it isn't on screen, and
    /// it's on no macOS desktop or on one being shown. A minimized window, and a hidden app's,
    /// is still listed; one on another desktop, or in full screen, is on a desktop not shown.
    private func closedWindows(listed: Set<WindowID>, answered: Set<pid_t>, offscreen: [WindowID: pid_t]) -> Set<WindowID> {
        Set(Set(model.home.keys).union(pendingLayout.keys).filter { id in
            guard !listed.contains(id), let pid = offscreen[id], answered.contains(pid) else { return false }
            return Windows.onNoOtherDesktop(id)
        })
    }

    /// The known windows that are off screen while their app is shown, the ones `closedWindows`
    /// looks at. A hidden app's windows don't count: they leave the screen on every switch.
    private func offscreenKnown(_ offscreen: [WindowID: pid_t]) -> Set<WindowID> {
        var shown: [pid_t: Bool] = [:]
        return Set(offscreen.filter { id, pid in
            guard model.workspace(of: id) != nil || pendingLayout[id] != nil else { return false }
            if shown[pid] == nil { shown[pid] = NSRunningApplication(processIdentifier: pid)?.isHidden == false }
            return shown[pid]!
        }.keys)
    }

    /// Re-reads apps that a scan couldn't, once they're willing to answer again, in the
    /// background between switches, so the wait never lands on a key press.
    private var retryPending = false
    private func scheduleRetry() {
        guard !retryPending else { return }
        retryPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) { [weak self] in
            guard let self else { return }
            self.retryPending = false
            guard self.active else { return }
            self.watcher.retry()
            guard let unsure = self.lastScan?.unsure, unsure.contains(where: Windows.isResponsive) else {
                if self.lastScan?.unsure.isEmpty == false || self.watcher.missing { self.scheduleRetry() }
                return
            }
            if self.switching { return self.scheduleRetry() }
            self.refresh(full: true)
            self.persist()
        }
    }

    private func prune(alive: Set<WindowID>) {
        // The app in front closing its window here (⌘W) hands focus to another app.
        if windows.contains(where: { !alive.contains($0.key) && $0.value.pid == frontPid && model.workspace(of: $0.key) == model.current }) {
            leftAt = Date()
        }
        windows = windows.filter { alive.contains($0.key) }
        model.sync(seen: [], alive: alive)
        saved.frames = saved.frames.filter { alive.contains($0.key) }
        saved.hiddenApps = saved.hiddenApps.filter { NSRunningApplication(processIdentifier: $0).map { !$0.isTerminated } ?? false }
        refusedFullScreen.formIntersection(alive)
        pendingLayout = pendingLayout.filter { alive.contains($0.key) }
    }

    /// `takeFocus: false` rearranges windows without touching focus, for moves made from the
    /// viewer while it holds the keyboard. `announce` flashes the workspace HUD.
    func switchTo(_ n: Int, takeFocus moveFocus: Bool = true, announce: Bool = true) {
        guard active, Workspaces.range.contains(n) else { return }
        if switching {
            // Presses keep their order; only back-to-back switches collapse to the last one.
            if case .switchTo = queued.last { queued.removeLast() }
            queued.append(.switchTo(n: n, focus: moveFocus, announce: announce))
            return
        }
        // The HUD is drawn after the switch is under way, never in front of it, from the windows
        // the switch's own scan found.
        if announce, moveFocus {
            DispatchQueue.main.async { [self] in
                var seen = Set<pid_t>()
                let icons = model.windows(on: n).compactMap { windows[$0]?.pid }.filter { seen.insert($0).inserted }
                    .prefix(5).compactMap { NSRunningApplication(processIdentifier: $0)?.icon }
                hud.show(n, occupied: Set(Workspaces.range.filter { !model.windows(on: $0).isEmpty }), icons: Array(icons))
            }
        }
        generation += 1
        clock = SwitchClock(target: n)
        refresh()
        clock.mark(.scanned)
        let focused = Windows.focused(in: Array(windows.values))
        if let f = focused, model.workspace(of: f.id) == model.current { model.noteFocus(f.id) }
        let leaving = model.current
        let plan = model.switchTo(n)
        recent.removeAll { $0 == n }
        recent.insert(n, at: 0)
        switching = true
        // The menu bar number changes the moment the key is pressed, not when the work is done.
        onChange?()

        // Full screen lives on a macOS desktop of its own, which BaneySpaces can't hide. Any window
        // left behind in full screen (a video, a presentation), focused or not, leaves full screen
        // first. One that refused before comes along instead of staying stranded on its desktop.
        let full = fullScreen(among: plan.hide)
        // Rearranging the workspace you're on (a move from the overview) is on purpose: no carrying.
        let carried = n == leaving ? [] : full.filter { refusedFullScreen.contains($0.id) }
        for w in carried { model.assign(w.id, to: n, focus: false) }
        let asking = full.filter { !refusedFullScreen.contains($0.id) }
        guard !asking.isEmpty else {
            return apply(carried.isEmpty ? plan : model.switchTo(n), moveFocus: moveFocus)
        }
        let gen = generation
        let known = Set(model.home.keys).union(pendingLayout.keys)
        // macOS puts each window back where it was before full screen.
        leaveFullScreen(asking, fill: false) { [self] refused in
            guard gen == generation, active else { return }
            for w in refused { model.assign(w.id, to: n, focus: false) }
            // Back on the regular desktop, Accessibility can list windows it couldn't see from the
            // full-screen one. Those opened while you were on the workspace you just left.
            refresh(full: true)
            for id in Set(model.home.keys).subtracting(known) { model.assign(id, to: leaving, focus: false) }
            apply(model.switchTo(n), moveFocus: moveFocus)
        }
    }

    /// The windows among `ids` in macOS full screen. Only windows exactly the size of a screen are
    /// asked, so a switch with no full screen costs one window-server read. A window seen out
    /// of full screen is asked again next time, even if it once refused to leave.
    private func fullScreen(among ids: [WindowID]) -> [Window] {
        let sizes = Windows.fullScreenFrames()
        let server = Windows.serverWindows()
        func screenSized(_ b: CGRect) -> Bool {
            sizes.contains { abs($0.minX - b.minX) < 1 && abs($0.minY - b.minY) < 1 && abs($0.width - b.width) < 1 && abs($0.height - b.height) < 1 }
        }
        var found: [Window] = []
        for id in ids {
            // A hidden app's windows aren't on screen, and a hidden app can be slow to answer.
            guard let w = windows[id], NSRunningApplication(processIdentifier: w.pid)?.isHidden != true else { continue }
            guard let b = server[id]?.bounds, screenSized(b), w.isFullScreen else {
                if server[id]?.bounds.map(screenSized) == false { refusedFullScreen.remove(id) }
                continue
            }
            found.append(w)
        }
        return found
    }

    /// macOS full screen moves a window to a desktop of its own, where BaneySpaces can't hide or
    /// show it. Full screen you choose (a video, a presentation) stays until you switch
    /// workspaces; a window left in full screen from before BaneySpaces started comes back out
    /// at launch and fills the screen.
    func flattenFullScreen() {
        guard active else { return }
        if switching { return enqueue { [weak self] in self?.flattenFullScreen() } }
        refresh(full: true)
        let fullScreen = windows.values.filter { !refusedFullScreen.contains($0.id) && $0.isFullScreen }
        guard !fullScreen.isEmpty else { return }
        switching = true
        generation += 1
        let gen = generation
        leaveFullScreen(fullScreen, fill: true) { [self] _ in
            guard gen == generation, active else { return }
            refresh(full: true)
            persist()
            finish()
        }
    }

    /// Takes windows out of full screen, and with `fill` fills the screen with each. Calls back
    /// with the windows that refused, which are remembered so they aren't asked again.
    private func leaveFullScreen(_ fullScreen: [Window], fill: Bool, then: @escaping ([Window]) -> Void) {
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
                    } else if fill, let f = w.frame {
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
        if switching { return enqueue { [weak self] in self?.moveFocused(to: n) } }
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
        defer { frontPid = pid }
        Windows.markResponsive(pid)
        // Asked for by `openWindowHere`: its window is on the way, here.
        if let o = opening, o.pid == pid, Date() < o.until { return }
        activatedAt = Date()
        if switching {
            if pid != expectedFront { followPending = true }
            return
        }
        if pid == expectedFront, Date() < settleUntil { return }
        followFocus()
    }

    /// The window each app last had in focus, to tell a window closing (⌘W) from the person
    /// picking another window of the same app.
    private var lastKey: [pid_t: WindowID] = [:]
    /// A window a switch tried and failed to raise, until when. Focus moving elsewhere in that
    /// app meanwhile is the app catching up, not a choice.
    private var intended: [pid_t: (id: WindowID, until: Date)] = [:]

    /// The app's window on this workspace that should take focus, if it has one: the one used
    /// last here, or any visible one.
    private func windowHere(of pid: pid_t) -> Window? {
        let here = model.windows(on: model.current).compactMap { windows[$0] }
            .filter { $0.pid == pid && !$0.isMinimized && saved.frames[$0.id] == nil }
        if let last = model.lastFocused[model.current], let w = here.first(where: { $0.id == last }) { return w }
        return here.first
    }

    /// Focuses a window on this workspace, marking the activation as BaneySpaces' own.
    private func stay(on w: Window) {
        expectedFront = w.pid
        settleUntil = Date().addingTimeInterval(0.3)
        model.noteFocus(w.id)
        // Only a raise that landed makes this the window you were in.
        if w.focus() { lastKey[w.pid] = w.id }
    }

    /// An app came to the front (Dock click, ⌘Tab, a link opening it). If it has a window on this
    /// workspace, stay here and use that one: macOS tends to focus the app's most recent window,
    /// which may belong to another workspace. Only an app with nothing here takes you to its
    /// workspace.
    private func followFocus() {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return }
        // A newly activated app may have just become a regular app: re-read the app list, which
        // forces a full scan only if it changed.
        RunningApps.invalidate()
        refresh()
        let pid = app.processIdentifier
        guard let w = Windows.focused(of: pid, in: Array(windows.values)),
              let n = model.workspace(of: w.id) else { return }
        if n == model.current && saved.frames[w.id] == nil {
            lastKey[pid] = w.id
            model.noteFocus(w.id)
            // An app BaneySpaces hid, opening a window here: macOS unhid all of it, so its windows
            // from other workspaces are in sight too. They go back out of view.
            if strayed(pid) { return switchTo(model.current, announce: false) }
            return persist()
        }
        if let here = windowHere(of: pid) { return stay(on: here) }
        let known = Windows.standardIDs(of: pid)
        // When the app in front closes its last window here, quits or hides (a switch hiding it
        // too), macOS hands focus to the next app in line on its own: often one BaneySpaces just
        // put away, parked or hidden. That isn't you picking it: stay here, and an app the
        // activation unhid goes back into hiding. Following it pulled you off the workspace you
        // had just gone to, Finder or Ghostty a moment after you arrived.
        let putAway = (saved.frames[w.id] != nil && ParkedApps.contains(pid)) || saved.hiddenApps.contains(pid)
        // Timed from when the activation arrived: one that came mid-switch is only looked at once
        // the switch, parking included, is over.
        if putAway, activatedAt.timeIntervalSince(max(leftAt, handedOffAt)) < 0.5 {
            Trace.log("followFocus stayed: \(w.appName) came forward after the front app left")
            if let id = model.lastFocused[model.current], let t = windows[id], saved.frames[id] == nil, t.pid != pid {
                stay(on: t)
            } else {
                takeFocus()
            }
            if saved.hiddenApps.contains(pid) { hideOnceBehind(pid) }
            // Unless it came forward to open a window here after all (its New Window key, pressed
            // right after the switch): that window shows.
            waitUntil(timeout: 0.5, interval: 0.02, { !Windows.standardIDs(of: pid).subtracting(known).isEmpty }) { [self] in
                guard active, !switching else { return }
                _ = showNewWindow(of: pid, besides: known)
            }
            return
        }
        // An app opening a new window (a global New Window key, a file opened in it) comes
        // forward before the window exists, still focused on its window elsewhere: Ghostty's
        // came 54 ms after it activated. Give the window that long to show up here before
        // following the app away.
        let gen = generation
        following += 1
        let ticket = following
        waitUntil(timeout: Self.newWindowGrace, interval: 0.02, {
            !Windows.standardIDs(of: pid).subtracting(known).isEmpty
        }) { [self] in
            guard following == ticket, gen == generation, active, !switching,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            if showNewWindow(of: pid, besides: known) {
                return Trace.log("followFocus stayed: \(w.appName) opened a window here")
            }
            Trace.log("followFocus \(w.appName) to \(n)")
            lastKey[pid] = w.id
            model.noteFocus(w.id)
            switchTo(n, announce: true)
        }
    }

    /// Hides an app BaneySpaces put away that came forward on its own, once it's out of the front:
    /// hiding the app in front makes macOS pick yet another app. Not if it has a window here by
    /// then (one it opened).
    private func hideOnceBehind(_ pid: pid_t) {
        waitUntil(timeout: 0.3, interval: 0.01, { NSWorkspace.shared.frontmostApplication?.processIdentifier != pid }) { [self] in
            guard active, !model.windows(on: model.current).contains(where: { windows[$0]?.pid == pid }) else { return }
            // Still in front (focus didn't move here): the workspace is applied again instead,
            // which hides it the usual way.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier != pid else {
                return switching ? () : switchTo(model.current, announce: false)
            }
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isHidden else { return }
            ownHides.insert(pid)
            ownHidesUntil = Date().addingTimeInterval(1)
            app.hide()
            saved.hiddenApps.insert(pid)
        }
    }

    /// How long an app that came forward gets to open a window here before BaneySpaces follows
    /// it to its workspace. Long enough for an app to make a window after activating, short
    /// enough that a Dock click on an app elsewhere still feels immediate.
    private static let newWindowGrace: TimeInterval = 0.2
    /// Counts followFocus calls; one waiting out `newWindowGrace` stands down for a newer one.
    private var following = 0

    /// The app has windows on other workspaces that aren't out of view: it was unhidden.
    private func strayed(_ pid: pid_t) -> Bool {
        guard NSRunningApplication(processIdentifier: pid)?.isHidden == false else { return false }
        return windows.values.contains { $0.pid == pid && model.workspace(of: $0.id).map { $0 != model.current } == true
            && saved.frames[$0.id] == nil && !$0.isMinimized }
    }

    /// When the app in front last closed a window here, quit or hid. An activation right after
    /// that is macOS picking the next app, not you.
    private var leftAt = Date.distantPast
    /// When a switch last handed focus away from the app in front (hid it, left a parked app,
    /// or went to an empty workspace). macOS then picks an app to put in front on its own.
    private var handedOffAt = Date.distantPast
    /// When the last app activation BaneySpaces didn't ask for arrived.
    private var activatedAt = Date.distantPast
    /// An app `openWindowHere` asked for a window, until when: its coming forward isn't followed.
    private var opening: (pid: pid_t, until: Date)?
    /// The app in front, as of the last activation.
    private var frontPid: pid_t?
    /// Apps BaneySpaces itself just hid; their hide notifications arrive late.
    private var ownHides: Set<pid_t> = []
    private var ownHidesUntil = Date.distantPast

    /// An app quit or hid (⌘Q, ⌘H). Only the app in front counts, and not BaneySpaces' own hiding.
    func appLeft(_ pid: pid_t) {
        guard pid == frontPid, !(ownHides.contains(pid) && Date() < ownHidesUntil) else { return }
        leftAt = Date()
    }

    /// The front app moved focus to another of its windows without an app switch. Two cases:
    /// the window you were in closed (⌘W), and the app picked its next window on its own; or you
    /// chose a window yourself (the Window menu, ⌘`). A closed window keeps you on this workspace,
    /// so typing never lands in a hidden window. A window you chose takes you to its workspace.
    private func focusMovedWithin(_ pid: pid_t) {
        guard active, !switching, Date() > settleUntil,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
        refresh()
        guard let w = Windows.focused(of: pid, in: Array(windows.values)), let n = model.workspace(of: w.id) else { return }
        if let i = intended[pid], Date() < i.until, i.id != w.id, model.workspace(of: i.id) == model.current,
           n != model.current || saved.frames[w.id] != nil, let target = windows[i.id] {
            return stay(on: target)
        }
        intended[pid] = nil
        let previous = lastKey[pid]
        lastKey[pid] = w.id
        guard n != model.current || saved.frames[w.id] != nil else { return model.noteFocus(w.id) }
        // A window minimized or closed (even one an app only hid) is one you left, not chose from.
        let chosen = previous.map { $0 != w.id && windows[$0].map { !$0.isMinimized } == true && Windows.lists($0, pid: pid) } ?? false
        if chosen {
            model.noteFocus(w.id)
            switchTo(n, announce: true)
        } else if let here = windowHere(of: pid) {
            stay(on: here)
        } else {
            switchTo(model.current, announce: false)
        }
    }

    /// The running apps on the parked list (see `ParkedApps`) that answer Accessibility. A busy
    /// app is hidden as before: parking needs it to answer, hiding doesn't.
    private func parkedPids() -> Set<pid_t> {
        let ids = ParkedApps.bundleIDs
        guard !ids.isEmpty else { return [] }
        let unsure = lastScan?.unsure ?? []
        return Set(windows.values.map(\.pid)).filter { pid in
            Windows.isResponsive(pid) && !unsure.contains(pid) && !SlowMovers.contains(pid)
                && NSRunningApplication(processIdentifier: pid)?.bundleIdentifier.map(ids.contains) == true
        }
    }

    /// Each app with a window, by name and bundle identifier, for the parked-apps menu.
    func appsWithWindows() -> [(name: String, bundleID: String)] {
        var seen = Set<String>()
        return windows.values.sorted { $0.appName.localizedCompare($1.appName) == .orderedAscending }.compactMap { w in
            guard let id = NSRunningApplication(processIdentifier: w.pid)?.bundleIdentifier, seen.insert(id).inserted else { return nil }
            return (w.appName, id)
        }
    }

    /// Re-applies the workspace you're on, after the parked-apps list changed.
    func reapply() { switchTo(model.current, takeFocus: false, announce: false) }

    /// Every window onto workspace 1, all visible. The way out of any tangle.
    func gatherOnOne() {
        guard active else { return }
        if switching { return enqueue { [weak self] in self?.gatherOnOne() } }
        refresh(full: true)
        let screens = Windows.screens()
        for w in windows.values where saved.frames[w.id] == nil && !w.isMinimized {
            guard let f = w.frame, Geometry.isStranded(f, screens: screens) else { continue }
            w.setFrame(Geometry.restoreFrame(saved: nil, size: f.size, screens: screens))
        }
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
            if self.switching { return self.enqueue { [weak self] in self?.screensChanged() } }
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
        if switching { return enqueue { [weak self] in self?.focus(id, on: n) } }
        // Picking a minimized window in the viewer means wanting it back.
        if let w = windows[id], w.isMinimized { w.unminimize() }
        // Already here: raise it directly. A switch would first record the window in front (the
        // app you're leaving, since docks and switchers never take focus) and land back on it.
        if n == model.current, let w = windows[id] {
            // A window still parked off screen here (an earlier restore didn't land) comes back first.
            if let frame = saved.frames[id], restore(w, to: frame, screens: Windows.screens()) { saved.frames[id] = nil }
            stay(on: w)
            persist()
            return
        }
        model.noteFocus(id)
        switchTo(n)
    }

    /// Goes to an app wherever it is: the window of it used last, on whichever workspace that is,
    /// preferring the workspace you're on. An app with no windows is simply brought forward.
    /// The workspace an app was last in front on, from each workspace's last-focused window,
    /// most recently visited workspace first.
    func lastWorkspace(of pid: pid_t) -> Int? {
        (recent + Array(Workspaces.range)).first { n in model.lastFocused[n].flatMap { windows[$0]?.pid } == pid }
    }

    /// `on` limits it to one workspace, for an app icon clicked in a dock tile. `cycle` steps to
    /// the app's next window there when one of its windows on that workspace is already in front.
    func focusApp(_ pid: pid_t, on only: Int? = nil, cycle: Bool = false) {
        guard active else { NSRunningApplication(processIdentifier: pid)?.activate(options: []); return }
        refresh()
        var mine = windows.values.filter { $0.pid == pid && model.workspace(of: $0.id) != nil }
        // A hidden app's window closing doesn't prompt a scan (its windows are off screen anyway),
        // so ask the app which windows it has: going to one it closed would bring nothing forward.
        // One on another macOS desktop is never listed from here; it doesn't count.
        let offscreen = Windows.snapshot(apps: [pid]).offscreen
        if let listed = Windows.listedIDs(of: pid),
           mine.contains(where: { !listed.contains($0.id) && offscreen[$0.id] != nil && Windows.onNoOtherDesktop($0.id) }) {
            refresh(full: true)
            mine = windows.values.filter { $0.pid == pid && model.workspace(of: $0.id) != nil }
        }
        let order = only.map { [$0] } ?? ([model.current] + recent.filter { $0 != model.current } + Array(Workspaces.range))
        for n in order {
            let here = mine.filter { model.workspace(of: $0.id) == n }
            guard !here.isEmpty else { continue }
            if cycle, n == model.current, let front = Windows.focused(in: Array(windows.values)),
               here.contains(where: { $0.id == front.id }), here.count > 1,
               let next = WindowCycle.next(here.map(\.id).sorted(), after: front.id) {
                return focus(next, on: n)
            }
            let last = model.lastFocused[n].flatMap { id in here.first { $0.id == id } }
            let pick = last ?? here.first { !$0.isMinimized } ?? here[0]
            return focus(pick.id, on: n)
        }
        if let only { return switchTo(only) }
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
    }

    /// Opens a new window of a running app here, with the app's own New Window command, and
    /// focuses it once it exists. The app stays hidden until then, and its windows on other
    /// workspaces stay where they are. False when the app has no New Window command; an app
    /// that makes no window in time is gone to instead.
    func openWindowHere(_ pid: pid_t) -> Bool {
        guard active, let item = Windows.newWindowItem(pid) else { return false }
        let known = Windows.standardIDs(of: pid)
        guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else { return false }
        // An app that comes forward for it isn't asking to be followed to its workspace.
        opening = (pid, Date().addingTimeInterval(1.5))
        waitUntil(timeout: 1.5, interval: 0.02, { !Windows.standardIDs(of: pid).subtracting(known).isEmpty }) { [weak self] in
            guard let self, self.active else { return }
            if self.switching { return self.enqueue { [weak self] in self?.finishOpening(pid, besides: known) } }
            self.finishOpening(pid, besides: known)
        }
        return true
    }

    private func finishOpening(_ pid: pid_t, besides known: Set<WindowID>) {
        opening = nil
        if !showNewWindow(of: pid, besides: known) { focusApp(pid) }
    }

    /// Shows a window the app just opened, which joined the workspace you're on: the app's others
    /// are parked before it shows, and it takes focus. False when there's no such window.
    private func showNewWindow(of pid: pid_t, besides known: Set<WindowID>) -> Bool {
        // A full scan: the window server may already have counted the window before
        // Accessibility listed it, and a quick refresh would then never look again.
        refresh(full: true)
        guard let new = windows.values.first(where: { $0.pid == pid && !known.contains($0.id) && model.workspace(of: $0.id) == model.current }) else {
            return false
        }
        lastKey[pid] = new.id
        model.noteFocus(new.id)
        switchTo(model.current, announce: false)
        return true
    }

    /// Sends one window to workspace `n` without going there.
    func move(_ id: WindowID, to n: Int) { move([id], to: n) }

    /// Sends windows to workspace `n` without going there, in one switch.
    func move(_ ids: [WindowID], to n: Int) {
        guard active, Workspaces.range.contains(n), !ids.isEmpty else { return }
        if switching { return enqueue { [weak self] in self?.move(ids, to: n) } }
        // The window last used there stays the one a visit lands on.
        for id in ids { model.assign(id, to: n, focus: false) }
        switchTo(model.current, takeFocus: false, announce: false)
    }

    /// The ⌘Tab switcher's list: the current workspace, then others with windows, most recent
    /// first, then any remaining ones in number order.
    func switcherOrder() -> [Int] {
        refresh()
        let withWindows = Set(Workspaces.range.filter { !model.windows(on: $0).isEmpty })
        var order = [model.current]
        for n in recent where n != model.current && withWindows.contains(n) { order.append(n) }
        for n in Workspaces.range where withWindows.contains(n) && !order.contains(n) { order.append(n) }
        return order
    }

    /// App names on workspace `n`, for the menu.
    func apps(on n: Int) -> [String] {
        var seen = Set<String>()
        return model.windows(on: n).compactMap { windows[$0]?.appName }.filter { seen.insert($0).inserted }
    }

    private func apply(_ plan: SwitchPlan, moveFocus: Bool = true) {
        guard active else { return }
        let gen = generation
        let screens = Windows.screens()
        // macOS reports the new front app a moment late. Right after a switch, the app that
        // switch brought forward is the one really in front.
        let oldFront = Date() < settleUntil ? expectedFront : NSWorkspace.shared.frontmostApplication?.processIdentifier
        // 1. Everything on this workspace comes back. That includes an app hidden with ⌘H:
        //    going to its workspace means wanting to see it.
        // A hidden app may not answer until it's shown, so a saved window that hasn't been seen yet
        // still brings its app back when you go to its workspace.
        // An app that also has known windows elsewhere stays hidden: it isn't answering, so those
        // windows couldn't be parked. The retry scan brings the waiting window home instead.
        let elsewhere = Set(windows.values.filter { model.workspace(of: $0.id) != model.current }.map(\.pid))
        let waiting = Set(pendingLayout.values.filter { $0.workspace == model.current }.map(\.pid)).subtracting(elsewhere)
        let parkedApps = parkedPids()
        let how = Concealment(plan: plan, owner: windows.mapValues(\.pid), alsoShown: waiting, neverHidden: parkedApps)
        let home = plan.show.compactMap { id -> (Window, CGRect)? in
            guard let frame = saved.frames[id], let w = windows[id] else { return nil }
            return (w, frame)
        }
        // Parked windows go home first, unseen; only then do their apps show.
        bringHome(home, screens: screens, gen: gen) { [self] in
        // An app with a window here parks its other windows now, before it shows (a hidden one
        // parks them unseen), so they never linger among this workspace's windows.
        parkAlongside(how, screens: screens)
        // An app on the parked list that BaneySpaces hid comes back once its windows from other
        // workspaces are parked, later in this switch (see `park`).
        for pid in how.showApps {
            if let app = NSRunningApplication(processIdentifier: pid), app.isHidden { app.unhide() }
            saved.hiddenApps.remove(pid)
        }
        // A hidden app that didn't answer couldn't move its windows home; now shown, it may.
        // Even one that animates its moves: a slide beats a window missing from its workspace.
        for (w, frame) in home where saved.frames[w.id] != nil {
            if restore(w, to: frame, screens: screens) { saved.frames[w.id] = nil }
        }
        // 2. Everything else leaves at once, except the app in front. Hiding a background app
        //    changes nothing about focus, so there's no reason to wait for it.
        let deferred: Set<pid_t> = moveFocus ? Set([oldFront].compactMap { $0 }).intersection(how.hideApps) : []
        // Our own hides are announced a moment later; they aren't an app you closed.
        ownHides = how.hideApps.union(Date() < ownHidesUntil ? ownHides : [])
        ownHidesUntil = Date().addingTimeInterval(1)
        let leavingParked: pid_t? = moveFocus ? oldFront.flatMap { parkedApps.contains($0) && !how.showApps.contains($0) ? $0 : nil } : nil
        conceal(how, apps: how.hideApps.subtracting(deferred), screens: screens)
        // 3. Focus moves to this workspace. Only then does the old front app hide: hiding the app
        //    in front makes macOS activate another app on its own, which would look like the
        //    person picking it.
        let target = ([plan.focus].compactMap { $0 } + plan.show)
            .compactMap { windows[$0] }.first { !$0.isMinimized && saved.frames[$0.id] == nil }
        let frontPid = target?.pid ?? getpid()
        if moveFocus { expectedFront = frontPid }
        var raised = false
        if moveFocus {
            if let target {
                emptyHolder.orderOut(nil)
                raised = target.focus()
                if raised { lastKey[target.pid] = target.id; intended[target.pid] = nil } else {
                    // The app may come forward on its own a moment later, focusing whatever window
                    // it used last. Until the raise lands, that isn't the person choosing it.
                    intended[target.pid] = (target.id, Date().addingTimeInterval(2))
                }
            } else {
                takeFocus()
            }
        }
        clock.mark(.shown)
        let done = { [self] in
            guard gen == generation, active else { return }
            clock.mark(.focused)
            // An app busy coming back from hiding can miss the raise. Try again once it has had
            // a moment, unless another switch came first.
            if moveFocus, !raised, let target {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
                    guard gen == generation, active, target.focus() else { return }
                    lastKey[target.pid] = target.id
                    intended[target.pid] = nil
                }
            }
            conceal(how, apps: deferred, screens: screens)
            // Hiding the app in front makes macOS activate the next one in line, often a parked
            // app whose window sits in the corner. That's this switch, not you picking it.
            if !deferred.isEmpty { leftAt = Date() }
            // A parked app isn't hidden, so nothing forces it out of the front. If it's still
            // there, its key window is out of sight: typing must not go into it.
            if let p = leavingParked, Windows.focusedPid() == p {
                if let target, target.focus() { lastKey[target.pid] = target.id } else { takeFocus() }
            }
            if moveFocus, target == nil, Windows.focusedPid() != getpid() {
                // Finder is the last resort, unless it was just hidden: activating a hidden app
                // brings back its windows from other workspaces.
                takeFocus(finderFallback: !how.hideApps.contains(Self.finderPid ?? -1))
            }
            if moveFocus, !deferred.isEmpty || leavingParked != nil || target == nil { handedOffAt = Date() }
            clock.mark(.done)
            // Only a switch that really brought an app forward vouches for the next one's idea of
            // which app is in front.
            if moveFocus, Windows.focusedPid() == frontPid { settleUntil = Date().addingTimeInterval(0.3) }
            // Windows from other workspaces leave last, behind the ones now in front.
            park(how, parkedApps: parkedApps, screens: screens, gen: gen) { [self] in
                clock.mark(.parked)
                clock.log(to: Spaces.folder.appendingPathComponent("timing.log"))
                persist()
                finish()
            }
        }
        // Nothing left that depends on focus: finish now, without waiting a timer tick.
        // Nothing left that depends on focus: finish now. An empty workspace still waits for
        // BaneySpaces to be in front, or the Finder fallback would fire on stale information.
        let waitForFocus = !deferred.isEmpty || (moveFocus && target == nil) || leavingParked != nil
        if !waitForFocus || Windows.focusedPid() == frontPid { return done() }
        waitUntil(timeout: 0.5, interval: 0.01, { Windows.focusedPid() == frontPid }, then: done)
        }
    }

    private func enqueue(_ action: @escaping () -> Void) { queued.append(.action(action)) }

    /// Ends a switch and runs what queued up during it, in order, then one check of an
    /// activation BaneySpaces didn't cause.
    private func finish() {
        switching = false
        onChange?()
        while !switching, !queued.isEmpty {
            switch queued.removeFirst() {
            case let .switchTo(n, focus, announce): switchTo(n, takeFocus: focus, announce: announce)
            case let .action(run): run()
            }
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
        // A hidden app's parked windows can go home once it's off screen; nobody sees them move.
        let home = saved.frames.compactMap { id, frame in windows[id].flatMap { apps.contains($0.pid) ? ($0, frame) : nil } }
        guard !home.isEmpty else { return }
        waitUntil(timeout: 0.3, interval: 0.01, { Windows.allOffscreen(Set(home.map(\.0.id))) }) { [self] in
            for (w, frame) in home where saved.frames[w.id] == frame && saved.hiddenApps.contains(w.pid) {
                if restore(w, to: frame, screens: screens) { saved.frames[w.id] = nil }
            }
        }
    }

    /// Parks the windows of other workspaces that stay unhidden: their app has a window here, or
    /// it's kept usable by automation. Some apps (Chromium browsers like Helium) animate every
    /// move, so a window slides away only behind windows that hide its whole path. An app with
    /// nothing here hides for the moment its windows move instead; one with a window here moves
    /// in place.
    private func park(_ how: Concealment, parkedApps: Set<pid_t>, screens: [CGRect], gen: Int, then: @escaping () -> Void) {
        let spot = Geometry.hidingSpot(screens: screens)
        // Apps with a window here parked theirs already (`parkAlongside`).
        let todo = how.park.compactMap { windows[$0] }.filter { !how.showApps.contains($0.pid) }.filter { w in
            !w.isMinimized && (saved.frames[w.id] == nil || w.frame.map { !Geometry.isStranded($0, screens: screens) } == true)
        }.filter { w in
            // Visible until now: remember where it stood. No readable frame, no parking.
            if saved.frames[w.id] == nil { saved.frames[w.id] = w.frame }
            return saved.frames[w.id] != nil
        }
        // A parked-list app BaneySpaces hid earlier (it was busy, or a park failed) parks while
        // still hidden, and shows once that worked, even with nothing left to park.
        let hiddenByUs = parkedApps.filter { pid in
            !how.showApps.contains(pid) && saved.hiddenApps.contains(pid) && NSRunningApplication(processIdentifier: pid)?.isHidden == true
        }
        guard !todo.isEmpty || !hiddenByUs.isEmpty else { return then() }
        let moving = Set(todo.map(\.id))
        let server = Windows.serverWindows()
        func path(_ w: Window) -> CGRect {
            (server[w.id]?.bounds ?? saved.frames[w.id] ?? .null).union(CGRect(origin: spot, size: CGSize(width: 1, height: 1)))
        }
        // Windows of apps hiding right now still read as on screen for a moment; they don't cover.
        let exposed = todo.filter { w in
            hiddenByUs.contains(w.pid) || !Windows.isCovered(w.id, ignoring: moving, apps: how.hideApps, path: path(w))
        }
        let exposedIDs = Set(exposed.map(\.id))
        for w in todo where !exposedIDs.contains(w.id) { w.setOrigin(spot) }
        whileHidden(exposed, move: { exposed.forEach { $0.setOrigin(spot) } }) { [self] justHid in
            guard gen == generation, active else { return }
            let hid = justHid.union(hiddenByUs)
            settle(moving, screens: screens) { [self] in
                guard gen == generation, active else { return }
                // An app kept unhidden for automation can ignore the move, or stop answering.
                // Read it back: one whose window didn't park is hidden after all, rather than
                // left in sight on the wrong workspace.
                let bounds = Windows.serverWindows()
                var unparked = Set<pid_t>()
                for w in todo {
                    guard let b = bounds[w.id]?.bounds, !Geometry.isStranded(b, screens: screens) else { continue }
                    unparked.insert(w.pid)
                    // A window that never left stays home with no record. One that moved part
                    // way keeps its record, so it comes back where it stood.
                    if let f = saved.frames[w.id], abs(f.minX - b.minX) < 2, abs(f.minY - b.minY) < 2 { saved.frames[w.id] = nil }
                }
                for pid in unparked {
                    NSRunningApplication(processIdentifier: pid)?.hide()
                    saved.hiddenApps.insert(pid)
                }
                for pid in hid.subtracting(unparked) {
                    NSRunningApplication(processIdentifier: pid)?.unhide()
                    saved.hiddenApps.remove(pid)
                }
                then()
            }
        }
    }

    /// Parks, in place and at once, the other windows of apps that have a window here. Hiding
    /// such an app would hide the window you came for, so these move where they are.
    private func parkAlongside(_ how: Concealment, screens: [CGRect]) {
        let spot = Geometry.hidingSpot(screens: screens)
        for id in how.park {
            guard let w = windows[id], how.showApps.contains(w.pid), !w.isMinimized,
                  saved.frames[id] == nil || w.frame.map({ !Geometry.isStranded($0, screens: screens) }) == true else { continue }
            if saved.frames[id] == nil {
                // Visible until now: remember where it stood. No readable frame, no parking.
                guard let f = w.frame else { continue }
                saved.frames[id] = f
            }
            w.setOrigin(spot)
        }
    }

    /// Brings parked windows back to where they stood, unseen. A window whose whole path is
    /// behind other windows moves in place, and so does one whose app has windows in sight
    /// (hiding it would make those blink). Any other moves while its app is hidden for a
    /// moment. Either way the move finishes before anything in front of it goes away.
    private func bringHome(_ moves: [(Window, CGRect)], screens: [CGRect], gen: Int, then: @escaping () -> Void) {
        // A window whose app doesn't answer can't move now; it isn't waited for.
        let targets = moves.compactMap { w, frame -> (Window, CGRect)? in
            w.frame.map { (w, Geometry.restoreFrame(saved: frame, size: $0.size, screens: screens)) }
        }
        guard !targets.isEmpty else { return then() }
        let moving = Set(targets.map(\.0.id))
        let server = Windows.serverWindows()
        let inSight = Windows.pidsInSight(screens: screens)
        let exposed = targets.filter { w, to in
            if NSRunningApplication(processIdentifier: w.pid)?.isHidden == true { return true }
            return !inSight.contains(w.pid) && !Windows.isCovered(w.id, ignoring: moving, apps: [], path: (server[w.id]?.bounds ?? .null).union(to))
        }
        let exposedIDs = Set(exposed.map(\.0.id))
        func place(_ list: [(Window, CGRect)]) {
            for (w, to) in list { w.place(to, currentSize: w.frame?.size ?? to.size) }
        }
        place(targets.filter { !exposedIDs.contains($0.0.id) })
        whileHidden(exposed.map(\.0), move: { place(exposed) }) { [self] hid in
            guard gen == generation, active else { return }
            let goal = Dictionary(uniqueKeysWithValues: targets.map { ($0.0.id, $0.1.origin) })
            settle(moving, targets: goal, screens: screens) { [self] in
                guard gen == generation, active else { return }
                // A busy app can drop the move: the window only counts as shown once it's on
                // screen. Otherwise it stays parked in the record and the next switch tries again.
                let bounds = Windows.serverWindows()
                for (w, _) in targets where bounds[w.id]?.bounds.map({ !Geometry.isStranded($0, screens: screens) }) == true {
                    saved.frames[w.id] = nil
                }
                for pid in hid {
                    NSRunningApplication(processIdentifier: pid)?.unhide()
                    saved.hiddenApps.remove(pid)
                }
                then()
            }
        }
    }

    /// Hides the apps of `windows` that are showing, runs `move` once the window server has
    /// them off screen, and hands back the apps it hid for the caller to show again. They're
    /// recorded as hidden meanwhile, so a quit or crash mid-switch still brings them back.
    private func whileHidden(_ windows: [Window], move: @escaping () -> Void, then: @escaping (Set<pid_t>) -> Void) {
        guard !windows.isEmpty else { return then([]) }
        let apps = Set(windows.map(\.pid)).compactMap { NSRunningApplication(processIdentifier: $0) }.filter { !$0.isHidden }
        let hid = Set(apps.map(\.processIdentifier))
        ownHides.formUnion(hid)
        ownHidesUntil = Date().addingTimeInterval(1)
        saved.hiddenApps.formUnion(hid)
        if !hid.isEmpty { persist() }
        apps.forEach { $0.hide() }
        let ids = Set(windows.map(\.id))
        waitUntil(timeout: 0.3, interval: 0.01, { Windows.allOffscreen(ids) }) {
            move()
            then(hid)
        }
    }

    /// Waits until each window has stopped where it was sent: exactly at its target when one is
    /// given, otherwise anywhere parked, still for 50 ms. Some apps animate a move over several
    /// frames; an app whose window was still changing position after 0.12 s is remembered in
    /// `SlowMovers` and hidden instead of parked from then on. Gives up after 0.4 s.
    private func settle(_ ids: Set<WindowID>, targets: [WindowID: CGPoint] = [:], screens: [CGRect], then: @escaping () -> Void) {
        guard !ids.isEmpty else { return then() }
        var last: [WindowID: CGRect] = [:]
        var stillSince: [WindowID: Date] = [:]
        var slow: Set<WindowID> = []
        let start = Date()
        waitUntil(timeout: 0.4, interval: 0.01, {
            let now = Windows.serverWindows().compactMapValues(\.bounds).filter { ids.contains($0.key) }
            let t = Date()
            // Only position counts: an app snapping its size to a grid isn't animating a move.
            for (id, b) in now where last[id]?.origin != b.origin {
                // A position between two others, late: the app is animating.
                if last[id] != nil, t.timeIntervalSince(start) > 0.12 { slow.insert(id) }
                stillSince[id] = t
            }
            last = now
            return ids.allSatisfy { id in
                guard let b = now[id] else { return true }
                if let to = targets[id], abs(b.minX - to.x) < 1, abs(b.minY - to.y) < 1 { return true }
                let still = t.timeIntervalSince(stillSince[id] ?? start) >= 0.05
                return still && (targets[id] == nil ? Geometry.isStranded(b, screens: screens) : !Geometry.isStranded(b, screens: screens))
            }
        }, then: { [self] in
            for pid in Set(slow.compactMap { windows[$0]?.pid }) {
                guard let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, !SlowMovers.bundleIDs.contains(id) else { continue }
                SlowMovers.bundleIDs.insert(id)
                Trace.log("slow mover: \(id) animates its moves; hiding it instead of parking")
            }
            then()
        })
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
            // Apps the last scan couldn't read, and windows from the saved layout still waiting
            // for theirs: why a window might be missing.
            "unsure": (lastScan?.unsure ?? []).sorted().map { ["pid": $0, "answering": Windows.isResponsive($0)] as [String: Any] },
            "waiting": pendingLayout.keys.sorted(),
            "lastFocused": Dictionary(uniqueKeysWithValues: model.lastFocused.map { (String($0.key), $0.value) }),
            "workspaces": Dictionary(uniqueKeysWithValues: Workspaces.range.map { n in
                (String(n), model.windows(on: n).map { ["id": $0, "app": windows[$0]?.appName ?? ""] as [String: Any] })
            }),
        ]
        let known = model.home.compactMap { id, ws in windows[id].map { SavedLayout.Entry(window: id, pid: $0.pid, workspace: ws) } }
        let layout = SavedLayout(current: model.current,
                                 entries: known + pendingLayout.values.filter { model.workspace(of: $0.window) == nil },
                                 lastFocused: model.lastFocused)
        Spaces.writer.async {
            frames.save(to: Spaces.framesURL)
            layout.save(to: Spaces.layoutURL)
            if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: Spaces.stateURL, options: .atomic)
            }
        }
    }

    /// Blocks until queued disk writes are done, for quitting.
    func flushWrites() { Spaces.writer.sync {} }

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
    enum Phase: String { case snap, scanned, shown, focused, done, parked }
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

