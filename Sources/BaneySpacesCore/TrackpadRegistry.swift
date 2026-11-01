import Foundation

/// MultitouchSupport as the registry needs it. The real one is loaded at run time by the app; the
/// tests use one that frees a device list's devices when the list goes, as the real one may.
public protocol TouchFramework: AnyObject {
    associatedtype Device: Hashable
    /// What keeps the devices of one listing alive: they must not be used once it is gone.
    associatedtype DeviceList
    func listDevices() -> DeviceList?
    func devices(in list: DeviceList) -> [Device]
    func deviceID(_ device: Device) -> UInt64?
    func isBuiltIn(_ device: Device) -> Bool
    /// Hundredths of a millimetre.
    func surface(_ device: Device) -> (width: Int, height: Int)
    /// Starts frames arriving for the device.
    func register(_ device: Device)
    /// Stops them. The device must still be alive.
    func unregister(_ device: Device)
}

/// The trackpads being watched. Each listing of devices makes new device objects, so a trackpad is
/// told apart by the framework's id; one already watched is never registered twice. A device list
/// is kept for as long as a device from it is registered, and let go only after the device has
/// been unregistered, because the list is what keeps the device alive.
public final class TrackpadRegistry<F: TouchFramework>: @unchecked Sendable {
    private struct Entry {
        let device: F.Device
        /// Held so `device` stays valid until it is unregistered.
        let list: F.DeviceList
        let builtIn: Bool
        var reader = TouchFrameReader()
        var swipe: FingerSwipe
    }

    public struct Change: Equatable {
        public var added = 0, removed = 0, skipped = 0
    }

    /// What one frame did.
    public struct Outcome {
        public var direction: FingerSwipe.Direction?
        public var fingers = 0
        /// The layout check moved to this verdict.
        public var layout: TouchFrameReader.Layout?
    }

    private let framework: F
    private let fingerCounts: (_ builtIn: Bool) -> Set<Int>
    private let lock = NSLock()
    private var entries: [UInt64: Entry] = [:]
    private var idOf: [F.Device: UInt64] = [:]
    private var skipped = Set<UInt64>()

    public init(framework: F, fingerCounts: @escaping (_ builtIn: Bool) -> Set<Int>) {
        self.framework = framework
        self.fingerCounts = fingerCounts
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    /// Any device being watched, for tests.
    var registeredDeviceForTests: F.Device? { lock.lock(); defer { lock.unlock() }; return entries.values.first?.device }

    public var layoutRejected: Bool {
        lock.lock(); defer { lock.unlock() }
        return entries.values.contains { $0.reader.layout == .rejected }
    }

    /// Lists the devices, watches the trackpads not yet watched and lets go of those gone.
    @discardableResult
    public func refresh() -> Change {
        var change = Change()
        guard let list = framework.listDevices() else { return change }
        var present = Set<UInt64>()
        for d in framework.devices(in: list) {
            guard let id = framework.deviceID(d) else { continue }
            present.insert(id)
            lock.lock(); let known = entries[id] != nil || skipped.contains(id); lock.unlock()
            if known { continue }
            let builtIn = framework.isBuiltIn(d)
            let size = framework.surface(d)
            guard TrackpadDevice.isTrackpad(builtIn: builtIn, width: size.width, height: size.height) else {
                lock.lock(); skipped.insert(id); lock.unlock()
                change.skipped += 1
                continue
            }
            let aspect = size.height > 0 ? Float(size.width) / Float(size.height) : FingerSwipe.defaultAspect
            lock.lock()
            entries[id] = Entry(device: d, list: list, builtIn: builtIn, swipe: FingerSwipe(fingers: fingerCounts(builtIn), aspect: aspect))
            idOf[d] = id
            lock.unlock()
            framework.register(d)
            change.added += 1
        }
        lock.lock()
        let gone = entries.filter { !present.contains($0.key) }
        for (id, e) in gone { entries[id] = nil; idOf[e.device] = nil }
        skipped.formIntersection(present)
        lock.unlock()
        // `gone` holds the lists, so these devices are alive for the calls.
        withExtendedLifetime(gone) { for e in gone.values { framework.unregister(e.device) } }
        change.removed = gone.count
        return change
    }

    /// Lets go of every trackpad (quitting, switching off, sleep). The lists are released after
    /// the devices are unregistered, never before.
    public func detach() {
        lock.lock()
        let old = entries
        entries = [:]
        idOf = [:]
        skipped = []
        lock.unlock()
        withExtendedLifetime(old) { for e in old.values { framework.unregister(e.device) } }
    }

    /// The finger counts follow System Settings.
    public func refreshSettings() {
        lock.lock()
        for (id, e) in entries { entries[id]?.swipe.fingers = fingerCounts(e.builtIn) }
        lock.unlock()
    }

    /// One frame from the framework's thread. nil for a device not watched.
    public func frame(_ device: F.Device, data: UnsafeRawPointer?, count: Int, available: Int) -> Outcome? {
        lock.lock(); defer { lock.unlock() }
        guard let id = idOf[device], var e = entries[id] else { return nil }
        let before = e.reader.layout
        var outcome = Outcome()
        if let touches = e.reader.touches(in: data, count: count, available: available) {
            outcome.direction = e.swipe.frame(touches)
            outcome.fingers = touches.count
        }
        entries[id] = e
        if e.reader.layout != before { outcome.layout = e.reader.layout }
        return outcome
    }
}
