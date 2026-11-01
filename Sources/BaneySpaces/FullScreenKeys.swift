import AppKit
import BaneySpacesCore
import CoreGraphics

/// BaneySpaces full screen (`behavior.fullscreen = baneyspaces`, the default): the green button and
/// ⌃⌘F fill the window's own workspace instead of putting it on a macOS desktop of its own, where
/// BaneySpaces can neither hide nor show it. An event tap catches the click on the green button (a
/// plain click; an Option-click presses it for macOS full screen) and the key, and hands the window
/// to `Spaces.toggleFill`.
///
/// AeroSpace and yabai do not intercept the button: AeroSpace's own `fullscreen` command is a layout
/// state that fills the monitor rectangle (Sources/AppBundle/layout/layoutRecursive.swift, MIT), and it
/// leaves native full screen alone in its own container; yabai's `window --toggle zoom-fullscreen`
/// resizes in the same way and is bound to a key. What is taken from them is that model: filling is a
/// resize inside the workspace. No code is ported; the interception is BaneySpaces' own, through an
/// event tap like `MissionControlKeys`.
///
/// The tap runs on its own thread and never waits for the main thread. It decides in a few
/// milliseconds with short Accessibility reads, and only on ⌃⌘F and on a click that lands on a button.
final class FullScreenKeys {
    enum Request {
        /// Fill (or put back) the window. `nil`: the window in front (the key).
        case fill(AXUIElement?, source: String)
        /// Press the button for macOS full screen (an Option-click).
        case native(AXUIElement)
    }

    /// `behavior.fullscreen`; read on the tap thread, so kept in a lock.
    private static let lock = NSLock()
    private static var _mode = FullScreenMode.default
    static var mode: FullScreenMode {
        get { lock.lock(); defer { lock.unlock() }; return _mode }
        set { lock.lock(); _mode = newValue; lock.unlock(); UserDefaults.standard.set(newValue.rawValue, forKey: "fullscreenMode") }
    }
    /// Loads the stored choice (the default where nobody chose).
    static func loadMode() {
        lock.lock(); defer { lock.unlock() }
        _mode = FullScreenMode(setting: UserDefaults.standard.string(forKey: "fullscreenMode")) ?? .default
    }

    private var tap: CFMachPort?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private let threadLock = NSLock()
    private let onRequest: (Request) -> Void
    private static var shared: FullScreenKeys?

    /// What a swallowed press is waiting for: its release, which is swallowed too.
    private static var armedKey = false
    private static var armed: Armed?
    private struct Armed { let request: Request }

    init(onRequest: @escaping (Request) -> Void) { self.onRequest = onRequest }

    var isActive: Bool { tap != nil }

