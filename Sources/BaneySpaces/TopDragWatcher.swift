import AppKit
import BaneySpacesCore

/// macOS's Mission Control for a window dragged to the top of the screen. It's off while the
/// overview takes that gesture. Its setting is saved first and goes back when the switch is
/// turned off or BaneySpaces is uninstalled. Not on quit: with BaneySpaces gone the gesture just
/// does nothing, and putting it back would restart the Dock on every update.
///
/// Filling the screen with that window stays macOS's: let go at the top and the window fills
/// the screen (Donovan, 2026-10-28). Builds before then turned it off.
enum SystemTopDrag {
    private struct Setting {
        let domain: String
        let key: String
        /// The process that reads it at launch, restarted for a change to take effect.
        let process: String
        var id: String { domain + "/" + key }
    }

    private static let settings = [
        Setting(domain: "com.apple.dock", key: "enterMissionControlByTopWindowDrag", process: "Dock"),
    ]
    /// Fill-the-screen, which builds before 2026-10-28 turned off along with Mission Control.
    private static let fill = Setting(domain: "com.apple.WindowManager", key: "EnableTopTilingByEdgeDrag", process: "WindowManager")
    private static let on = true as NSNumber
    private static let savedKey = "systemTopDragSaved"
    private static let off = false as NSNumber

    static var isTakenByUs: Bool { UserDefaults.standard.dictionary(forKey: savedKey) != nil }

    static func takeOver() {
        giveFillBack()
        // A setting that wasn't there is saved as absent, so restoring removes it again. One
        // not off any more since the last launch was changed in System Settings since: that's
        // the person's newer choice, and the one to put back later.
        var saved = UserDefaults.standard.dictionary(forKey: savedKey) ?? [:]
        let first = !isTakenByUs
        for s in settings where first || read(s) != off {
            saved[s.id] = read(s)
        }
        UserDefaults.standard.set(saved, forKey: savedKey)
        restart(settings.filter { write($0, off) })
    }

    static func restore() {
        giveFillBack()
        guard let saved = UserDefaults.standard.dictionary(forKey: savedKey) else { return }
        // Only a setting still off as BaneySpaces left it goes back; one switched on since in
        // System Settings is the person's newer choice and stays.
        restart(settings.filter { read($0) == off && write($0, saved[$0.id] as? NSNumber) })
        UserDefaults.standard.removeObject(forKey: savedKey)
    }

    /// Turning it back on didn't read back yet: still owed even once `restore()` drops the record.
    private static let fillPendingKey = "systemTopDragFillPending"
    private static let fillTriesKey = "systemTopDragFillTries"
    /// A try was counted since this launch: at most one is, however often this runs.
    private static var fillTriedThisLaunch = false

