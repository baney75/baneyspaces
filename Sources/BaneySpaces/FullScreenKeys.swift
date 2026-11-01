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
/// What the tap costs. It runs on its own thread and decides in microseconds for everything but two
/// things. A key other than F returns at once. A click is tested in memory against the on-screen
/// windows' frames (`ClickZones`, refreshed by every scan and after every click): only a click inside a
/// window's traffic-light corner goes on to Accessibility, and that look has a hard 20 ms budget in
/// total; when it runs out the click passes through untouched. Every Accessibility call here is on a
/// per-app element made for the call, never the system-wide one: a timeout set on the system-wide
/// element is the process's default for every Accessibility call (`AppDelegate.start` sets it to 0.25 s).
final class FullScreenKeys {
    enum Request {
        /// Fill (or put back) the window. `nil`: the window in front (the key).
        case fill(AXUIElement?, source: String)
        /// Press the button for macOS full screen (an Option-click); the window is remembered as a deliberate choice.
        case native(button: AXUIElement, window: AXUIElement?)
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

    /// The on-screen windows' frames, front to back, as the last scan saw them.
    private static var zones = ClickZones()
    static func setZones(_ z: ClickZones) { lock.lock(); zones = z; lock.unlock() }

    private var tap: CFMachPort?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private let threadLock = NSLock()
    private let onRequest: (Request) -> Void
    /// After any click: the windows may have moved, so the frames are read again (on the main thread, throttled).
    var onClickEnded: () -> Void = {}
    private static var shared: FullScreenKeys?

    /// A swallowed press and what it is waiting for. Under `lock`.
    private static var pairing = PressPairing()
    private static var armed: (request: Request, button: AXUIElement?, pid: pid_t)?

    /// The tap could not be made (Input Monitoring not granted): said once, retried quietly each minute.
    private static var failedAt: Date?
    private static var saidFailed = false

    init(onRequest: @escaping (Request) -> Void) { self.onRequest = onRequest }

    var isActive: Bool { tap != nil }

