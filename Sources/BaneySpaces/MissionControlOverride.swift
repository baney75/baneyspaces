import AppKit
import BaneySpacesCore

/// macOS's Mission Control, kept off while BaneySpaces' overview takes its place. The settings
/// are saved first and put back when the switch goes off, when BaneySpaces loses Accessibility,
/// or when it's uninstalled (`MissionControlTakeover` has the rules; `uninstall.sh` reads the same
/// record). Not on quit: with BaneySpaces gone the Dock's switch just leaves Mission Control off
/// until the next launch, and putting it back would restart the Dock on every quit and update.
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
    }

    static func restore() {
        if takeover.restore() {
            Trace.log("mission control: back as it was")
            restartDock()
        }
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
/// moves or clicks the pointer, and a global mouse-moved watch needs no permission.
final class HotCornerWatcher {
    var onOpen: () -> Void = {}
    private var corners: [(corner: MissionControlTakeover.Corner, modifiers: Int)] = []
    private var dwell = HotCornerDwell()
    private var monitor: Any?
    private var timer: Timer?

    var isRunning: Bool { monitor != nil }

    func start(corners: [(corner: MissionControlTakeover.Corner, modifiers: Int)]) {
        stop()
        self.corners = corners
        guard !corners.isEmpty else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in self?.evaluate() }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
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

        static func load() -> API? {
            guard let h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY),
                  let create = dlsym(h, "MTDeviceCreateList"), let register = dlsym(h, "MTRegisterContactFrameCallback"),
                  let unregister = dlsym(h, "MTUnregisterContactFrameCallback"), let start = dlsym(h, "MTDeviceStart"),
                  let stop = dlsym(h, "MTDeviceStop")
            else { return nil }
            return API(create: unsafeBitCast(create, to: (@convention(c) () -> Unmanaged<CFArray>?).self),
                       register: unsafeBitCast(register, to: (@convention(c) (Device, Frame) -> Void).self),
                       unregister: unsafeBitCast(unregister, to: (@convention(c) (Device, Frame) -> Void).self),
                       start: unsafeBitCast(start, to: (@convention(c) (Device, Int32) -> Void).self),
                       stop: unsafeBitCast(stop, to: (@convention(c) (Device) -> Void).self))
        }
    }

    /// One touch is 96 bytes: the state at byte 20, the position (0...1 from the left and the
    /// bottom) at bytes 32 and 36.
    private static let touchSize = 96
    private static let states: ClosedRange<Int32> = 3...4   // making a touch, touching

    private static var shared: TrackpadSwipe?
    private static let callback: Frame = { device, data, count, _, _ in
        guard let device, let data, count > 0 else { return 0 }
        shared?.frame(device, data, Int(count))
        return 0
    }

    private let lock = NSLock()
    private var api: API?
    /// Every device list asked for, kept so the devices in `registered` stay valid until `detach`.
    private var lists: [CFArray] = []
    private var registered: [Device] = []
    private var detectors: [Device: FingerSwipe] = [:]
    private var fingers = Set<Int>()
    private var layoutBad = false
    private var sawFrame = false
    private var loadFailed = false
    private var running = false
    private var timer: Timer?
    private var wake: NSObjectProtocol?

    /// Why the swipe doesn't work, in words for Settings; nil while it works or isn't wanted.
    var problem: String? {
        lock.lock(); defer { lock.unlock() }
        guard running else { return nil }
        if loadFailed {
            return "BaneySpaces couldn't load macOS's trackpad support, so a swipe up on the trackpad does nothing. The Mission Control key, ⌃↑, the hot corners and the menu bar menu open the overview."
        }
        if layoutBad {
            return "This version of macOS reports trackpad touches in a way BaneySpaces doesn't read, so a swipe up on the trackpad does nothing. The Mission Control key, ⌃↑, the hot corners and the menu bar menu open the overview."
        }
        return nil
    }

    func start() {
        guard !running else { return }
        TrackpadSwipe.shared = self
        lock.lock()
        running = true
        layoutBad = false
        sawFrame = false
        loadFailed = false
        lock.unlock()
        guard let api = API.load() else {
            lock.lock(); loadFailed = true; lock.unlock()
            return Trace.log("trackpad swipe: MultitouchSupport didn't load")
        }
        self.api = api
        refresh()
        // Trackpads come and go, and the settings change; both are looked at again every few seconds.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // Devices stop reporting across sleep; start them again.
            self?.detach()
            self?.refresh()
        }
    }

    func stop() {
        guard running else { return }
        timer?.invalidate()
        timer = nil
        if let wake { NSWorkspace.shared.notificationCenter.removeObserver(wake) }
        wake = nil
        detach()
        lock.lock(); running = false; lock.unlock()
        api = nil
    }

    private func detach() {
        guard let api else { return }
        lock.lock()
        let devices = registered
        registered = []
        detectors = [:]
        lock.unlock()
        for d in devices { api.unregister(d, TrackpadSwipe.callback); api.stop(d) }
        lists = []
    }

    private func refresh() {
        guard let api, running else { return }
        let counts = TrackpadSwipe.fingerCounts()
        lock.lock(); fingers = counts; lock.unlock()
        guard !(counts.isEmpty && registered.isEmpty) else { return }
        guard let found = api.create()?.takeRetainedValue() else { return }
        var added = 0
        for i in 0..<CFArrayGetCount(found) {
            guard let raw = CFArrayGetValueAtIndex(found, i) else { continue }
            let d = UnsafeMutableRawPointer(mutating: raw)
            lock.lock(); let known = registered.contains(d); lock.unlock()
            if known { continue }
            lock.lock(); registered.append(d); detectors[d] = FingerSwipe(fingers: counts); lock.unlock()
            api.register(d, TrackpadSwipe.callback)
            api.start(d, 0)
            added += 1
        }
        // The devices stay valid while the list that holds them does.
        if added > 0 {
            lists.append(found)
            Trace.log("trackpad swipe: watching \(added) device(s), fingers \(counts.sorted())")
        }
    }

    /// Runs on the framework's thread for each frame of touches.
    private func frame(_ device: Device, _ data: UnsafeRawPointer, _ count: Int) {
        var touches: [FingerSwipe.Touch] = []
        var odd = false
        for i in 0..<count {
            let base = data + i * TrackpadSwipe.touchSize
            guard TrackpadSwipe.states.contains(base.load(fromByteOffset: 20, as: Int32.self)) else { continue }
            let x = base.load(fromByteOffset: 32, as: Float.self), y = base.load(fromByteOffset: 36, as: Float.self)
            if !(x.isFinite && y.isFinite && (-0.1...1.1).contains(x) && (-0.1...1.1).contains(y)) { odd = true }
            touches.append(.init(x: x, y: y))
        }
        lock.lock()
        if odd, !layoutBad {
            layoutBad = true
            lock.unlock()
            DispatchQueue.main.async { Trace.log("trackpad swipe: touches don't read as positions; the swipe is off") }
            return
        }
        guard !layoutBad, var detector = detectors[device] else { lock.unlock(); return }
        let first = !sawFrame
        sawFrame = true
        detector.fingers = fingers
        let direction = detector.frame(touches)
        detectors[device] = detector
        lock.unlock()
        if first { DispatchQueue.main.async { Trace.log("trackpad swipe: touches arriving") } }
        if let direction {
            DispatchQueue.main.async { [weak self] in
                Trace.log("trackpad swipe \(direction == .up ? "up" : "down") with \(touches.count) fingers")
                self?.onSwipe(direction)
            }
        }
    }

    /// The finger counts macOS gives Mission Control, from the built-in trackpad's settings and a
    /// Bluetooth trackpad's, whichever has them.
    static func fingerCounts() -> Set<Int> {
        let domains = ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"]
        func read(_ key: String, _ domain: String) -> Int? {
            CFPreferencesAppSynchronize(domain as CFString)
            return (CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? NSNumber)?.intValue
        }
        var set = Set<Int>()
        var any = false
        for d in domains {
            let three = read("TrackpadThreeFingerVertSwipeGesture", d), four = read("TrackpadFourFingerVertSwipeGesture", d)
            let drag = read("TrackpadThreeFingerDrag", d) ?? 0
            // A trackpad with none of these set is macOS's defaults, not an extra opinion.
            guard three != nil || four != nil else { continue }
            any = true
            set.formUnion(FingerSwipe.fingerCounts(threeFingers: three, fourFingers: four, threeFingerDrag: drag != 0))
        }
        return any ? set : FingerSwipe.fingerCounts(threeFingers: nil, fourFingers: nil, threeFingerDrag: false)
    }
}
