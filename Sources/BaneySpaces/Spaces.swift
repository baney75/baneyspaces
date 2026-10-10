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
    /// Shortcuts pressed mid-switch run, in order, once it finishes.
    private var queued: [() -> Void] = []
    /// The app our own switch activated, so its activation isn't mistaken for the person's.
    private var expectedPid: pid_t?
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
    }

    func refresh() {
        let list = Windows.all()
        let alive = Windows.alive()
        windows = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let added = model.sync(seen: list.map(\.id), alive: alive)
        saved.frames = saved.frames.filter { alive.contains($0.key) }
        // An app that autosaves its window position can reopen a window at the hiding spot.
        let screens = Windows.screens()
        for id in added {
            guard let w = windows[id], !w.isMinimized, let f = w.frame, Geometry.isStranded(f, screens: screens) else { continue }
            w.setFrame(Geometry.restoreFrame(saved: nil, size: f.size, screens: screens))
        }
    }

    func switchTo(_ n: Int) {
        guard Workspaces.range.contains(n) else { return }
        if switching { return queued.append { [weak self] in self?.switchTo(n) } }
        refresh()
        if let f = Windows.focused(in: Array(windows.values)), model.workspace(of: f.id) == model.current {
            model.noteFocus(f.id)
        }
        let plan = model.switchTo(n)
        switching = true
        generation += 1

        // A window in macOS full screen lives on its own desktop, where nothing can move it.
        // Leaving its workspace brings it out of full screen and fills the screen with it instead.
        let fullScreen = plan.hide.compactMap { windows[$0] }.filter(\.isFullScreen)
        guard !fullScreen.isEmpty else { return apply(plan) }
        fullScreen.forEach { $0.exitFullScreen() }
        waitUntil(timeout: 3, { fullScreen.allSatisfy { !$0.isFullScreen } }) { [self] in
            // The exit animation keeps resizing the window for a moment after the flag flips.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
                for w in fullScreen {
                    if w.isFullScreen {
                        // The app refused. Keep the window with you rather than strand you on its desktop.
                        model.assign(w.id, to: n)
                        NSSound.beep()
                    } else if let f = w.frame {
                        w.setFrame(Windows.visibleArea(near: f))
                    }
                }
                // Now on the regular desktop, Accessibility can list windows it couldn't see from
                // the full-screen one. Plan again with all of them.
                refresh()
                apply(model.switchTo(n))
            }
        }
    }

    /// Sends the focused window to workspace `n` and follows it there.
    func moveFocused(to n: Int) {
        guard Workspaces.range.contains(n) else { return }
        if switching { return queued.append { [weak self] in self?.moveFocused(to: n) } }
        refresh()
        guard let w = Windows.focused(in: Array(windows.values)) else { return NSSound.beep() }
        model.assign(w.id, to: n)
        switchTo(n)
    }

    /// Clicking a Dock icon or using ⌘Tab can focus a window on another workspace. Go there,
    /// and land on the window that was picked.
    func appActivated(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != getpid() else { return }
        if pid == expectedPid { expectedPid = nil; return }
        if switching { return queued.append { [weak self] in self?.followFocus() } }
        followFocus()
    }

    private func followFocus() {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return }
        refresh()
        guard let w = Windows.focused(of: app.processIdentifier, in: Array(windows.values)),
              let n = model.workspace(of: w.id) else { return }
        model.noteFocus(w.id)
        if n != model.current { switchTo(n) }
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
        persist()
    }

    /// The display layout changed: put hidden windows at the new hiding spot.
    func screensChanged() {
        if switching { return queued.append { [weak self] in self?.screensChanged() } }
        switchTo(model.current)
    }

    /// App names on workspace `n`, for the menu.
    func apps(on n: Int) -> [String] {
        var seen = Set<String>()
        return model.windows(on: n).compactMap { windows[$0]?.appName }.filter { seen.insert($0).inserted }
    }

    private func apply(_ plan: SwitchPlan) {
        let screens = Windows.screens()
        let spot = Geometry.hidingSpot(screens: screens)
        for id in plan.hide {
            guard let w = windows[id], !w.isMinimized else { continue }
            if saved.frames[id] == nil {
                // Visible until now: remember where it stood. No readable frame, no hiding.
                guard let f = w.frame else { continue }
                saved.frames[id] = f
            }
            w.setOrigin(spot)
        }
        for id in plan.show {
            guard let frame = saved.frames[id], let w = windows[id] else { continue }
            if restore(w, to: frame, screens: screens) { saved.frames[id] = nil }
        }
        focus(plan)
        persist()
        switching = false
        onChange?()
        while !switching, !queued.isEmpty { queued.removeFirst()() }
    }

    /// Brings a hidden window back and reads it back. A busy app can drop the move, so the
    /// window only counts as shown once it is actually on screen; otherwise it stays hidden in
    /// the record and the next switch tries again.
    private func restore(_ w: Window, to frame: CGRect, screens: [CGRect]) -> Bool {
        guard let f = w.frame else { return false }
        w.setFrame(Geometry.restoreFrame(saved: frame, size: f.size, screens: screens))
        guard let now = w.frame else { return false }
        return !Geometry.isStranded(now, screens: screens)
    }

    /// Focuses the workspace's window, then checks that it took. If no window can take focus,
    /// BaneySpaces takes it, so typing never lands in a hidden window.
    private func focus(_ plan: SwitchPlan) {
        let candidates = ([plan.focus].compactMap { $0 } + plan.show)
            .compactMap { windows[$0] }.filter { !$0.isMinimized && saved.frames[$0.id] == nil }
        guard let target = candidates.first else {
            expectedPid = nil
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let gen = generation
        expectedPid = target.pid
        target.focus()
        // Focus lands asynchronously. If typing would go to a hidden window, focus the target once
        // more, then take focus ourselves. A newer switch makes these checks stand down.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
            guard gen == generation, saved.frames[target.id] == nil,
                  let f = Windows.focused(in: Array(windows.values)), saved.frames[f.id] != nil else { return }
            target.focus()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
                guard gen == generation,
                      let f = Windows.focused(in: Array(windows.values)), saved.frames[f.id] != nil else { return }
                expectedPid = nil
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        // If the app was already in front, no activation comes to clear this.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            if gen == generation { expectedPid = nil }
        }
    }

    private func persist() {
        saved.save(to: Spaces.framesURL)
        // state.json is for scripts and checks: the current workspace and where each window lives.
        let state: [String: Any] = [
            "current": model.current,
            "hidden": saved.frames.keys.sorted(),
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
