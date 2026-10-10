import AppKit
import ApplicationServices
import BaneySpacesCore

// Private but stable since macOS 10.x: the WindowServer number behind an Accessibility window.
// Every window manager on the Mac relies on it; there is no public way to match the two.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// One real window, reached through Accessibility.
struct Window {
    let id: WindowID
    let element: AXUIElement
    let pid: pid_t
    let appName: String

    var frame: CGRect? {
        guard Windows.isResponsive(pid), let p: CGPoint = element.value(kAXPositionAttribute, .cgPoint),
              let s: CGSize = element.value(kAXSizeAttribute, .cgSize) else { return nil }
        return CGRect(origin: p, size: s)
    }

    var isMinimized: Bool { Windows.isResponsive(pid) && element.bool(kAXMinimizedAttribute) }
    var title: String { Windows.isResponsive(pid) ? element.string(kAXTitleAttribute) ?? "" : "" }
    var isFullScreen: Bool { Windows.isResponsive(pid) && element.bool("AXFullScreen") }

    func setOrigin(_ p: CGPoint) {
        guard Windows.isResponsive(pid) else { return }
        element.set(kAXPositionAttribute, p, .cgPoint)
    }
    func setSize(_ s: CGSize) { element.set(kAXSizeAttribute, s, .cgSize) }
    /// Moves a window back to `r`. A parked window kept its size, so usually one move is all it
    /// takes; resizing makes apps lay out again, which is slow and can flicker.
    func place(_ r: CGRect, currentSize: CGSize) {
        if currentSize == r.size { setOrigin(r.origin) } else { setFrame(r) }
    }

    func setFrame(_ r: CGRect) {
        // Size, move, size again: a window that would cross a screen edge gets clamped otherwise.
        setSize(r.size)
        setOrigin(r.origin)
        setSize(r.size)
    }

    func unminimize() {
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }

    func exitFullScreen() {
        AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString, kCFBooleanFalse)
    }

    func pressFullScreenButton() {
        guard let button: AXUIElement = element.value(kAXFullScreenButtonAttribute) else { return }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
    }

    func focus() {
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: pid)?.activate()
    }
}

/// The regular apps that are running, kept current by launch and quit notifications instead of
/// asking macOS about every app on every switch (about 12 ms each time).
enum RunningApps {
    private static var cached: Set<pid_t>?
    private static var observing = false

    /// Forget the cached list; the next read asks macOS again. Apps can turn into regular apps
    /// after launch (menu bar apps that open a window), which no notification announces.
    static func invalidate() { cached = nil }

    static var regular: Set<pid_t> {
        if !observing {
            observing = true
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                center.addObserver(forName: name, object: nil, queue: .main) { _ in cached = nil }
            }
        }
        if let cached { return cached }
        let me = getpid()
        let set = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != me }
            .map(\.processIdentifier))
        cached = set
        return set
    }
}

enum Windows {
    /// Apps that stopped answering Accessibility, and until when to leave them alone. One hung
    /// app costs a full timeout per call; skipping it keeps every switch quick.
    private static var unresponsiveUntil: [pid_t: Date] = [:]
    /// How many times in a row each app failed to answer. Each strike waits longer before
    /// asking again (5 s, 30 s, 2 min, 10 min), so a frozen app costs a timeout rarely.
    private static var strikes: [pid_t: Int] = [:]
    private static let unresponsiveLock = NSLock()

    static func isResponsive(_ pid: pid_t) -> Bool {
        unresponsiveLock.lock(); defer { unresponsiveLock.unlock() }
        guard let until = unresponsiveUntil[pid] else { return true }
        if until < Date() { unresponsiveUntil[pid] = nil; return true }
        return false
    }

    static func markUnresponsive(_ pid: pid_t) {
        unresponsiveLock.lock(); defer { unresponsiveLock.unlock() }
        let backoff: [TimeInterval] = [5, 30, 120, 600]
        let n = strikes[pid, default: 0]
        strikes[pid] = n + 1
        unresponsiveUntil[pid] = Date().addingTimeInterval(backoff[min(n, backoff.count - 1)])
    }

    /// The app answered, or the person brought it forward: give it a clean slate.
    static func markResponsive(_ pid: pid_t) {
        unresponsiveLock.lock(); defer { unresponsiveLock.unlock() }
        unresponsiveUntil[pid] = nil
        strikes[pid] = nil
    }

