import AppKit
import BaneySpacesCore
import Carbon.HIToolbox

/// R-D7: the workspace keys inside a VM that takes the keyboard. UTM, Parallels, VMware Fusion and
/// VirtualBox grab system keys with an event tap while their window has focus, so a global shortcut
/// never fires. While one of them is in front, this watches the same chords one step earlier: a tap
/// at the head of the HID list, remade whenever another app's key tap has got in front of it
/// (`DeviceKeys.shouldRearm`). It takes only ⌘1–9 and ⌘⇧1–9 (the person's workspace modifier); every other key
/// goes to the guest. `defaults write <bundle id> deviceKeysInVMs -bool false` turns it off.
///
/// The tap lives only while such an app is in front, so the rest of the time BaneySpaces holds no extra tap.
final class DeviceKeyBridge {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "deviceKeysInVMs") as? Bool ?? true }

    private var tap: CFMachPort?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private let lock = NSLock()
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var frontApp: String?
    /// Keys whose down event was taken: their up event is taken too.
    fileprivate static var taken = Set<Int64>()
    fileprivate static weak var shared: DeviceKeyBridge?
    fileprivate static var mod = "cmd"
    fileprivate static var front: String?
    fileprivate static var run: ((String) -> Void)?

    /// `run` is called on the main thread with `switch n` or `move n`.
    func start(run: @escaping (String) -> Void) {
        DeviceKeyBridge.run = run
        DeviceKeyBridge.shared = self
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.frontChanged()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.keepAhead() }
        frontChanged()
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        timer?.invalidate()
        timer = nil
        disarm()
    }

    /// The device app in front that captures keys, if any.
    private func capturingFront() -> String? {
        guard Self.enabled, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let facts = DeviceApps.facts(pid: pid), let app = DeviceTable.builtin.app(of: facts),
              let capture = app.keys["macos"]?.capture, capture == "tap" else { return nil }
        return app.id
    }

    private func frontChanged() {
        frontApp = capturingFront()
        DeviceKeyBridge.front = frontApp
        DeviceKeyBridge.mod = Self.modName(Modifier.current)
        if frontApp != nil { arm() } else { disarm() }
    }

    static func modName(_ m: Modifier) -> String {
        switch m {
        case .command: "cmd"
        case .control: "ctrl"
        case .option: "alt"
        case .controlOption: "ctrl+alt"
        }
    }

    /// Another app's key tap may have been made after ours and now sees keys first.
    private func keepAhead() {
        guard frontApp != nil, tap != nil else { return }
        var count: UInt32 = 0
        CGGetEventTapList(0, nil, &count)
        var list = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        CGGetEventTapList(count, &list, &count)
        let keys = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let taps = list.prefix(Int(count)).filter { $0.enabled && $0.eventsOfInterest & keys != 0 && $0.tapPoint == .cghidEventTap }
            .map { (owner: $0.tappingProcess, takesKeys: $0.options == .defaultTap) }
        if DeviceKeys.shouldRearm(taps: taps, ours: getpid()) {
            Trace.log("device keys: another tap is ahead of ours while \(frontApp ?? "?") is in front; making ours again")
            disarm()
            arm()
        }
    }

    private func arm() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: DeviceKeyBridge.callback, userInfo: nil)
        else { return Trace.log("device keys: macOS would not give a key tap (Accessibility or Input Monitoring)") }
        self.tap = tap
        let t = Thread { [weak self] in
            guard let self else { return }
            let loop = CFRunLoopGetCurrent()
            self.lock.lock()
            guard self.tap === tap else { self.lock.unlock(); return }
            self.runLoop = loop
            self.lock.unlock()
            CFRunLoopAddSource(loop, CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        t.name = "BaneySpaces device keys"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        Trace.log("device keys: watching workspace keys while \(frontApp ?? "?") is in front")
    }

    private func disarm() {
        lock.lock()
        defer { lock.unlock() }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil
        runLoop = nil
        thread = nil
        DeviceKeyBridge.taken.removeAll()
    }

    private static let callback: CGEventTapCallBack = { _, type, event, _ in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = DeviceKeyBridge.shared?.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp { return DeviceKeyBridge.taken.remove(code) != nil ? nil : Unmanaged.passUnretained(event) }
        guard type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
            return DeviceKeyBridge.taken.contains(code) ? nil : Unmanaged.passUnretained(event)
        }
        guard let n = Hotkeys.digitKeyCodes.firstIndex(of: Int(code)).map({ $0 + 1 }) else { return Unmanaged.passUnretained(event) }
        let f = event.flags
        var mods = Set<String>()
        if f.contains(.maskCommand) { mods.insert("cmd") }
        if f.contains(.maskControl) { mods.insert("ctrl") }
        if f.contains(.maskAlternate) { mods.insert("alt") }
        if f.contains(.maskShift) { mods.insert("shift") }
        guard let action = DeviceKeys.action(frontApp: DeviceKeyBridge.front, mod: DeviceKeyBridge.mod, bridge: true,
                                             chord: ChordSpec(mods: mods, key: String(n))) else { return Unmanaged.passUnretained(event) }
        taken.insert(code)
        DispatchQueue.main.async { DeviceKeyBridge.run?(action) }
        return nil
    }
}
