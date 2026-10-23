import AppKit
import BaneySpacesCore

/// macOS's own answers to a window dragged to the top of the screen: Mission Control, and filling
/// the screen with it. Both are off while the overview takes that gesture. Their settings are
/// saved first and go back when the switch is turned off or BaneySpaces is uninstalled. Not on
/// quit: with BaneySpaces gone the gesture just does nothing, and putting them back would
/// restart the Dock on every update.
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
        Setting(domain: "com.apple.WindowManager", key: "EnableTopTilingByEdgeDrag", process: "WindowManager"),
    ]
    private static let savedKey = "systemTopDragSaved"
    private static let off = false as NSNumber

    static var isTakenByUs: Bool { UserDefaults.standard.dictionary(forKey: savedKey) != nil }

    static func takeOver() {
        if !isTakenByUs {
            // A setting that wasn't there is saved as absent, so restoring removes it again.
            var saved: [String: Any] = [:]
            for s in settings { if let v = read(s) { saved[s.id] = v } }
            UserDefaults.standard.set(saved, forKey: savedKey)
        }
        restart(settings.filter { write($0, off) })
    }

    static func restore() {
        guard let saved = UserDefaults.standard.dictionary(forKey: savedKey) else { return }
        // Only a setting still off as BaneySpaces left it goes back; one switched on since in
        // System Settings is the person's newer choice and stays.
        restart(settings.filter { read($0) == off && write($0, saved[$0.id] as? NSNumber) })
        UserDefaults.standard.removeObject(forKey: savedKey)
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

/// Watches for another app's window being dragged by its title bar to the top of a screen, and
/// then follows the drag until the button comes up. A press is all it listens for; a tick per
/// frame runs only while the button that started on a window stays down.
final class TopDragWatcher {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "topDragOpensOverview") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "topDragOpensOverview") }
    }

    /// The drag reached the top: open for it. False when the window isn't one BaneySpaces places.
    var onOpen: (TopDrag.Grab, CGPoint) -> Bool = { _, _ in false }
    /// The pointer moved while the overview is open for a drag.
    var onMove: (CGPoint) -> Void = { _ in }
    /// The button came up with the overview open for `grab`.
    var onRelease: (TopDrag.Grab) -> Void = { _ in }

    private var monitor: Any?
    private var timer: Timer?
    private var state = TopDrag()
    private var open: TopDrag.Grab?

    var isRunning: Bool { monitor != nil }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in self?.pressed() }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        endTicks()
        if let g = open { open = nil; onRelease(g) }
    }

    private func pressed() {
        endTicks()
        let p = TopDragWatcher.cursor
        guard let grab = TopDragWatcher.window(at: p) else { return }
        state.press(grab)
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let p = TopDragWatcher.cursor
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            endTicks()
            if let g = open { open = nil; onRelease(g) }
            return
        }
        if open != nil { return onMove(p) }
        guard let grab = state.grab else { return endTicks() }
        let frame = TopDragWatcher.bounds(of: grab.window)
        if let g = state.tick(cursor: p, frame: frame, screens: TopDragWatcher.screens(), now: ProcessInfo.processInfo.systemUptime) {
            if onOpen(g, p) { open = g } else { endTicks() }
        } else if state.grab == nil {
            endTicks()
        }
    }

    private func endTicks() {
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

    /// The frontmost ordinary window of another app under `p`.
    static func window(at p: CGPoint) -> TopDrag.Grab? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list {
            guard let bounds = (w[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  bounds.contains(p) else { continue }
            // The first window under the pointer takes the click, whatever it is.
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowOwnerPID as String] as? Int32) != getpid(),
                  let id = w[kCGWindowNumber as String] as? Int else { return nil }
            return TopDrag.Grab(window: WindowID(id), frame: bounds)
        }
        return nil
    }

    static func bounds(of id: WindowID) -> CGRect? {
        // The window server wants the bare numbers in the array, not NSNumbers.
        var ids = [UnsafeRawPointer(bitPattern: UInt(id))]
        guard let array = CFArrayCreate(nil, &ids, 1, nil) else { return nil }
        let list = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]]
        return (list?.first?[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
    }
}