    /// Every standard window of every regular app except BaneySpaces itself. Dialogs, panels,
    /// popovers and windows on other macOS desktops are left alone. Apps are asked in parallel:
    /// Accessibility answers each app separately, so a slow app no longer delays the rest.
    /// `unsure` lists the apps that were skipped or didn't answer in time; their windows may be
    /// missing from the result.
    static func all(owners: Set<pid_t>? = nil) -> (windows: [Window], unsure: Set<pid_t>) {
        // Only apps that own a window are asked. A running app with no windows is often frozen by
        // macOS and never answers, which would cost a full timeout on every scan.
        let candidates = owners.map { RunningApps.regular.intersection($0) } ?? RunningApps.regular
        var unsure = Set(candidates.filter { !isResponsive($0) })
        let apps = candidates.compactMap { pid -> (pid_t, String)? in
            guard isResponsive(pid), let app = NSRunningApplication(processIdentifier: pid) else { return nil }
            return (pid, app.localizedName ?? "App")
        }
        var results = [[Window]](repeating: [], count: apps.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            let (pid, name) = apps[i]
            let ax = AXUIElementCreateApplication(pid)
            // A hung app must not hang every workspace switch.
            AXUIElementSetMessagingTimeout(ax, 0.25)
            let listed: [AXUIElement]? = ax.value(kAXWindowsAttribute)
            if listed == nil { lock.lock(); unsure.insert(pid); lock.unlock() } else { markResponsive(pid) }
            let elements = listed ?? []
            let found = elements.compactMap { el -> Window? in
                guard let id = el.windowID, el.string(kAXSubroleAttribute) == kAXStandardWindowSubrole as String else { return nil }
                return Window(id: id, element: el, pid: pid, appName: name)
            }
            lock.lock(); results[i] = found; lock.unlock()
        }
        return (results.flatMap { $0 }, unsure)
    }

    static func alive() -> Set<WindowID> { snapshot(apps: RunningApps.regular).alive }

    /// Every window number, plus the ordinary app windows (layer 0) among them. When the layer-0
    /// set hasn't changed since the last look, no window was opened or closed, and the full
    /// Accessibility scan can be skipped.
    static func snapshot(apps: Set<pid_t>) -> (alive: Set<WindowID>, appWindows: Set<WindowID>, owners: Set<pid_t>) {
        let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        var alive = Set<WindowID>(), appWindows = Set<WindowID>(), owners = Set<pid_t>()
        for w in info {
            guard let id = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            alive.insert(id)
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, apps.contains(pid) else { continue }
            appWindows.insert(id)
            owners.insert(pid)
        }
        return (alive, appWindows, owners)
    }

    /// The window that has keyboard focus, if it is one we manage.
    static func focused(in windows: [Window]) -> Window? {
        guard let pid = focusedPid() else { return nil }
        return focused(of: pid, in: windows)
    }

    /// The app that receives keystrokes. Accessibility's system-wide answer often fails or goes
    /// stale, so it is only the fallback.
    static func focusedPid() -> pid_t? {
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier { return pid }
        guard let app: AXUIElement = AXUIElementCreateSystemWide().value(kAXFocusedApplicationAttribute) else { return nil }
        var pid: pid_t = 0
        return AXUIElementGetPid(app, &pid) == .success && pid > 0 ? pid : nil
    }

    /// Brings an app to the front through Accessibility, which works even when macOS would
    /// refuse a plain activation request from a background app.
    static func makeFrontmost(_ pid: pid_t) {
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    static func focused(of pid: pid_t, in windows: [Window]) -> Window? {
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, 0.25)
        guard let el: AXUIElement = ax.value(kAXFocusedWindowAttribute), let id = el.windowID else { return nil }
        return windows.first { $0.id == id }
    }

    /// Screen frames in Accessibility coordinates.
    static func screens() -> [CGRect] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.map { Geometry.toAX($0.frame, primaryHeight: primaryHeight) }
    }

    /// The usable area (no menu bar, no Dock) of the screen a frame is mostly on.
    static func visibleArea(near frame: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let areas = NSScreen.screens.map { (Geometry.toAX($0.frame, primaryHeight: primaryHeight),
                                            Geometry.toAX($0.visibleFrame, primaryHeight: primaryHeight)) }
        let best = areas.max { a, b in
            let ia = a.0.intersection(frame), ib = b.0.intersection(frame)
            return ia.width * ia.height < ib.width * ib.height
        }
        return best?.1 ?? areas.first?.1 ?? frame
    }
}

extension AXUIElement {
    var windowID: WindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(self, &id) == .success && id != 0 ? id : nil
    }

    func value<T>(_ attribute: String) -> T? {
        var raw: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(self, attribute as CFString, &raw)
        guard result == .success else {
            // A timeout means the app is busy or hung: stop asking it for a few seconds.
            if result == .cannotComplete {
                var pid: pid_t = 0
                if AXUIElementGetPid(self, &pid) == .success, pid > 0 { Windows.markUnresponsive(pid) }
            }
            return nil
        }
        return raw as? T
    }

    func value<T>(_ attribute: String, _ type: AXValueType) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        return AXValueGetValue(raw as! AXValue, type, pointer) ? pointer.pointee : nil
    }

    func string(_ attribute: String) -> String? { value(attribute) }
    func bool(_ attribute: String) -> Bool { (value(attribute) as NSNumber?)?.boolValue ?? false }

    func set(_ attribute: String, _ value: CGPoint, _ type: AXValueType) {
        var v = value
        guard let ax = AXValueCreate(type, &v) else { return }
        AXUIElementSetAttributeValue(self, attribute as CFString, ax)
    }

    func set(_ attribute: String, _ value: CGSize, _ type: AXValueType) {
        var v = value
        guard let ax = AXValueCreate(type, &v) else { return }
        AXUIElementSetAttributeValue(self, attribute as CFString, ax)
    }
}