    /// Once, on a Mac where an older build took the drag over (and turned fill-the-screen off):
    /// it comes back on unless it was off before BaneySpaces (`FillTheScreen`). A setting saved
    /// as absent leaves no key, so the record's mere presence is what counts. Done once the write
    /// reads back, or after `FillTheScreen.maxTries` launches' tries that didn't; after that a
    /// change in System Settings is left alone, with one exception: a give-up is recorded as
    /// `FillTheScreen.gaveUpKey`, not as given back, so uninstalling makes one last write. Give-ups
    /// recorded by builds before #50 set the given-back flag, and get no last write.
    private static func giveFillBack() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: FillTheScreen.givenBackKey), !d.bool(forKey: FillTheScreen.gaveUpKey) else { return }
        var saved = d.dictionary(forKey: savedKey)
        let was = saved?[fill.id] as? NSNumber
        let pending = d.bool(forKey: fillPendingKey)
        let now = read(fill)?.boolValue
        let due = FillTheScreen.turnBackOn(taken: saved != nil || pending, saved: was?.boolValue, now: now)
        if due, write(fill, on) { restart([fill]) }
        let step = FillTheScreen.decide(
            record: saved != nil, pending: pending, saved: was?.boolValue, now: now,
            tries: d.integer(forKey: fillTriesKey), triedThisLaunch: fillTriedThisLaunch, readBack: read(fill) == on)
        fillTriedThisLaunch = step.triedThisLaunch
        switch step.decision {
        case .retry(let tries):
            d.set(tries, forKey: fillTriesKey)
            d.set(true, forKey: fillPendingKey)
            return NSLog("BaneySpaces: fill-the-screen didn't turn back on (try \(tries) of \(FillTheScreen.maxTries))")
        case .giveUp:
            NSLog("BaneySpaces: fill-the-screen stays off after \(FillTheScreen.maxTries) tries; something else keeps it off. Leaving it.")
        case .settled:
            break
        }
        if saved?.removeValue(forKey: fill.id) != nil { d.set(saved, forKey: savedKey) }
        for key in [fillPendingKey, fillTriesKey] { d.removeObject(forKey: key) }
        if let key = step.decision.flagKey { d.set(true, forKey: key) }
    }

    private static func read(_ s: Setting) -> NSNumber? {
        CFPreferencesCopyAppValue(s.key as CFString, s.domain as CFString) as? NSNumber
    }

    /// Writes a setting (nil removes it); whether anything changed.
    private static func write(_ s: Setting, _ value: NSNumber?) -> Bool {
        guard read(s) != value else { return false }
        CFPreferencesSetAppValue(s.key as CFString, value, s.domain as CFString)
        CFPreferencesAppSynchronize(s.domain as CFString)
        return true
    }

    private static func restart(_ changed: [Setting]) {
        let names = Set(changed.map(\.process))
        guard !names.isEmpty else { return }
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = names.sorted()
        try? kill.run()
    }
}

