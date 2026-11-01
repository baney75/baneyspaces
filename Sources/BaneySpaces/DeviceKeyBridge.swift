import AppKit
import BaneySpacesCore
import Carbon.HIToolbox

/// R-D7: the workspace keys inside a VM that takes the keyboard. UTM, Parallels, VMware Fusion and
/// VirtualBox grab system keys with an event tap while their window has focus, so a global shortcut
/// never fires. While one of them is in front, this watches the same chords one step earlier: a tap
/// at the head of the HID list, made again when another key-taking tap has appeared since ours was
/// (`DeviceKeys.shouldRearm`; the list's order is not documented, so only a newcomer counts). It takes only
/// the workspace modifier with 1-9 (switch) and with ⇧ 1-9 (move); every other key goes to the guest. The modifier
/// itself is held back from the guest while a chord is possible and replayed if none follows (`KeyBridgeState`).
/// `defaults write <bundle id> deviceKeysInVMs -bool false` turns it off.
///
/// Everything the tap callback and the main thread share is in `KeyBridgeState`, behind one lock. The tap
/// lives only while such an app is in front, so the rest of the time BaneySpaces holds no extra tap.
final class DeviceKeyBridge {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "deviceKeysInVMs") as? Bool ?? true }

    private let state = KeyBridgeState()
    private var tap: CFMachPort?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    /// Bumped by every arm and disarm, under `lock`. The tap's thread checks it at each step of its setup; a thread
    /// whose generation has passed tears itself down instead of using a port that was invalidated.
    private var generation = 0
    /// Guards `tap`, `thread` and `runLoop`, which the main thread and the tap's thread both touch.
    private let lock = NSLock()
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var frontApp: String?
    private var knownTaps = Set<UInt32>()
    private var lastRearm = Date.distantPast
    fileprivate static weak var current: DeviceKeyBridge?
    private var run: ((String) -> Void)?

    /// `run` is called on the main thread with `switch n` or `move n`.
    func start(run: @escaping (String) -> Void) {
        self.run = run
        DeviceKeyBridge.current = self
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
              app.keys["macos"]?.capture == "tap" else { return nil }
        return app.id
    }

    private func frontChanged() {
        frontApp = capturingFront()
        state.setFront(frontApp, mod: Self.modName(Modifier.current))
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

    private func tapList() -> [(id: UInt32, owner: Int32, takesKeys: Bool)] {
        var count: UInt32 = 0
        CGGetEventTapList(0, nil, &count)
        var list = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        CGGetEventTapList(count, &list, &count)
        let keys = CGEventMask(1 << CGEventType.keyDown.rawValue)
        return list.prefix(Int(count)).filter { $0.enabled && $0.eventsOfInterest & keys != 0 && $0.tapPoint == .cghidEventTap }
            .map { (id: $0.eventTapID, owner: $0.tappingProcess, takesKeys: $0.options == .defaultTap) }
    }

    /// Another app's key tap that appeared after ours may see keys first. At most one remake every 5 s.
    private func keepAhead() {
        guard frontApp != nil, hasTap, Date().timeIntervalSince(lastRearm) > 5 else { return }
        if DeviceKeys.shouldRearm(taps: tapList(), known: knownTaps, ours: getpid()) {
            lastRearm = Date()
            Trace.log("device keys: a new key tap appeared while \(frontApp ?? "?") is in front; making ours again")
            disarm()
            arm()
        }
    }

    private var hasTap: Bool { lock.lock(); defer { lock.unlock() }; return tap != nil }

    private func arm() {
        lock.lock()
        guard tap == nil else { lock.unlock(); return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDown.rawValue) | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
        guard let made = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: DeviceKeyBridge.callback, userInfo: nil) else {
            lock.unlock()
            return Trace.log("device keys: macOS would not give a key tap (Accessibility or Input Monitoring)")
        }
        generation += 1
        let mine = generation
        tap = made
        state.arm()
        let t = Thread { [weak self] in
            guard let self else { return }
            let loop = CFRunLoopGetCurrent()
            // The run loop source is made under the lock, in the same step that checks this generation is still
            // current: disarm() invalidates the port under the same lock, and a source made from an invalid port is nil.
            self.lock.lock()
            guard self.generation == mine, self.tap === made, let source = CFMachPortCreateRunLoopSource(nil, made, 0) else {
                self.lock.unlock()
                return
            }
            self.runLoop = loop
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: made, enable: true)
            self.lock.unlock()
            // Run returns at once if disarm() invalidated the port since: the loop then has no live source.
            CFRunLoopRun()
        }
        t.name = "BaneySpaces device keys"
        t.qualityOfService = .userInteractive
        thread = t
        lock.unlock()
        t.start()
        knownTaps = Set(tapList().map(\.id))
        Trace.log("device keys: watching workspace keys while \(frontApp ?? "?") is in front")
    }

    private func disarm() {
        state.disarm()
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil
        runLoop = nil
        thread = nil
    }

    /// Which modifier a flagsChanged key code is, and the device-dependent flag bit that says whether it is down.
    private static let modifierKeys: [Int64: (name: String, bit: UInt64)] = [
        55: ("cmd", 0x8), 54: ("cmd", 0x10), 59: ("ctrl", 0x1), 62: ("ctrl", 0x2000),
        58: ("alt", 0x20), 61: ("alt", 0x40), 56: ("shift", 0x2), 60: ("shift", 0x4),
    ]

    /// Shows the guest the modifiers that were held back, in order, just ahead of the event being passed on.
    /// `tapPostEvent` puts them in the stream for the taps after ours, which includes the VM's and never ours.
    private static func replay(_ codes: [Int64], proxy: CGEventTapProxy, flags: CGEventFlags) {
        var raw: UInt64 = flags.rawValue & ~(CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskShift.rawValue)
        for code in codes {
            guard let m = modifierKeys[code], let ev = CGEvent(source: nil) else { continue }
            switch m.name {
            case "cmd": raw |= CGEventFlags.maskCommand.rawValue
            case "ctrl": raw |= CGEventFlags.maskControl.rawValue
            case "alt": raw |= CGEventFlags.maskAlternate.rawValue
            default: raw |= CGEventFlags.maskShift.rawValue
            }
            raw |= m.bit
            ev.type = .flagsChanged
            ev.setIntegerValueField(.keyboardEventKeycode, value: code)
            ev.flags = CGEventFlags(rawValue: raw)
            ev.tapPostEvent(proxy)
        }
    }

    private static let callback: CGEventTapCallBack = { proxy, type, event, _ in
        guard let me = DeviceKeyBridge.current else { return Unmanaged.passUnretained(event) }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            me.lock.lock(); let tap = me.tap; me.lock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        func answer(_ v: KeyBridgeState.Verdict) -> Unmanaged<CGEvent>? {
            switch v {
            case .pass: return Unmanaged.passUnretained(event)
            case .swallow: return nil
            case .run(let action):
                DispatchQueue.main.async { me.run?(action) }
                return nil
            case .replay(let codes):
                DeviceKeyBridge.replay(codes, proxy: proxy, flags: event.flags)
                return Unmanaged.passUnretained(event)
            }
        }
        switch type {
        case .flagsChanged:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            guard let m = modifierKeys[code] else { return Unmanaged.passUnretained(event) }
            return answer(me.state.modifier(code: code, name: m.name, down: event.flags.rawValue & m.bit != 0))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return answer(me.state.mouseDown())
        case .keyUp:
            return answer(me.state.keyUp(code: event.getIntegerValueField(.keyboardEventKeycode)))
        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let n = Hotkeys.digitKeyCodes.firstIndex(of: Int(code)).map { $0 + 1 }
            let f = event.flags
            var mods = Set<String>()
            if f.contains(.maskCommand) { mods.insert("cmd") }
            if f.contains(.maskControl) { mods.insert("ctrl") }
            if f.contains(.maskAlternate) { mods.insert("alt") }
            if f.contains(.maskShift) { mods.insert("shift") }
            return answer(me.state.keyDown(code: code, workspaceKey: n, mods: mods, repeating: event.getIntegerValueField(.keyboardEventAutorepeat) != 0))
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
