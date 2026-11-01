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

    /// Why Mission Control couldn't be taken over, for Settings; nil while it is, or isn't wanted.
    private(set) static var problem: String?

    private static var installer: WatchdogInstaller {
        WatchdogInstaller(
            folder: Spaces.folder,
            agentPlist: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(MissionControlWatchdog.plistName)"),
            restoreSource: Bundle.main.url(forResource: "uninstall", withExtension: "sh"),
            uid: getuid(), launchctl: launchctl)
    }

    /// Switches Mission Control off, but only once the launch agent that puts it back is written,
    /// loaded and checked. True when it is off; false when it couldn't be armed, in which case
    /// Mission Control is left on (or given back) and `problem` says why.
    @discardableResult
    static func takeOver() -> Bool {
        switch MissionControlSetup.takeOver(takeover, arm: { installer.install(pid: getpid()) }) {
        case .taken(let changed):
            problem = nil
            if changed {
                Trace.log("mission control: off at the Dock (corners answered: \(answeredCorners().map(\.corner.rawValue)))")
                restartDock()
            }
            return true
        case .notArmed(let reason, let restored):
            if problem != reason { Trace.log("mission control: left on, \(reason)") }
            problem = reason
            if restored { restartDock() }
            return false
        }
    }

    /// Gives Mission Control back. `keeping` is a reason it wasn't taken, which Settings goes on showing.
    static func restore(keeping why: String? = nil) {
        problem = why
        let changed = takeover.restore()
        installer.remove()
        if changed {
            Trace.log("mission control: back as it was")
            restartDock()
        }
    }

    /// Quitting for an update: the new build takes over where this one left off, so nothing is
    /// restored. A marker tells the launch agent to give it 30 seconds, not 60, to start.
    static func leaveForUpdate() {
        installer.leaveForUpdate(pid: getpid())
        Trace.log("mission control: left to the update")
    }

    /// Proof that BaneySpaces is alive, for the launch agent.
    static func beat() { try? installer.beatNow(pid: getpid()) }

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
        // Moving into a corner, and pressing the key a corner wants while the pointer rests in it.
        let kinds: NSEvent.EventTypeMask = [.mouseMoved, .flagsChanged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: { [weak self] _ in self?.evaluate() }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: kinds, handler: { [weak self] e in self?.evaluate(); return e }) { monitors.append(l) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        timer?.invalidate()
        timer = nil
        corners = []
        dwell = HotCornerDwell()
        last = nil
    }

    private var last: MissionControlTakeover.Corner?

    private func evaluate() {
        var corner = HotCorners.corner(at: NSEvent.mouseLocation, screens: NSScreen.screens.map(\.frame))
        // A corner macOS answered with a key held waits for that key; a drag in progress isn't a visit.
        if let c = corner {
            let wanted = corners.first { $0.corner == c }
            let held = Int(NSEvent.modifierFlags.rawValue)
            let answered = wanted.map { HotCorners.modifiersHeld(required: $0.modifiers, held: held) } ?? false
            if !answered || NSEvent.pressedMouseButtons != 0 { corner = nil }
        }
        let now = ProcessInfo.processInfo.systemUptime
        // A new visit starts a new wait; the one for the last visit is of no use.
        if corner != last { timer?.invalidate(); timer = nil; last = corner }
        if dwell.update(corner, now: now) {
            Trace.log("hot corner \(corner?.rawValue ?? "?"): overview")
            onOpen()
        } else if let left = dwell.remaining(now: now), timer == nil {
            // The pointer rests, so no more events come: look again when the dwell is up.
            timer = Timer.scheduledTimer(withTimeInterval: left + 0.02, repeats: false) { [weak self] _ in
                self?.timer = nil
                self?.evaluate()
            }
        }
    }
}

/// MultitouchSupport, loaded at run time, as the registry uses it.
final class MultitouchAdapter: TouchFramework {
    typealias Device = UnsafeMutableRawPointer
    typealias DeviceList = CFArray
    typealias Frame = @convention(c) (Device?, UnsafeRawPointer?, Int32, Double, Int32) -> Int32

