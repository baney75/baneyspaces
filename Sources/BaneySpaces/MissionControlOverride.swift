import AppKit
import BaneySpacesCore
import IOKit

/// macOS's Mission Control, kept off only while BaneySpaces is there to replace it. The settings
/// are saved first and put back when the switch goes off, when BaneySpaces quits or loses
/// Accessibility, and when it's uninstalled (`MissionControlTakeover` has the rules; `uninstall.sh`
/// reads the same record). Two things cover a BaneySpaces that stops without doing it: a quit for
/// an update leaves the settings for the new build, and a launch agent (`MissionControlWatchdog`)
/// puts them back if no BaneySpaces has run for a minute (30 seconds after an update's quit).
enum SystemMissionControl {
    private final class Prefs: PreferenceStore {
        func value(_ domain: String, _ key: String) -> NSNumber? {
            CFPreferencesAppSynchronize(domain as CFString)
            return CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? NSNumber
        }
        func set(_ domain: String, _ key: String, _ value: NSNumber?) {
            CFPreferencesSetAppValue(key as CFString, value, domain as CFString)
            CFPreferencesAppSynchronize(domain as CFString)
        }
    }

    private final class Record: SavedRecord {
        var saved: [String: NSNumber]? {
            get { UserDefaults.standard.dictionary(forKey: MissionControlTakeover.recordKey) as? [String: NSNumber] }
            set {
                if let newValue { UserDefaults.standard.set(newValue, forKey: MissionControlTakeover.recordKey) }
                else { UserDefaults.standard.removeObject(forKey: MissionControlTakeover.recordKey) }
            }
        }
    }

    private static var takeover: MissionControlTakeover { MissionControlTakeover(prefs: Prefs(), record: Record()) }

    static var isTakenByUs: Bool { takeover.isTakenByUs }

    /// The hot corners that opened Mission Control, which BaneySpaces answers now.
    static func answeredCorners() -> [(corner: MissionControlTakeover.Corner, modifiers: Int)] { takeover.answeredCorners() }

    static func takeOver() {
        if takeover.takeOver() {
            Trace.log("mission control: off at the Dock (corners answered: \(answeredCorners().map(\.corner.rawValue)))")
            restartDock()
        }
        installWatchdog()
    }

    static func restore() {
        let changed = takeover.restore()
        removeWatchdog()
        if changed {
            Trace.log("mission control: back as it was")
            restartDock()
        }
    }

    /// Quitting for an update: the new build takes over where this one left off, so nothing is
    /// restored. A marker tells the launch agent to give it 30 seconds, not 60, to start.
    static func leaveForUpdate() {
        FileManager.default.createFile(atPath: folder.appendingPathComponent(MissionControlWatchdog.updating).path, contents: Data())
        beat()
        Trace.log("mission control: left to the update")
    }

    /// Proof that BaneySpaces is alive, for the launch agent.
    static func beat() {
        let url = folder.appendingPathComponent(MissionControlWatchdog.heartbeat)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        } else {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
    }

