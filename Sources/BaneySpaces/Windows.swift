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
        guard let p: CGPoint = element.value(kAXPositionAttribute, .cgPoint),
              let s: CGSize = element.value(kAXSizeAttribute, .cgSize) else { return nil }
        return CGRect(origin: p, size: s)
    }

    var isMinimized: Bool { element.bool(kAXMinimizedAttribute) }
    var isFullScreen: Bool { element.bool("AXFullScreen") }

    func setOrigin(_ p: CGPoint) { element.set(kAXPositionAttribute, p, .cgPoint) }
    func setSize(_ s: CGSize) { element.set(kAXSizeAttribute, s, .cgSize) }
    func setFrame(_ r: CGRect) {
        // Size, move, size again: a window that would cross a screen edge gets clamped otherwise.
        setSize(r.size)
        setOrigin(r.origin)
        setSize(r.size)
    }

    func exitFullScreen() {
        AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString, kCFBooleanFalse)
    }

    func focus() {
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: pid)?.activate()
    }
}

enum Windows {
    /// Every standard window of every regular app except BaneySpaces itself. Dialogs, panels,
    /// popovers and windows on other macOS desktops are left alone.
    static func all() -> [Window] {
        let me = ProcessInfo.processInfo.processIdentifier
        var out: [Window] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != me && !app.isTerminated {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            // A hung app must not hang every workspace switch.
            AXUIElementSetMessagingTimeout(ax, 0.25)
            let elements: [AXUIElement] = ax.value(kAXWindowsAttribute) ?? []
            for el in elements {
                guard let id = el.windowID,
                      el.string(kAXSubroleAttribute) == kAXStandardWindowSubrole as String else { continue }
                out.append(Window(id: id, element: el, pid: app.processIdentifier, appName: app.localizedName ?? "App"))
            }
        }
        return out
    }

    /// Every window the WindowServer has, on every macOS desktop. Accessibility can miss a window
    /// (a busy app, another desktop); this list can't, so it decides whether a window still exists.
    static func alive() -> Set<WindowID> {
        let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(info.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
    }

    /// The window that has keyboard focus, if it is one we manage.
    static func focused(in windows: [Window]) -> Window? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return focused(of: app.processIdentifier, in: windows)
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
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &raw) == .success else { return nil }
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