/// Watches for another app's window being dragged by its title bar to the top of a screen, or
/// down to the Workspace Dock, and then follows the drag until the button comes up. A press is
/// all it listens for; a tick per frame runs only while the button that started on a window
/// stays down.
final class TopDragWatcher {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "topDragOpensOverview") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "topDragOpensOverview") }
    }

    /// The drag reached the top: open for it. True opened, false never will (a window
    /// BaneySpaces doesn't place), nil not right now (a switch is under way): ask again.
    var onOpen: (TopDrag.Grab, CGPoint) -> Bool? = { _, _ in false }
    /// A press on another app, with the window under it: a drop of that window still settling
    /// is stale, since it's being picked up again.
    var onPress: (WindowID?) -> Void = { _ in }
    /// The pointer moved while the overview is open for a drag.
    var onMove: (CGPoint) -> Void = { _ in }
    /// The button came up with the overview open for `grab`. `drop` is false when the drag
    /// ended some other way (the watcher stopped, or a release it missed), so nothing moves.
    var onRelease: (_ grab: TopDrag.Grab, _ drop: Bool) -> Void = { _, _ in }
    /// The drag to the top opens the overview. Off, the watcher still follows drags for the dock.
    var topEnabled = true
    /// The window follows the pointer, on every tick until the overview opens for it: the dock
    /// comes up when the pointer reaches its edge.
    var onCarry: (TopDrag.Grab, CGPoint) -> Void = { _, _ in }
    /// That drag ended: let go at the point given, or nil when it ended some other way (the
    /// overview took it, the window went away, the watcher stopped), so nothing moves.
    var onCarryEnd: (TopDrag.Grab, CGPoint?) -> Void = { _, _ in }

    private var monitor: Any?
    private var upMonitor: Any?
    private var timer: Timer?
    private var state = TopDrag()
    private var open: TopDrag.Grab?
    /// The drag `onCarry` has been told about.
    private var carried: TopDrag.Grab?
    /// The app whose window was pressed.
    private var owner: pid_t = 0

    var isRunning: Bool { monitor != nil }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            self?.pressed(at: e.cgEvent?.location ?? TopDragWatcher.cursor)
        }
        // The release itself, where it happened, so a quick let-go lands on the tile it was
        // over; the tick's button check is the fallback for one the monitor misses.
        upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] e in
            self?.released(at: e.cgEvent?.location ?? TopDragWatcher.cursor)
        }
    }

    func stop() {
        for m in [monitor, upMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(m) }
        monitor = nil
        upMonitor = nil
        released(at: nil)
    }

    /// Ends the drag: the overview, if it opened for it, gets the last position and the release.
    /// Without a position it closes and nothing moves.
    private func released(at p: CGPoint?) {
        endCarry(at: p)
        endTicks()
        guard let g = open else { return }
        open = nil
        if let p { onMove(p) }
        onRelease(g, p != nil)
    }

    private func pressed(at p: CGPoint) {
        // A press always follows a release; one the watcher missed ends the last drag first,
        // without a drop, since where it let go is unknown.
        released(at: nil)
        let found = TopDragWatcher.window(at: p)
        onPress(found?.grab.window)
        guard let found else { return }
        state.press(found.grab)
        owner = found.pid
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let p = TopDragWatcher.cursor
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return released(at: p) }
        if open != nil { return onMove(p) }
        guard let grab = state.grab else { return endTicks() }
        let frame = TopDragWatcher.bounds(of: grab.window)
        let wasDragging = state.moving || state.pinned
        defer {
            // Once per drag, so trace.log shows the drags the watcher saw.
            if !wasDragging, state.moving || state.pinned { Trace.log("topDrag \(state.moving ? "moving" : "pinned") window=\(grab.window)") }
        }
        let top = state.tick(cursor: p, frame: frame, screens: TopDragWatcher.screens(), now: ProcessInfo.processInfo.systemUptime)
        if let g = top, topEnabled {
            // A window against the top that didn't move: a tab torn off its title bar makes a
            // new window of the same app in front of it, and that drag isn't this one.
            if !state.moving, TopDragWatcher.frontWindow(of: owner) != g.window { return endTicks() }
            switch onOpen(g, p) {
            case true?:
                // The overview has it now, not the dock.
                endCarry(at: nil)
                open = g
            case false?: endTicks()
            case nil: state.rearm()
            }
        } else if state.grab == nil {
            endTicks()
        } else if top != nil {
            // The overview is off: the drag goes on, for the dock, as if the top never fired.
            state.rearm()
        } else if state.moving {
            carried = grab
            onCarry(grab, p)
        }
    }

    private func endCarry(at p: CGPoint?) {
        guard let g = carried else { return }
        carried = nil
        onCarryEnd(g, p)
    }

    private func endTicks() {
        endCarry(at: nil)
        timer?.invalidate()
        timer = nil
        state.release()
    }

    /// The pointer in window-server space (top-left origin).
    static var cursor: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    static func screens() -> [CGRect] {
        guard let mainHeight = NSScreen.screens.first?.frame.maxY else { return [] }
        return NSScreen.screens.map { CGRect(x: $0.frame.minX, y: mainHeight - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height) }
    }

    /// The frontmost ordinary window of another app under `p`, and its app.
    static func window(at p: CGPoint) -> (grab: TopDrag.Grab, pid: pid_t)? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list {
            guard let bounds = (w[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  bounds.contains(p) else { continue }
            // The first window under the pointer takes the click, whatever it is.
            guard (w[kCGWindowLayer as String] as? Int) == 0, let pid = w[kCGWindowOwnerPID as String] as? Int32, pid != getpid(),
                  let id = w[kCGWindowNumber as String] as? Int else { return nil }
            return (TopDrag.Grab(window: WindowID(id), frame: bounds, press: p), pid)
        }
        return nil
    }

    /// The frontmost ordinary on-screen window of app `pid`.
    static func frontWindow(of pid: pid_t) -> WindowID? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.first { ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
            .flatMap { ($0[kCGWindowNumber as String] as? Int).map(WindowID.init) }
    }

    static func bounds(of id: WindowID) -> CGRect? {
        // The window server wants the bare numbers in the array, not NSNumbers.
        var ids = [UnsafeRawPointer(bitPattern: UInt(id))]
        guard let array = CFArrayCreate(nil, &ids, 1, nil) else { return nil }
        let list = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]]
        return (list?.first?[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
    }
}