    private static var folder: URL { Spaces.folder.appendingPathComponent("BaneySpaces") }
    private static var agentPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(MissionControlWatchdog.plistName)")
    }

    /// The launch agent, its script, and the copy of uninstall.sh it restores with. Written at
    /// every takeover so an updated build's copy replaces the old one.
    private static func installWatchdog() {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try? fm.removeItem(at: folder.appendingPathComponent(MissionControlWatchdog.updating))
        beat()
        guard let uninstall = Bundle.main.url(forResource: "uninstall", withExtension: "sh") else {
            return Trace.log("mission control: no uninstall.sh in the app, so no watchdog")
        }
        let restoreCopy = folder.appendingPathComponent(MissionControlWatchdog.restoreName)
        try? fm.removeItem(at: restoreCopy)
        try? fm.copyItem(at: uninstall, to: restoreCopy)
        let script = folder.appendingPathComponent(MissionControlWatchdog.scriptName)
        try? MissionControlWatchdog.script.write(to: script, atomically: true, encoding: .utf8)
        let escaped = folder.path.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let plist = MissionControlWatchdog.plist(folder: escaped)
        let old = try? String(contentsOf: agentPlist, encoding: .utf8)
        try? fm.createDirectory(at: agentPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? plist.write(to: agentPlist, atomically: true, encoding: .utf8)
        // Loaded once; a changed plist is loaded again.
        if old != plist { launchctl(["bootout", "gui/\(getuid())/\(MissionControlWatchdog.label)"]) }
        if !launchctl(["print", "gui/\(getuid())/\(MissionControlWatchdog.label)"]) {
            launchctl(["bootstrap", "gui/\(getuid())", agentPlist.path])
        }
    }

    private static func removeWatchdog() {
        launchctl(["bootout", "gui/\(getuid())/\(MissionControlWatchdog.label)"])
        let fm = FileManager.default
        try? fm.removeItem(at: agentPlist)
        for name in [MissionControlWatchdog.heartbeat, MissionControlWatchdog.updating] {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Whether launchctl exited 0.
    @discardableResult
    private static func launchctl(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// The Dock reads these settings when it starts; restarting it is how System Settings applies them.
    private static func restartDock() {
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = ["Dock"]
        try? kill.run()
    }
}

/// Hot corners that used to open Mission Control, now opening the overview. macOS's own are
/// remapped to nothing (`SystemMissionControl`); this watches the pointer for them. It never
/// moves or clicks the pointer, and a mouse-moved watch needs no permission. The pointer over
/// BaneySpaces' own windows (the dock, the overview, Settings) is seen by the local watch.
final class HotCornerWatcher {
    var onOpen: () -> Void = {}
    private var corners: [(corner: MissionControlTakeover.Corner, modifiers: Int)] = []
    private var dwell = HotCornerDwell()
    private var monitors: [Any] = []
    private var timer: Timer?

    var isRunning: Bool { !monitors.isEmpty }

    /// The corners to answer. The watch starts, stops or is left alone, whichever the list needs.
    func set(corners new: [(corner: MissionControlTakeover.Corner, modifiers: Int)]) {
        let same = new.count == corners.count && zip(new, corners).allSatisfy { $0.corner == $1.corner && $0.modifiers == $1.modifiers }
        if same && isRunning == !new.isEmpty { return }
        stop()
        corners = new
        guard !new.isEmpty else { return }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in self?.evaluate() }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] e in self?.evaluate(); return e }) { monitors.append(l) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        timer?.invalidate()
        timer = nil
        corners = []
        dwell = HotCornerDwell()
    }

    private func evaluate() {
        var corner = HotCorners.corner(at: NSEvent.mouseLocation, screens: NSScreen.screens.map(\.frame))
        // A corner macOS answered with a key held waits for that key; a drag in progress isn't a visit.
        if let c = corner {
            let wanted = corners.first { $0.corner == c }
            let held = Int(NSEvent.modifierFlags.rawValue)
            let answered = wanted.map { HotCorners.modifiersHeld(required: $0.modifiers, held: held) } ?? false
            if !answered || NSEvent.pressedMouseButtons != 0 { corner = nil }
        }
        if dwell.update(corner, now: ProcessInfo.processInfo.systemUptime) {
            Trace.log("hot corner \(corner?.rawValue ?? "?"): overview")
            timer?.invalidate()
            onOpen()
        } else if corner != nil, timer == nil || timer?.isValid == false {
            // The pointer rests, so no more events come: look again once the dwell is up.
            timer = Timer.scheduledTimer(withTimeInterval: HotCorners.dwell + 0.02, repeats: false) { [weak self] _ in self?.evaluate() }
        }
    }
}

/// The three- or four-finger swipe up that opened Mission Control, and the swipe down that closes
/// the overview. macOS gives apps no public way to see trackpad touches, so this loads the private
/// MultitouchSupport framework at run time, as other trackpad apps do. If it can't be loaded, or
/// reports touches in a layout this build doesn't know, the swipe is off and Settings says so
/// (`problem`); with Mission Control off at the Dock the system view doesn't open either.
///
/// Trackpads are listed once at start and again only when IOKit says a multitouch device came or
/// went, or after sleep. Each is told apart by the framework's own device id, because every
/// listing makes new device objects. Only trackpads are watched, never a Magic Mouse.
final class TrackpadSwipe {
    var onSwipe: (FingerSwipe.Direction) -> Void = { _ in }