    func start() {
        guard tap == nil, FullScreenKeys.mode == .baneyspaces else { return }
        if let at = FullScreenKeys.failedAt, Date().timeIntervalSince(at) < 60 { return }
        FullScreenKeys.shared = self
        FullScreenKeys.reset()
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDown.rawValue) | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: FullScreenKeys.callback, userInfo: nil)
                ?? CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                     eventsOfInterest: mask, callback: FullScreenKeys.callback, userInfo: nil)
        else {
            FullScreenKeys.failedAt = Date()
            if !FullScreenKeys.saidFailed {
                FullScreenKeys.saidFailed = true
                Trace.log("fullscreen: could not watch the green button and ⌃⌘F; macOS full screen stays as it is (trying again every minute, quietly)")
            }
            return
        }
        FullScreenKeys.failedAt = nil
        FullScreenKeys.saidFailed = false
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
        FullScreenKeys.reset()
    }

    private static func reset() {
        lock.lock(); pairing.reset(); armed = nil; lock.unlock()
    }

    // MARK: On the tap's thread

    /// Every Accessibility call here shares one 20 ms budget, so a hung app costs a click at most 20 ms,
    /// and then the click passes through untouched.
    private struct Budget {
        let end = CFAbsoluteTimeGetCurrent() + 0.02
        var exhausted: Bool { CFAbsoluteTimeGetCurrent() >= end }
        /// Sets the element's own timeout to what is left, then reads. Nil when the budget is spent or the read fails.
        func read(_ e: AXUIElement, _ attribute: String) -> CFTypeRef? {
            let left = end - CFAbsoluteTimeGetCurrent()
            guard left > 0.001 else { return nil }
            AXUIElementSetMessagingTimeout(e, Float(left))
            var raw: CFTypeRef?
            return AXUIElementCopyAttributeValue(e, attribute as CFString, &raw) == .success ? raw : nil
        }
        func element(_ e: AXUIElement, _ attribute: String) -> AXUIElement? {
            guard let raw = read(e, attribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            return (raw as! AXUIElement)
        }
        func bool(_ e: AXUIElement, _ attribute: String) -> Bool { (read(e, attribute) as? NSNumber)?.boolValue == true }
    }

    private static func modifiers(_ e: CGEvent) -> FullScreenRoute.Modifiers {
        let f = e.flags
        return .init(control: f.contains(.maskControl), command: f.contains(.maskCommand), option: f.contains(.maskAlternate), shift: f.contains(.maskShift))
    }

    /// The window in front of `pid`'s app, when it has a green button: and whether it is in macOS full screen.
    private static func frontWindow(pid: pid_t) -> (window: AXUIElement, native: Bool)? {
        let budget = Budget()
        let app = AXUIElementCreateApplication(pid)
        guard pid != getpid(), let window = budget.element(app, kAXFocusedWindowAttribute),
              budget.element(window, kAXFullScreenButtonAttribute) != nil else { return nil }
        return (window, budget.bool(window, "AXFullScreen"))
    }

    /// The green button of a window of `pid` that lies under `point`, with its window and whether that
    /// window is in macOS full screen.
    private static func greenButton(at point: CGPoint, pid: pid_t) -> (button: AXUIElement, window: AXUIElement, native: Bool)? {
        let budget = Budget()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.02)
        var hit: AXUIElement?
        guard pid != getpid(), AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success, let button = hit,
              (budget.read(button, kAXRoleAttribute) as? String) == kAXButtonRole as String,
              let window = budget.element(button, kAXWindowAttribute) else { return nil }
        let subrole = budget.read(button, kAXSubroleAttribute) as? String
        // The window's full-screen button is the green one; Zoom-only windows have no such button.
        guard subrole == "AXFullScreenButton" || budget.element(window, kAXFullScreenButtonAttribute).map({ CFEqual($0, button) }) == true else { return nil }
        return (button, window, budget.bool(window, "AXFullScreen"))
    }

    private static let callback: CGEventTapCallBack = { _, type, event, _ in
        let pass = Unmanaged.passUnretained(event)
        guard let me = FullScreenKeys.shared else { return pass }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // A press waiting for its release will never get it now.
            reset()
            if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        switch type {
        case .keyDown, .keyUp:
            // Anything but F returns at once.
            guard event.getIntegerValueField(.keyboardEventKeycode) == Int64(FullScreenRoute.keyF) else { return pass }
            if type == .keyUp {
                // Whatever is held now, the release of an F whose press was swallowed is swallowed.
                lock.lock(); defer { lock.unlock() }
                return pairing.keyUp() ? nil : pass
            }
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                lock.lock(); defer { lock.unlock() }
                return pairing.keyArmed ? nil : pass
            }
            guard FullScreenRoute.isFullScreenKey(code: Int64(FullScreenRoute.keyF), modifiers(event)), mode == .baneyspaces,
                  let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
                  let front = frontWindow(pid: pid),
                  FullScreenRoute.key(mode: mode, windowInNativeFullScreen: front.native) == .fill else { return pass }
            lock.lock(); pairing.armKey(); lock.unlock()
            DispatchQueue.main.async { me.onRequest(.fill(nil, source: "key")) }
            return nil
        case .leftMouseDown:
            let m = modifiers(event)
            // Command, Control and Shift are not a plain click on the button: macOS keeps them.
            guard mode == .baneyspaces, !(m.control || m.command || m.shift) else { return pass }
            lock.lock(); let z = zones; lock.unlock()
            var found: (button: AXUIElement, window: AXUIElement, native: Bool)?
            // In memory first: only a click in a window's traffic-light corner is looked at.
            guard let entry = ClickFilter.request(at: event.location, zones: z, look: { w in
                found = greenButton(at: event.location, pid: w.pid)
                return found != nil
            }), let hit = found else { return pass }
            let req = FullScreenRoute.click(mode: mode, m, windowInNativeFullScreen: hit.native)
            let request: Request
            switch req {
            case .passThrough: return pass
            case .fill: request = .fill(hit.window, source: "green button")
            case .native: request = .native(button: hit.button, window: hit.window)
            }
            lock.lock()
            pairing.armMouse(event.getIntegerValueField(.mouseEventNumber))
            armed = (request, hit.button, entry.pid)
            lock.unlock()
            return nil
        case .leftMouseDragged:
            lock.lock(); defer { lock.unlock() }
            return pairing.downNumber == event.getIntegerValueField(.mouseEventNumber) ? nil : pass
        case .leftMouseUp:
            DispatchQueue.main.async { me.onClickEnded() }
            let number = event.getIntegerValueField(.mouseEventNumber)
            lock.lock()
            let mine = pairing.downNumber == number
            let a = armed
            lock.unlock()
            guard mine, let a else { return pass }
            // Still on the same button at the release, or the press was a drag away and does nothing.
            let on = greenButton(at: event.location, pid: a.pid).map { hit in a.button.map { CFEqual($0, hit.button) } ?? false } ?? false
            lock.lock()
            let release = pairing.mouseUp(number: number, onButton: on)
            armed = nil
            lock.unlock()
            if release == .swallowAndAct { DispatchQueue.main.async { me.onRequest(a.request) } }
            return nil
        default:
            return pass
        }
    }
}