    func start() {
        guard tap == nil, FullScreenKeys.mode == .baneyspaces else { return }
        FullScreenKeys.shared = self
        FullScreenKeys.armedKey = false
        FullScreenKeys.armed = nil
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDown.rawValue) | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: FullScreenKeys.callback, userInfo: nil)
                ?? CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                     eventsOfInterest: mask, callback: FullScreenKeys.callback, userInfo: nil)
        else { return Trace.log("fullscreen: could not watch the green button and ⌃⌘F; macOS full screen stays as it is") }
        self.tap = tap
        let t = Thread { [weak self] in
            guard let self else { return }
            let loop = CFRunLoopGetCurrent()
            self.threadLock.lock()
            guard self.tap === tap else { self.threadLock.unlock(); return }
            self.runLoop = loop
            self.threadLock.unlock()
            CFRunLoopAddSource(loop, CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        t.name = "BaneySpaces full screen"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        Trace.log("fullscreen: BaneySpaces full screen is on (the green button and ⌃⌘F fill the workspace; Option-click keeps macOS full screen)")
    }

    func stop() {
        threadLock.lock()
        defer { threadLock.unlock() }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil
        runLoop = nil
        thread = nil
        FullScreenKeys.armedKey = false
        FullScreenKeys.armed = nil
    }

    // MARK: On the tap's thread

    private static func modifiers(_ e: CGEvent) -> FullScreenRoute.Modifiers {
        let f = e.flags
        return .init(control: f.contains(.maskControl), command: f.contains(.maskCommand), option: f.contains(.maskAlternate), shift: f.contains(.maskShift))
    }

    private static func ax(_ e: AXUIElement, _ key: String) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(e, 0.08)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, key as CFString, &raw) == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private static func bool(_ e: AXUIElement, _ key: String) -> Bool {
        var raw: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, key as CFString, &raw) == .success && (raw as? NSNumber)?.boolValue == true
    }

    /// The window in front, when it has a green button: and whether it is in macOS full screen.
    private static func frontWindow() -> (window: AXUIElement, native: Bool)? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.08)
        guard let app = ax(sys, kAXFocusedApplicationAttribute) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(app, &pid) == .success, pid != getpid(),
              let window = ax(app, kAXFocusedWindowAttribute), ax(window, kAXFullScreenButtonAttribute) != nil else { return nil }
        return (window, bool(window, "AXFullScreen"))
    }

    /// The window whose green button is under `point`, and whether that window is in macOS full screen.
    private static func greenButton(at point: CGPoint) -> (button: AXUIElement, window: AXUIElement, native: Bool)? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.05)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sys, Float(point.x), Float(point.y), &hit) == .success, let button = hit else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(button, &pid) == .success, pid != getpid() else { return nil }
        AXUIElementSetMessagingTimeout(button, 0.08)
        var role: CFTypeRef?, subrole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(button, kAXRoleAttribute as CFString, &role) == .success, (role as? String) == kAXButtonRole as String,
              let window = ax(button, kAXWindowAttribute) else { return nil }
        AXUIElementCopyAttributeValue(button, kAXSubroleAttribute as CFString, &subrole)
        // The window's full-screen button is the green one; Zoom-only windows have no such button.
        guard (subrole as? String) == "AXFullScreenButton"
                || ax(window, kAXFullScreenButtonAttribute).map({ CFEqual($0, button) }) == true else { return nil }
        return (button, window, bool(window, "AXFullScreen"))
    }

    private static let callback: CGEventTapCallBack = { _, type, event, _ in
        guard let me = FullScreenKeys.shared else { return Unmanaged.passUnretained(event) }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let pass = Unmanaged.passUnretained(event)
        guard mode == .baneyspaces else { return pass }
        switch type {
        case .keyDown, .keyUp:
            let m = modifiers(event)
            guard FullScreenRoute.isFullScreenKey(code: event.getIntegerValueField(.keyboardEventKeycode), m) else {
                // Control or Command let go before F: the release still has to be swallowed.
                return pass
            }
            if type == .keyUp {
                lock.lock(); defer { lock.unlock() }
                if armedKey { armedKey = false; return nil }
                return pass
            }
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                lock.lock(); defer { lock.unlock() }
                return armedKey ? nil : pass
            }
            guard let front = frontWindow(),
                  FullScreenRoute.key(mode: mode, windowInNativeFullScreen: front.native) == .fill else { return pass }
            lock.lock(); armedKey = true; lock.unlock()
            DispatchQueue.main.async { me.onRequest(.fill(nil, source: "key")) }
            return nil
        case .leftMouseDown:
            let m = modifiers(event)
            // Command, Control and Shift are not a plain click on the button: macOS keeps them.
            if m.control || m.command || m.shift { return pass }
            guard let hit = greenButton(at: event.location) else { return pass }
            let req = FullScreenRoute.click(mode: mode, m, windowInNativeFullScreen: hit.native)
            switch req {
            case .passThrough: return pass
            case .fill:
                lock.lock(); armed = Armed(request: .fill(hit.window, source: "green button")); lock.unlock()
            case .native:
                lock.lock(); armed = Armed(request: .native(hit.button)); lock.unlock()
            }
            return nil
        case .leftMouseUp:
            lock.lock()
            let a = armed
            armed = nil
            lock.unlock()
            guard let a else { return pass }
            DispatchQueue.main.async { me.onRequest(a.request) }
            return nil
        default:
            return pass
        }
    }
}