    private let create: @convention(c) () -> Unmanaged<CFArray>?
    private let registerCallback: @convention(c) (Device, Frame) -> Void
    private let unregisterCallback: @convention(c) (Device, Frame) -> Void
    private let startDevice: @convention(c) (Device, Int32) -> Void
    private let stopDevice: @convention(c) (Device) -> Void
    private let getID: @convention(c) (Device, UnsafeMutablePointer<UInt64>) -> Int32
    private let builtIn: @convention(c) (Device) -> Bool
    private let dimensions: @convention(c) (Device, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32
    private let callback: Frame

    /// nil when the framework or any function in it isn't there.
    init?(callback: @escaping Frame) {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY),
              let create = dlsym(h, "MTDeviceCreateList"), let register = dlsym(h, "MTRegisterContactFrameCallback"),
              let unregister = dlsym(h, "MTUnregisterContactFrameCallback"), let start = dlsym(h, "MTDeviceStart"),
              let stop = dlsym(h, "MTDeviceStop"), let id = dlsym(h, "MTDeviceGetDeviceID"),
              let builtIn = dlsym(h, "MTDeviceIsBuiltIn"), let dims = dlsym(h, "MTDeviceGetSensorSurfaceDimensions")
        else { return nil }
        self.create = unsafeBitCast(create, to: (@convention(c) () -> Unmanaged<CFArray>?).self)
        registerCallback = unsafeBitCast(register, to: (@convention(c) (Device, Frame) -> Void).self)
        unregisterCallback = unsafeBitCast(unregister, to: (@convention(c) (Device, Frame) -> Void).self)
        startDevice = unsafeBitCast(start, to: (@convention(c) (Device, Int32) -> Void).self)
        stopDevice = unsafeBitCast(stop, to: (@convention(c) (Device) -> Void).self)
        getID = unsafeBitCast(id, to: (@convention(c) (Device, UnsafeMutablePointer<UInt64>) -> Int32).self)
        self.builtIn = unsafeBitCast(builtIn, to: (@convention(c) (Device) -> Bool).self)
        dimensions = unsafeBitCast(dims, to: (@convention(c) (Device, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32).self)
        self.callback = callback
    }

    func listDevices() -> CFArray? { create()?.takeRetainedValue() }

    func devices(in list: CFArray) -> [Device] {
        (0..<CFArrayGetCount(list)).compactMap { CFArrayGetValueAtIndex(list, $0).map { UnsafeMutableRawPointer(mutating: $0) } }
    }

    func deviceID(_ d: Device) -> UInt64? {
        var id: UInt64 = 0
        return getID(d, &id) == 0 ? id : nil
    }

    func isBuiltIn(_ d: Device) -> Bool { builtIn(d) }

    func surface(_ d: Device) -> (width: Int, height: Int) {
        var w: Int32 = 0, h: Int32 = 0
        _ = dimensions(d, &w, &h)
        return (Int(w), Int(h))
    }

    func register(_ d: Device) {
        registerCallback(d, callback)
        startDevice(d, 0)
    }

    func unregister(_ d: Device) {
        unregisterCallback(d, callback)
        stopDevice(d)
    }
}

/// The three- or four-finger swipe up that opened Mission Control, and the swipe down that closes
/// the overview. macOS gives apps no public way to see trackpad touches, so this loads the private
/// MultitouchSupport framework at run time, as other trackpad apps do. If it can't be loaded, or
/// reports touches in a layout this build doesn't know, the swipe is off and Settings says so
/// (`problem`); with Mission Control off at the Dock the system view doesn't open either.
///
/// Trackpads are listed once at start and again only when IOKit says a multitouch device came or
/// went, or after sleep (`TrackpadRegistry` keeps them straight). Only trackpads are watched.
final class TrackpadSwipe {
    var onSwipe: (FingerSwipe.Direction) -> Void = { _ in }

    private static var shared: TrackpadSwipe?
    private static let callback: MultitouchAdapter.Frame = { device, data, count, _, _ in
        // A frame with no touches (every finger up) has no data: it still ends the gesture.
        guard let device else { return 0 }
        shared?.frame(device, data, Int(count))
        return 0
    }

    private var registry: TrackpadRegistry<MultitouchAdapter>?
    private let stateLock = NSLock()
    private var loadFailed = false
    private var running = false
    private var wake: NSObjectProtocol?
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var pending: DispatchWorkItem?

    /// Why the swipe doesn't work, in words for Settings; nil while it works or isn't wanted.
    var problem: String? {
        stateLock.lock(); defer { stateLock.unlock() }
        guard running else { return nil }
        let others = "The Mission Control key, ⌃↑, the hot corners and the menu bar menu open the overview."
        if loadFailed {
            return "BaneySpaces couldn't load macOS's trackpad support, so a swipe up on the trackpad does nothing. \(others)"
        }
        if registry?.layoutRejected == true {
            return "This version of macOS reports trackpad touches in a way BaneySpaces doesn't read, so a swipe up on the trackpad does nothing. \(others)"
        }
        return nil
    }

    func start() {
        guard !running else { return }
        TrackpadSwipe.shared = self
        stateLock.lock(); running = true; loadFailed = false; stateLock.unlock()
        guard let adapter = MultitouchAdapter(callback: TrackpadSwipe.callback) else {
            stateLock.lock(); loadFailed = true; stateLock.unlock()
            return Trace.log("trackpad swipe: MultitouchSupport didn't load")
        }
        stateLock.lock()
        registry = TrackpadRegistry(framework: adapter, fingerCounts: TrackpadSwipe.fingerCounts)
        stateLock.unlock()
        refresh()
        watchForDevices()
        wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // Devices stop reporting across sleep; list and start them again.
            self?.registry?.detach()
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
        registry?.detach()
        stateLock.lock(); running = false; registry = nil; stateLock.unlock()
    }

    /// The finger counts follow System Settings; called now and then, it only reads preferences.
    func refreshSettings() { registry?.refreshSettings() }

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

    private func refresh() {
        guard running, let change = registry?.refresh() else { return }
        if change.skipped > 0 { Trace.log("trackpad swipe: skipping \(change.skipped) multitouch device(s) that aren't trackpads") }
        if change.added > 0 || change.removed > 0 {
            Trace.log("trackpad swipe: watching \(registry?.count ?? 0) trackpad(s) (+\(change.added) -\(change.removed))")
        }
    }

    /// Runs on the framework's thread for each frame of touches.
    private func frame(_ device: UnsafeMutableRawPointer, _ data: UnsafeRawPointer?, _ count: Int) {
        stateLock.lock(); let registry = self.registry; stateLock.unlock()
        let available = data.map { count > 0 ? SafeBuffer.length(of: $0) : 0 } ?? 0
        guard let outcome = registry?.frame(device, data: data, count: count, available: available) else { return }
        if let layout = outcome.layout {
            DispatchQueue.main.async { Trace.log("trackpad swipe: touch layout \(layout == .trusted ? "checked" : "not recognised")") }
        }
        if let direction = outcome.direction {
            DispatchQueue.main.async { [weak self] in
                Trace.log("trackpad swipe \(direction == .up ? "up" : "down") with \(outcome.fingers) fingers")
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