    // The framework's own types, as they have been since 10.6.
    private typealias Device = UnsafeMutableRawPointer
    private typealias Frame = @convention(c) (Device?, UnsafeRawPointer?, Int32, Double, Int32) -> Int32
    private struct API {
        let create: @convention(c) () -> Unmanaged<CFArray>?
        let register: @convention(c) (Device, Frame) -> Void
        let unregister: @convention(c) (Device, Frame) -> Void
        let start: @convention(c) (Device, Int32) -> Void
        let stop: @convention(c) (Device) -> Void
        let deviceID: @convention(c) (Device, UnsafeMutablePointer<UInt64>) -> Int32
        let isBuiltIn: @convention(c) (Device) -> Bool
        let dimensions: @convention(c) (Device, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32

        static func load() -> API? {
            guard let h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY),
                  let create = dlsym(h, "MTDeviceCreateList"), let register = dlsym(h, "MTRegisterContactFrameCallback"),
                  let unregister = dlsym(h, "MTUnregisterContactFrameCallback"), let start = dlsym(h, "MTDeviceStart"),
                  let stop = dlsym(h, "MTDeviceStop"), let id = dlsym(h, "MTDeviceGetDeviceID"),
                  let builtIn = dlsym(h, "MTDeviceIsBuiltIn"), let dims = dlsym(h, "MTDeviceGetSensorSurfaceDimensions")
            else { return nil }
            return API(create: unsafeBitCast(create, to: (@convention(c) () -> Unmanaged<CFArray>?).self),
                       register: unsafeBitCast(register, to: (@convention(c) (Device, Frame) -> Void).self),
                       unregister: unsafeBitCast(unregister, to: (@convention(c) (Device, Frame) -> Void).self),
                       start: unsafeBitCast(start, to: (@convention(c) (Device, Int32) -> Void).self),
                       stop: unsafeBitCast(stop, to: (@convention(c) (Device) -> Void).self),
                       deviceID: unsafeBitCast(id, to: (@convention(c) (Device, UnsafeMutablePointer<UInt64>) -> Int32).self),
                       isBuiltIn: unsafeBitCast(builtIn, to: (@convention(c) (Device) -> Bool).self),
                       dimensions: unsafeBitCast(dims, to: (@convention(c) (Device, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32).self))
        }
    }

    /// A trackpad being watched. `list` keeps its device object alive.
    private struct Watched {
        let device: Device
        let list: CFArray
        let builtIn: Bool
        var reader = TouchFrameReader()
        var swipe: FingerSwipe
    }

    private static var shared: TrackpadSwipe?
    private static let callback: Frame = { device, data, count, _, _ in
        // A frame with no touches (every finger up) has no data: it still ends the gesture.
        guard let device else { return 0 }
        shared?.frame(device, data, Int(count))
        return 0
    }

    private let lock = NSLock()
    private var api: API?
    private var watched: [UInt64: Watched] = [:]
    private var idOf: [Device: UInt64] = [:]
    private var skipped = Set<UInt64>()
    private var loadFailed = false
    private var running = false
    private var wake: NSObjectProtocol?
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var pending: DispatchWorkItem?

    /// Why the swipe doesn't work, in words for Settings; nil while it works or isn't wanted.
    var problem: String? {
        lock.lock(); defer { lock.unlock() }
        guard running else { return nil }
        let others = "The Mission Control key, ⌃↑, the hot corners and the menu bar menu open the overview."
        if loadFailed {
            return "BaneySpaces couldn't load macOS's trackpad support, so a swipe up on the trackpad does nothing. \(others)"
        }
        if watched.values.contains(where: { $0.reader.layout == .rejected }) {
            return "This version of macOS reports trackpad touches in a way BaneySpaces doesn't read, so a swipe up on the trackpad does nothing. \(others)"
        }
        return nil
    }

    func start() {
        guard !running else { return }
        TrackpadSwipe.shared = self
        lock.lock(); running = true; loadFailed = false; lock.unlock()
        guard let api = API.load() else {
            lock.lock(); loadFailed = true; lock.unlock()
            return Trace.log("trackpad swipe: MultitouchSupport didn't load")
        }
        self.api = api
        refresh()
        watchForDevices()
        wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // Devices stop reporting across sleep; list and start them again.
            self?.detach()
            self?.refresh()
        }
    }

    func stop() {
        guard running else { return }
        pending?.cancel()
        pending = nil
        for it in iterators { IOObjectRelease(it) }
        iterators = []
        if let port { IONotificationPortDestroy(port) }
        port = nil
        if let wake { NSWorkspace.shared.notificationCenter.removeObserver(wake) }
        wake = nil
        detach()
        lock.lock(); running = false; lock.unlock()
        api = nil
    }

    /// The finger counts follow System Settings; called now and then, it only reads preferences.
    func refreshSettings() {
        lock.lock()
        for (id, w) in watched { watched[id]?.swipe.fingers = TrackpadSwipe.fingerCounts(builtIn: w.builtIn) }
        lock.unlock()
    }

    private func detach() {
        guard let api else { return }
        lock.lock()
        let devices = Array(watched.values.map(\.device))
        watched = [:]
        idOf = [:]
        skipped = []
        lock.unlock()
        for d in devices { api.unregister(d, TrackpadSwipe.callback); api.stop(d) }
    }

