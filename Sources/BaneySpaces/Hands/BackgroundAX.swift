import ApplicationServices
import BaneySpacesCore
import CoreGraphics
import Foundation

/// What accessibility and the window server say about one process's windows right now: the facts the planner
/// decides on and the readings the delivery proof compares. Only reads. (`_AXUIElementGetWindow` is private; it is
/// looked up by name, and without it no window can be proven, so the route is refused.)
enum BackgroundAX {
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError
    private static let getWindow: GetWindow? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow")
        .map { unsafeBitCast($0, to: GetWindow.self) }

    static var canMapWindows: Bool { getWindow != nil }

    /// Short timeout: an app that does not answer must not hold the queue.
    private static func app(_ pid: pid_t) -> AXUIElement {
        let e = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(e, 0.5)
        return e
    }

    static func windowID(of e: AXUIElement) -> UInt32? {
        guard let getWindow else { return nil }
        var id: UInt32 = 0
        return getWindow(e, &id) == .success && id != 0 ? id : nil
    }

    private static func copy(_ e: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var out: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, attribute as CFString, &out) == .success ? out : nil
    }

    struct AppWindow {
        var element: AXUIElement
        var id: UInt32
        var minimized: Bool
    }

    /// The app's accessibility windows with their window-server ids. Empty when it says nothing.
    static func windows(pid: pid_t) -> [AppWindow] {
        guard let list = copy(app(pid), kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        return list.compactMap { w in
            guard let id = windowID(of: w) else { return nil }
            return AppWindow(element: w, id: id, minimized: (copy(w, kAXMinimizedAttribute) as? Bool) ?? false)
        }
    }

    /// Where the app's keys go: its focused window and the window its focused element is in.
    static func focus(pid: pid_t) -> (window: UInt32?, element: AXUIElement?, elementWindow: UInt32?) {
        let a = app(pid)
        let window = (copy(a, kAXFocusedWindowAttribute)).flatMap { windowID(of: $0 as! AXUIElement) }
        guard let raw = copy(a, kAXFocusedUIElementAttribute) else { return (window, nil, nil) }
        let el = raw as! AXUIElement
        return (window, el, windowID(of: el))
    }

    /// A reading of one element: what it is (role and frame), what it holds (hashed), what is selected.
    static func reading(of e: AXUIElement) -> ElementReading {
        let role = (copy(e, kAXRoleAttribute) as? String) ?? ""
        var frame = ""
        if let p = copy(e, kAXPositionAttribute), let s = copy(e, kAXSizeAttribute) {
            var pt = CGPoint.zero, sz = CGSize.zero
            AXValueGetValue(p as! AXValue, .cgPoint, &pt)
            AXValueGetValue(s as! AXValue, .cgSize, &sz)
            frame = "\(Int(pt.x)),\(Int(pt.y)),\(Int(sz.width)),\(Int(sz.height))"
        }
        var value: String?
        if let v = copy(e, kAXValueAttribute) { value = (v as? String) ?? "\(v)" }
        var selection: (Int, Int)?
        if let r = copy(e, kAXSelectedTextRangeAttribute) {
            var range = CFRange()
            if AXValueGetValue(r as! AXValue, .cfRange, &range) { selection = (range.location, range.length) }
        }
        return ElementReading.text(window: windowID(of: e), identity: "\(role)|\(frame)", value: value, selection: selection)
    }

    /// The window server's word on one window: its owner and its frame in screen coordinates. Windows parked
    /// out of view are listed too.
    static func serverWindow(_ id: UInt32) -> (pid: Int32, frame: CGRect)? {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list where (w[kCGWindowNumber as String] as? Int) == Int(id) {
            guard let pid = w[kCGWindowOwnerPID as String] as? Int, let b = w[kCGWindowBounds as String] as? [String: Any],
                  let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat, let width = b["Width"] as? CGFloat, let height = b["Height"] as? CGFloat else { return nil }
            return (Int32(pid), CGRect(x: x, y: y, width: width, height: height))
        }
        return nil
    }
}
