import AppKit
import ApplicationServices
import BaneySpacesCore

// Private but stable since macOS 10.x: the WindowServer number behind an Accessibility window.
// Every window manager on the Mac relies on it; there is no public way to match the two.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError
// Private but stable, as above: which macOS desktops a window is on, and the desktop each
// display is showing. yabai and AltTab rely on the same calls.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ windows: CFArray) -> Unmanaged<CFArray>?
@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray

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
        withoutAnimation { element.set(kAXPositionAttribute, p, .cgPoint) }
    }
    func setSize(_ s: CGSize) {
        guard Windows.isResponsive(pid) else { return }
        withoutAnimation { element.set(kAXSizeAttribute, s, .cgSize) }
    }
    /// Moves a window back to `r`. A parked window kept its size, so usually one move is all it
    /// takes; resizing makes apps lay out again, which is slow and can flicker.
    func place(_ r: CGRect, currentSize: CGSize) {
        if currentSize == r.size { setOrigin(r.origin) } else { setFrame(r) }
    }

    func setFrame(_ r: CGRect) {
        guard Windows.isResponsive(pid) else { return }
        // Size, move, size again: a window that would cross a screen edge gets clamped otherwise.
        withoutAnimation {
            element.set(kAXSizeAttribute, r.size, .cgSize)
            element.set(kAXPositionAttribute, r.origin, .cgPoint)
            element.set(kAXSizeAttribute, r.size, .cgSize)
        }
    }

    /// While an app has AXEnhancedUserInterface on, AppKit animates every move made through
    /// Accessibility: a parked window slid across the screen to the corner for a fifth of a
    /// second (Ghostty, measured: 20 positions; with it off, one). Chromium browsers turn it on,
    /// and assistive tools can turn it on for every app. It's off for the move and back on right
    /// after, which leaves the move instant and whoever wanted it on unaffected.
    private func withoutAnimation(_ move: () -> Void) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        let key = "AXEnhancedUserInterface" as CFString
        var raw: CFTypeRef?
        let on = AXUIElementCopyAttributeValue(app, key, &raw) == .success && (raw as? Bool) == true
        if on { AXUIElementSetAttributeValue(app, key, kCFBooleanFalse) }
        move()
        guard on, AXUIElementSetAttributeValue(app, key, kCFBooleanTrue) != .success else { return }
        // Busy laying out after a resize: try again in a moment, with longer to answer, so
        // whoever turned it on (VoiceOver, automation) doesn't lose it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            AXUIElementSetMessagingTimeout(app, 0.5)
            AXUIElementSetAttributeValue(app, key, kCFBooleanTrue)
        }
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

    /// Raises the window and brings its app forward; whether the raise took. An app busy coming
    /// back from hiding can stall each call, so the calls wait briefly and stop at the first
    /// timeout. Other errors (a window that can't be made main) don't stop the raise.
    @discardableResult
    func focus() -> Bool {
        defer { NSRunningApplication(processIdentifier: pid)?.activate() }
        AXUIElementSetMessagingTimeout(element, 0.1)
        defer { AXUIElementSetMessagingTimeout(element, 0) }
        let main = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        guard main != .cannotComplete else { element.checked(main); return false }
        let raise = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        guard raise != .cannotComplete else { element.checked(raise); return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        app.checked(AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue))
        return raise == .success
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
    /// missing from the result. `listed` is every window number the apps gave, of any kind, and
    /// `partial` the apps that gave an element whose number couldn't be read: only an app that
    /// answered in full can say a window it didn't list is closed.
    /// `notWindows` are listed elements whose subrole was read and isn't a standard window's
    /// (sheets, panels). One whose subrole couldn't be read is neither: it stays unplaced, so
    /// `UnplacedWindows` looks at it again.
    static func all(owners: Set<pid_t>? = nil) -> (windows: [Window], unsure: Set<pid_t>, listed: Set<WindowID>, partial: Set<pid_t>, notWindows: Set<WindowID>, companions: [Window]) {
        // Only apps that own a window are asked. A running app with no windows is often frozen by
        // macOS and never answers, which would cost a full timeout on every scan.
        let candidates = owners.map { RunningApps.regular.intersection($0) } ?? RunningApps.regular
        var unsure = Set(candidates.filter { !isResponsive($0) })
        let apps = candidates.compactMap { pid -> (pid_t, String)? in
            guard isResponsive(pid), let app = NSRunningApplication(processIdentifier: pid) else { return nil }
            return (pid, app.localizedName ?? "App")
        }
        var results = [[Window]](repeating: [], count: apps.count)
        var companionResults = [[Window]](repeating: [], count: apps.count)
        var listedIDs = Set<WindowID>(), partial = Set<pid_t>(), notWindows = Set<WindowID>()
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            let (pid, name) = apps[i]
            let ax = AXUIElementCreateApplication(pid)
            // A hung app must not hang every workspace switch.
            AXUIElementSetMessagingTimeout(ax, 0.25)
            let listed: [AXUIElement]? = ax.value(kAXWindowsAttribute)
            // Any failure, not just a timeout, counts: otherwise an app that answers with an error
            // would be retried at full speed forever instead of backing off.
            if listed == nil { lock.lock(); unsure.insert(pid); lock.unlock(); markUnresponsive(pid) } else { markResponsive(pid) }
            let elements = listed ?? []
            let ids = elements.map(\.windowID)
            var found: [Window] = [], other: [WindowID] = [], companions: [Window] = []
            // R-D1: a simulator, emulator or VM says what each of its windows is for. Every other app
            // takes the plain path below, exactly as before.
            let device = DeviceApps.facts(pid: pid)
            for (el, id) in zip(elements, ids) {
                guard let id, let subrole = el.string(kAXSubroleAttribute) else { continue }
                let standard = subrole == kAXStandardWindowSubrole as String
                guard let device else {
                    if standard { found.append(Window(id: id, element: el, pid: pid, appName: name)) } else { other.append(id) }
                    continue
                }
                var facts = device
                facts.title = el.string(kAXTitleAttribute) ?? ""
                facts.standard = standard
                switch DeviceTable.classify(facts).role {
                case .main: found.append(Window(id: id, element: el, pid: pid, appName: name))
                case .companion: companions.append(Window(id: id, element: el, pid: pid, appName: name))
                case .ignore: other.append(id)
                }
            }
            lock.lock()
            results[i] = found
            companionResults[i] = companions
            listedIDs.formUnion(ids.compactMap { $0 })
            notWindows.formUnion(other)
            if ids.contains(nil) { partial.insert(pid) }
            lock.unlock()
        }
        return (results.flatMap { $0 }, unsure, listedIDs, partial, notWindows, companionResults.flatMap { $0 })
    }

    static func alive() -> Set<WindowID> { snapshot(apps: RunningApps.regular).alive }

    /// Every window number, plus the ordinary app windows (layer 0) among them. When the layer-0
    /// set hasn't changed since the last look, no window was opened or closed, and the full
    /// Accessibility scan can be skipped.
    /// `offscreen` holds the app windows the window server isn't drawing (a hidden app's,
    /// minimized ones, ones on another macOS desktop, and ones the app closed but kept), by owner;
    /// `onScreen` the rest.
    static func snapshot(apps: Set<pid_t>) -> (alive: Set<WindowID>, appWindows: Set<WindowID>, owners: Set<pid_t>, offscreen: [WindowID: pid_t], onScreen: [WindowID: pid_t]) {
        let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        var alive = Set<WindowID>(), appWindows = Set<WindowID>(), owners = Set<pid_t>(), offscreen: [WindowID: pid_t] = [:], onScreen: [WindowID: pid_t] = [:]
        for w in info {
            guard let id = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            alive.insert(id)
            // A device app's tool windows (an emulator's toolbar floats at layer 3) count too: their
            // opening and closing must start a scan, or a toolbar would wait for the next one.
            let layer = w[kCGWindowLayer as String] as? Int ?? -1
            guard layer == 0 || (layer > 0 && layer <= 8 && (w[kCGWindowOwnerPID as String] as? NSNumber).map { DeviceApps.facts(pid: $0.int32Value) != nil } == true),
                  let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, apps.contains(pid) else { continue }
            appWindows.insert(id)
            owners.insert(pid)
            if (w[kCGWindowIsOnscreen as String] as? Bool) != true { offscreen[id] = pid } else { onScreen[id] = pid }
        }
        return (alive, appWindows, owners, offscreen, onScreen)
    }

    /// Whether a window is on no macOS desktop at all, or on one a display is showing. A window
    /// the app closed but kept (Ghostty keeps every one; so does Music), or a tab behind
    /// another tab, is one of these and off screen. A window on another desktop, or in full
    /// screen on its own, is neither: Accessibility just can't see it from here.
    static func onNoOtherDesktop(_ id: WindowID) -> Bool {
        let cid = CGSMainConnectionID()
        guard let raw = CGSCopySpacesForWindows(cid, 0x7, [id] as CFArray)?.takeRetainedValue() as? [NSNumber] else { return false }
        let spaces = Set(raw.map(\.intValue))
        if spaces.isEmpty { return true }
        guard let displays = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else { return false }
        let shown = Set(displays.compactMap { ($0["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int })
        return !shown.isEmpty && spaces.isSubset(of: shown)
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

    /// Whether the app still lists this window among its open ones. Some apps hide a window on
    /// ⌘W instead of closing it, so the window server alone can't tell.
    /// The app's standard windows that Accessibility lists, by number: what a new window looks
    /// like to BaneySpaces. The window server also lists every app's invisible helper windows
    /// (Ghostty has 14), which come and go on their own.
    static func standardIDs(of pid: pid_t) -> Set<WindowID> {
        guard isResponsive(pid) else { return [] }
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, 0.1)
        let listed: [AXUIElement] = ax.value(kAXWindowsAttribute) ?? []
        return Set(listed.compactMap { el in
            el.string(kAXSubroleAttribute) == kAXStandardWindowSubrole as String ? el.windowID : nil
        })
    }

    /// Every window number the app lists, of any kind; nil when it doesn't answer in full.
    static func listedIDs(of pid: pid_t) -> Set<WindowID>? {
        guard isResponsive(pid) else { return nil }
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, 0.25)
        guard let listed: [AXUIElement] = ax.value(kAXWindowsAttribute) else { return nil }
        let ids = listed.map(\.windowID)
        return ids.contains(nil) ? nil : Set(ids.compactMap { $0 })
    }

    static func lists(_ id: WindowID, pid: pid_t) -> Bool {
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, 0.25)
        let listed: [AXUIElement] = ax.value(kAXWindowsAttribute) ?? []
        return listed.contains { $0.windowID == id }
    }

    /// Each window's owner and frame from the window server, which answers even when the app
    /// doesn't. Frames are in Accessibility coordinates (top-left origin).
    static func serverWindows() -> [WindowID: (pid: pid_t, bounds: CGRect?)] {
        let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        var result: [WindowID: (pid: pid_t, bounds: CGRect?)] = [:]
        for w in info {
            guard let id = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { continue }
            let bounds = (w[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
            result[id] = (pid, bounds)
        }
        return result
    }

    /// Whether the window in front is in full screen, on its own macOS Space.
    static func frontIsFullScreen() -> Bool {
        guard let pid = focusedPid() else { return false }
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, 0.25)
        guard let el: AXUIElement = ax.value(kAXFocusedWindowAttribute) else { return false }
        return el.bool("AXFullScreen")
    }

    static func focused(of pid: pid_t, in windows: [Window]) -> Window? {
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, 0.25)
        guard let el: AXUIElement = ax.value(kAXFocusedWindowAttribute), let id = el.windowID else { return nil }
        return windows.first { $0.id == id }
    }

    /// The frames a full-screen window can have, in Accessibility coordinates: the whole screen,
    /// and on a display with a camera notch, the screen below it (where macOS puts full screen
    /// by default).
    static func fullScreenFrames() -> [CGRect] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.flatMap { screen -> [CGRect] in
            let f = Geometry.toAX(screen.frame, primaryHeight: primaryHeight)
            let top = screen.safeAreaInsets.top
            return top > 0 ? [f, CGRect(x: f.minX, y: f.minY + top, width: f.width, height: f.height - top)] : [f]
        }
    }

    /// Whether the windows in front of `id` hide every usable part of the screens within `path`
    /// (the box from where a window is to where it goes), so it can move there unseen. Windows
    /// in `moving`, and those of apps in `leaving` (being hidden), don't count: they're on their
    /// way out too.
    static func isCovered(_ id: WindowID, ignoring moving: Set<WindowID>, apps leaving: Set<pid_t>, path: CGRect) -> Bool {
        let above = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], id) as? [[String: Any]] ?? []
        let rects = above.compactMap { w -> CGRect? in
            guard (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ((w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) >= 1,
                  let n = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value, !moving.contains(n),
                  !leaving.contains((w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? -1) else { return nil }
            return (w[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        // A maximized window can stop a point or two short of the menu bar; motion there is invisible.
        return NSScreen.screens.allSatisfy { screen in
            let area = Geometry.toAX(screen.visibleFrame, primaryHeight: primaryHeight).insetBy(dx: 2, dy: 2).intersection(path)
            return area.isNull || Geometry.covers(rects, area: area)
        }
    }

    /// Apps with a window on screen now that a person can see (not one parked in the corner).
    static func pidsInSight(screens: [CGRect]) -> Set<pid_t> {
        let shown = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(shown.compactMap { w -> pid_t? in
            guard (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let b = (w[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  b.width > 50, b.height > 50, !Geometry.isStranded(b, screens: screens) else { return nil }
            return (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        })
    }

    /// Whether the window server shows none of these windows on screen (their app hid).
    static func allOffscreen(_ ids: Set<WindowID>) -> Bool {
        let shown = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return !shown.contains { ($0[kCGWindowNumber as String] as? NSNumber).map { ids.contains($0.uint32Value) } ?? false }
    }

    /// Every display, the main one first: its UUID, and its whole and usable (no menu bar, no
    /// Dock) areas in Accessibility coordinates.
    static func displays() -> [(key: DisplayKey, frame: CGRect, visible: CGRect)] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.compactMap { s in
            guard let key = key(of: s) else { return nil }
            return (key, Geometry.toAX(s.frame, primaryHeight: primaryHeight), Geometry.toAX(s.visibleFrame, primaryHeight: primaryHeight))
        }
    }

    /// A screen's display UUID.
    static func key(of s: NSScreen) -> DisplayKey? {
        guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// The screen for a display UUID from `displays()`.
    static func screen(for key: DisplayKey) -> NSScreen? {
        NSScreen.screens.first { Self.key(of: $0) == key }
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

    /// The app's own New Window command: a menu item named New … Window (New Window, New Finder
    /// Window, New Personal Window), preferring the one on plain ⌘N. Matched by name, not by ⌘N
    /// alone, which in Notes or Mail makes a note or a message instead, and which Ghostty gives
    /// up when its New Window key is changed. Works on a hidden app, which stays hidden.
    static func newWindowItem(_ pid: pid_t) -> AXUIElement? {
        guard isResponsive(pid) else { return nil }
        // Every element asked gets the short timeout: an app that hangs partway through its
        // menus must not hold the launcher.
        func children(_ e: AXUIElement) -> [AXUIElement] {
            AXUIElementSetMessagingTimeout(e, 0.25)
            return e.value(kAXChildrenAttribute) ?? []
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let bar: AXUIElement = app.value(kAXMenuBarAttribute) else { return nil }
        var named: AXUIElement?
        // A document app's plain "New" on ⌘N (TextEdit) opens an empty window, and counts only
        // when the app has no command with "window" in its name.
        var document: AXUIElement?
        // The Apple menu is first and never has it.
        for menu in children(bar).dropFirst() {
            for list in children(menu) {
                for item in children(list) {
                    if let title = item.string(kAXTitleAttribute), title == "New" || title == "New Document", document == nil,
                       item.bool(kAXEnabledAttribute), item.string("AXMenuItemCmdChar") == "N",
                       (item.value("AXMenuItemCmdModifiers") as NSNumber?)?.intValue == 0 {
                        document = item
                    }
                    guard let title = item.string(kAXTitleAttribute), title.hasPrefix("New"),
                          title.localizedCaseInsensitiveContains("window"), item.bool(kAXEnabledAttribute) else { continue }
                    if item.string("AXMenuItemCmdChar") == "N", (item.value("AXMenuItemCmdModifiers") as NSNumber?)?.intValue == 0 {
                        return item
                    }
                    if named == nil { named = item }
                }
            }
            guard isResponsive(pid) else { return nil }
        }
        return named ?? document
    }
}

extension AXUIElement {
    var windowID: WindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(self, &id) == .success && id != 0 ? id : nil
    }

    func value<T>(_ attribute: String) -> T? {
        var raw: CFTypeRef?
        guard checked(AXUIElementCopyAttributeValue(self, attribute as CFString, &raw)) else { return nil }
        return raw as? T
    }

    /// Whether a call succeeded. A timeout means the app is busy or hung: stop asking it for a
    /// few seconds, so one stuck app costs one timeout instead of one per call.
    @discardableResult
    func checked(_ result: AXError) -> Bool {
        if result == .cannotComplete {
            var pid: pid_t = 0
            if AXUIElementGetPid(self, &pid) == .success, pid > 0 { Windows.markUnresponsive(pid) }
        }
        return result == .success
    }

    func value<T>(_ attribute: String, _ type: AXValueType) -> T? {
        var raw: CFTypeRef?
        guard checked(AXUIElementCopyAttributeValue(self, attribute as CFString, &raw)),
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
        checked(AXUIElementSetAttributeValue(self, attribute as CFString, ax))
    }

    func set(_ attribute: String, _ value: CGSize, _ type: AXValueType) {
        var v = value
        guard let ax = AXValueCreate(type, &v) else { return }
        checked(AXUIElementSetAttributeValue(self, attribute as CFString, ax))
    }
}

/// Which running apps are simulators, emulators or VMs (spec/devices.md), asked once per process.
enum DeviceApps {
    private static let lock = NSLock()
    private static var known: [pid_t: (launched: Date?, facts: DeviceFacts?)] = [:]

    /// The facts about an app's process when it is a device app, nil for every other app.
    static func facts(pid: pid_t) -> DeviceFacts? {
        lock.lock(); defer { lock.unlock() }
        let app = NSRunningApplication(processIdentifier: pid)
        // A pid can be reused by another process: the launch time tells them apart.
        if let cached = known[pid], cached.launched == app?.launchDate { return cached.facts }
        let facts = DeviceFacts(bundle: app?.bundleIdentifier ?? "", process: app?.executableURL?.lastPathComponent ?? "")
        let result = DeviceTable.builtin.app(of: facts) == nil ? nil : facts
        known[pid] = (app?.launchDate, result)
        return result
    }

    static func forget(_ pid: pid_t) { lock.lock(); known[pid] = nil; lock.unlock() }

    /// Whether the app resizes its own windows (a rotated device, a guest's new resolution): R-D6.
    static func resizesItself(pid: pid_t) -> Bool {
        guard let f = facts(pid: pid) else { return false }
        return DeviceTable.builtin.app(of: f)?.resizesItself ?? false
    }
}