    /// IOKit says when a multitouch device appears or goes, so nothing has to look on a timer.
    private func watchForDevices() {
        guard let notify = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(notify, .main)
        port = notify
        let handler: IOServiceMatchingCallback = { refcon, iterator in
            // Arms the next notification.
            while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
            guard let refcon else { return }
            Unmanaged<TrackpadSwipe>.fromOpaque(refcon).takeUnretainedValue().devicesChanged()
        }
        let me = Unmanaged.passUnretained(self).toOpaque()
        for kind in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var it: io_iterator_t = 0
            guard IOServiceAddMatchingNotification(notify, kind, IOServiceMatching("AppleMultitouchDevice"), handler, me, &it) == KERN_SUCCESS else { continue }
            iterators.append(it)
            while case let service = IOIteratorNext(it), service != 0 { IOObjectRelease(service) }
        }
    }

    /// A burst of notices (a trackpad is several services) makes one listing.
    private func devicesChanged() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Lists the multitouch devices, watches the trackpads not yet watched and lets go of those gone.
    private func refresh() {
        guard let api, running, let found = api.create()?.takeRetainedValue() else { return }
        var present = Set<UInt64>()
        var added = 0
        for i in 0..<CFArrayGetCount(found) {
            guard let raw = CFArrayGetValueAtIndex(found, i) else { continue }
            let d = UnsafeMutableRawPointer(mutating: raw)
            var id: UInt64 = 0
            guard api.deviceID(d, &id) == 0 else { continue }
            present.insert(id)
            lock.lock(); let known = watched[id] != nil || skipped.contains(id); lock.unlock()
            if known { continue }
            let builtIn = api.isBuiltIn(d)
            var w: Int32 = 0, h: Int32 = 0
            _ = api.dimensions(d, &w, &h)
            guard TrackpadDevice.isTrackpad(builtIn: builtIn, width: Int(w), height: Int(h)) else {
                lock.lock(); skipped.insert(id); lock.unlock()
                Trace.log("trackpad swipe: skipping a multitouch device that isn't a trackpad (\(w)x\(h))")
                continue
            }
            let aspect = h > 0 ? Float(w) / Float(h) : FingerSwipe.defaultAspect
            lock.lock()
            watched[id] = Watched(device: d, list: found, builtIn: builtIn,
                                  swipe: FingerSwipe(fingers: TrackpadSwipe.fingerCounts(builtIn: builtIn), aspect: aspect))
            idOf[d] = id
            lock.unlock()
            api.register(d, TrackpadSwipe.callback)
            api.start(d, 0)
            added += 1
        }
        lock.lock()
        let gone = watched.filter { !present.contains($0.key) }
        for (id, w) in gone { watched[id] = nil; idOf[w.device] = nil }
        skipped.formIntersection(present)
        let count = watched.count
        lock.unlock()
        for (_, w) in gone { api.unregister(w.device, TrackpadSwipe.callback); api.stop(w.device) }
        if added > 0 || !gone.isEmpty { Trace.log("trackpad swipe: watching \(count) trackpad(s) (+\(added) -\(gone.count))") }
    }

    /// Runs on the framework's thread for each frame of touches.
    private func frame(_ device: Device, _ data: UnsafeRawPointer?, _ count: Int) {
        lock.lock()
        guard let id = idOf[device], var w = watched[id] else { lock.unlock(); return }
        let before = w.reader.layout
        let touches = w.reader.touches(in: data, count: count)
        var direction: FingerSwipe.Direction?
        if let touches { direction = w.swipe.frame(touches) }
        watched[id] = w
        let after = w.reader.layout
        lock.unlock()
        if before != after {
            DispatchQueue.main.async { Trace.log("trackpad swipe: touch layout \(after == .trusted ? "checked" : "not recognised")") }
        }
        if let direction {
            DispatchQueue.main.async { [weak self] in
                Trace.log("trackpad swipe \(direction == .up ? "up" : "down") with \(touches?.count ?? 0) fingers")
                self?.onSwipe(direction)
            }
        }
    }

    /// The finger counts macOS gives Mission Control for a trackpad, from that trackpad's own
    /// settings (the built-in one's, or a Bluetooth or USB one's).
    static func fingerCounts(builtIn: Bool) -> Set<Int> {
        let domain = TrackpadDevice.preferenceDomain(builtIn: builtIn)
        CFPreferencesAppSynchronize(domain as CFString)
        func read(_ key: String) -> Int? { (CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? NSNumber)?.intValue }
        return FingerSwipe.fingerCounts(threeFingers: read("TrackpadThreeFingerVertSwipeGesture"),
                                        fourFingers: read("TrackpadFourFingerVertSwipeGesture"),
                                        threeFingerDrag: (read("TrackpadThreeFingerDrag") ?? 0) != 0)
    }
}
