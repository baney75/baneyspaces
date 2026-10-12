import AppKit
import CoreGraphics

/// Catches the Mission Control key (F3 on Apple keyboards) and ⌃↑ before macOS does, and opens
/// the BaneySpaces viewer instead. An event tap needs the same Accessibility access BaneySpaces
/// already has. Turning it off hands the keys straight back to Mission Control.
final class MissionControlKeys {
    static let missionControlKey: Int64 = 160
    static let upArrow: Int64 = 126
    static let tabKey: Int64 = 48
    static let escapeKey: Int64 = 53

    private var tap: CFMachPort?
    private let onPress: () -> Void
    private static var shared: MissionControlKeys?

    init(onPress: @escaping () -> Void) {
        self.onPress = onPress
    }

    /// What ⌘Tab does. Off (macOS's own switcher) unless chosen in setup.
    enum CmdTabMode: String, CaseIterable, Identifiable {
        /// macOS's app switcher, untouched.
        case off
        /// Every app with a window, on any workspace, most recent first; picking one goes there.
        case apps
        /// Workspaces, most recent first.
        case workspaces

        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: "macOS"
            case .apps: "Apps on every workspace"
            case .workspaces: "Workspaces"
            }
        }
    }

    static var cmdTabMode: CmdTabMode {
        get {
            if let raw = UserDefaults.standard.string(forKey: "cmdTabMode"), let m = CmdTabMode(rawValue: raw) { return m }
            // 0.2 had one switch: ⌘Tab switches workspaces.
            return UserDefaults.standard.bool(forKey: "cmdTabSwitchesWorkspaces") ? .workspaces : .off
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "cmdTabMode") }
    }

    static var cmdTabEnabled: Bool { cmdTabMode != .off }

    /// Called on the main thread while ⌘ is held: Tab (forward) or ⇧Tab (back), and whether the
    /// press is a repeat of a held Tab; ⌘ released; Esc.
    var onCmdTab: (_ forward: Bool, _ isRepeat: Bool, _ time: Double) -> Void = { _, _, _ in }
    /// A gesture ended while Tab may still be held, so its repeats and its release are swallowed
    /// instead of typing into the app just picked. Set on the tap thread, or by the switcher when
    /// it notices ⌘ let go that the tap missed.
    private static var _swallowTab = false
    private static var swallowTab: Bool {
        get { gestureLock.lock(); defer { gestureLock.unlock() }; return _swallowTab }
        set { gestureLock.lock(); _swallowTab = newValue; gestureLock.unlock() }
    }

    /// The gesture ended without the tap seeing ⌘ let go.
    static func gestureEndedElsewhere() {
        inGesture = false
        swallowTab = true
    }
    /// Tab let go during a gesture, ⌘ still held.
    var onTabUp: () -> Void = {}
    var onCmdReleased: () -> Void = {}
    var onCancel: () -> Void = {}
    /// Read on the tap thread; set when a ⌘Tab gesture starts, cleared when it ends.
    private static let gestureLock = NSLock()
    private static var _inGesture = false
    static var inGesture: Bool {
        get { gestureLock.lock(); defer { gestureLock.unlock() }; return _inGesture }
        set { gestureLock.lock(); _inGesture = newValue; gestureLock.unlock() }
    }
    private static var tabEnabledOnTap = false
    /// Whether the switcher can act right now (set on the main thread). When it can't, ⌘Tab
    /// passes through to the normal app switcher instead of vanishing.
    private static var _started = false, _viewerOpen = false
    static var switcherReady: Bool {
        gestureLock.lock(); defer { gestureLock.unlock() }
        return _started && !_viewerOpen
    }
    static var appStarted: Bool {
        get { gestureLock.lock(); defer { gestureLock.unlock() }; return _started }
        set { gestureLock.lock(); _started = newValue; gestureLock.unlock() }
    }
    static var viewerOpen: Bool {
        get { gestureLock.lock(); defer { gestureLock.unlock() }; return _viewerOpen }
        set { gestureLock.lock(); _viewerOpen = newValue; gestureLock.unlock() }
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
        guard tap == nil, MissionControlKeys.enabled || MissionControlKeys.cmdTabEnabled else { return }
        MissionControlKeys.tabEnabledOnTap = MissionControlKeys.cmdTabEnabled
        MissionControlKeys.inGesture = false
        MissionControlKeys.shared = self
        MissionControlKeys.takeControlUp = SystemShortcuts.missionControlOnControlUp
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
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
        MissionControlKeys.inGesture = false
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
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        // ⌘ let go ends a ⌘Tab gesture. The modifier change itself always passes through.
        if type == .flagsChanged {
            if inGesture, !event.flags.contains(.maskCommand) {
                inGesture = false
                swallowTab = true
                DispatchQueue.main.async { me.onCmdReleased() }
            }
            return Unmanaged.passUnretained(event)
        }
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if code == tabKey, swallowTab, !inGesture {
            // A fresh press means Tab was let go already; it's a new keystroke and passes.
            if type == .keyDown && !isRepeat { swallowTab = false } else {
                if type == .keyUp { swallowTab = false }
                return nil
            }
        }
        if tabEnabledOnTap, code == tabKey, type == .keyDown, !(switcherReady || inGesture),
           event.flags.intersection([.maskControl, .maskCommand, .maskAlternate]) == .maskCommand {
            let started = appStarted, viewer = viewerOpen
            DispatchQueue.main.async { Trace.log("cmdTab passed to macOS started=\(started) viewerOpen=\(viewer)") }
        }
        if tabEnabledOnTap, code == tabKey, switcherReady || inGesture {
            let mods = event.flags.intersection([.maskControl, .maskCommand, .maskAlternate])
            if mods == .maskCommand {
                // A held Tab that wasn't part of a gesture (⌘ pressed after Tab) starts nothing.
                if isRepeat && !inGesture { return nil }
                if type == .keyDown {
                    inGesture = true
                    let back = event.flags.contains(.maskShift)
                    // When the key arrived here, not when the main thread gets to it. This thread
                    // never waits on the main one, so the reading is close to the press.
                    let time = ProcessInfo.processInfo.systemUptime
                    DispatchQueue.main.async { me.onCmdTab(!back, isRepeat, time) }
                } else if type == .keyUp, inGesture {
                    DispatchQueue.main.async { me.onTabUp() }
                }
                return nil
            }
        }
        if inGesture, code == escapeKey {
            if type == .keyDown {
                inGesture = false
                swallowTab = true
                DispatchQueue.main.async { me.onCancel() }
            }
            return nil
        }
        // Any other key while the switcher is up is swallowed, as the system switcher does:
        // ⌘Q or ⌘W would otherwise quit or close whatever app is in front.
        if inGesture, type == .keyDown || type == .keyUp { return nil }
        guard MissionControlKeys.enabled, isMissionControl(event) else { return Unmanaged.passUnretained(event) }
        if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            DispatchQueue.main.async { me.onPress() }
        }
        return nil
    }
}
