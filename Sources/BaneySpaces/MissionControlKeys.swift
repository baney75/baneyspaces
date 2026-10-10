import AppKit
import CoreGraphics

/// Catches the Mission Control key (F3 on Apple keyboards) and ⌃↑ before macOS does, and opens
/// the BaneySpaces viewer instead. An event tap needs the same Accessibility access BaneySpaces
/// already has. Turning it off hands the keys straight back to Mission Control.
final class MissionControlKeys {
    static let missionControlKey: Int64 = 160
    static let upArrow: Int64 = 126

    private var tap: CFMachPort?
    private let onPress: () -> Void
    private static var shared: MissionControlKeys?

    init(onPress: @escaping () -> Void) {
        self.onPress = onPress
    }

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "viewerReplacesMissionControl") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "viewerReplacesMissionControl") }
    }

    /// The tap runs on its own thread. A tap that can swallow keys holds every keystroke on the
    /// Mac until it answers, so it must never wait behind window work on the main thread. The
    /// tap is made here on the main thread, so start and stop never race the thread.
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private let lock = NSLock()
    /// ⌃↑ is only taken while macOS still uses it for Mission Control.
    fileprivate static var takeControlUp = true

    /// True while the key watcher is installed. False when it is switched off or when macOS
    /// refused it (no Accessibility yet); `start()` can simply be called again to retry.
    var isActive: Bool { tap != nil }

    func start() {
        guard tap == nil, MissionControlKeys.enabled else { return }
        MissionControlKeys.shared = self
        MissionControlKeys.takeControlUp = SystemShortcuts.missionControlOnControlUp
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        // The HID tap sees keys before macOS turns them into Mission Control; the session tap is
        // the fallback if macOS won't allow the earlier one.
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: MissionControlKeys.callback, userInfo: nil)
                ?? CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                     eventsOfInterest: mask, callback: MissionControlKeys.callback, userInfo: nil)
        else { return NSLog("BaneySpaces: could not watch the Mission Control key") }
        self.tap = tap
        let t = Thread { [weak self] in
            guard let self else { return }
            let loop = CFRunLoopGetCurrent()
            self.lock.lock()
            // stop() may have run before this thread got going; then there is nothing to do.
            guard self.tap === tap else { self.lock.unlock(); return }
            self.runLoop = loop
            self.lock.unlock()
            CFRunLoopAddSource(loop, CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        t.name = "BaneySpaces Mission Control key"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil
        runLoop = nil
        thread = nil
    }

    static func isMissionControl(_ event: CGEvent) -> Bool {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if code == missionControlKey { return true }
        let mods = event.flags.intersection([.maskControl, .maskCommand, .maskAlternate, .maskShift])
        return takeControlUp && code == upArrow && mods == .maskControl
    }

    private static let callback: CGEventTapCallBack = { _, type, event, _ in
        guard let me = MissionControlKeys.shared else { return Unmanaged.passUnretained(event) }
        // macOS switches a slow tap off; switch it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard isMissionControl(event) else { return Unmanaged.passUnretained(event) }
        if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            DispatchQueue.main.async { me.onPress() }
        }
        return nil
    }
}
