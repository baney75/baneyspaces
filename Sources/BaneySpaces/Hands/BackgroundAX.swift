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

    /// The app's accessibility windows with their window-server ids, and how many it lists that cannot be mapped to
    /// one (a panel being made, a window `_AXUIElementGetWindow` has no answer for). The unmapped count is kept so a
    /// caller can fail closed: a key could land in a window nobody can name.
    static func windows(pid: pid_t) -> (mapped: [AppWindow], unmapped: Int) {
        guard let list = copy(app(pid), kAXWindowsAttribute) as? [AXUIElement] else { return ([], 0) }
        var mapped: [AppWindow] = []
        var unmapped = 0
        for w in list {
            guard let id = windowID(of: w) else { unmapped += 1; continue }
            mapped.append(AppWindow(element: w, id: id, minimized: (copy(w, kAXMinimizedAttribute) as? Bool) ?? false))
        }
        return (mapped, unmapped)
    }

    /// The window's own state, for shortcuts that change the window and not an element (Save).
    static func windowReading(_ w: AXUIElement) -> WindowReading {
        let title = copy(w, kAXTitleAttribute) as? String
        let edited = copy(w, "AXEdited" as String) as? Bool
        let sheets = ((copy(w, kAXChildrenAttribute) as? [AXUIElement]) ?? []).filter { (copy($0, kAXRoleAttribute) as? String) == "AXSheet" }.count
        return WindowReading(titleDigest: title.map(ElementReading.digest), edited: edited, sheets: sheets)
    }

    /// How far down the window's title bar reaches, from its top edge, in points: the lowest of its close, minimize
    /// and zoom buttons plus a margin. 0 for a window without them.
    static func titleBarHeight(_ w: AXUIElement, windowTop: CGFloat) -> CGFloat {
        var bottom: CGFloat?
        for name in [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute] {
            guard let b = copy(w, name), let p = copy(b as! AXUIElement, kAXPositionAttribute), let sz = copy(b as! AXUIElement, kAXSizeAttribute) else { continue }
            var pt = CGPoint.zero, size = CGSize.zero
            AXValueGetValue(p as! AXValue, .cgPoint, &pt)
            AXValueGetValue(sz as! AXValue, .cgSize, &size)
            bottom = max(bottom ?? 0, pt.y + size.height)
        }
        guard let bottom else { return 0 }
        return max(0, bottom - windowTop) + 6
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
        return ElementReading.text(window: windowID(of: e), identity: "\(role)|\(frame)", value: value, selection: selection,
                                   attributes: value.flatMap { attributesDescription(e, length: $0.utf16.count) })
    }

    /// The text's attributes (fonts, underline...) run by run, as one string to hash. nil when the element does not answer.
    static func attributesDescription(_ e: AXUIElement, length: Int) -> String? {
        guard length > 0, length < 100_000 else { return nil }
        var range = CFRange(location: 0, length: length)
        guard let param = AXValueCreate(.cfRange, &range) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(e, kAXAttributedStringForRangeParameterizedAttribute as CFString, param, &out) == .success,
              let attributed = out as? NSAttributedString else { return nil }
        var parts: [String] = []
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length), options: []) { attrs, r, _ in
            let keys = attrs.keys.sorted { "\($0)" < "\($1)" }
            parts.append("\(r.location)+\(r.length):" + keys.map { "\($0)=\(attrs[$0]!)" }.joined(separator: ";"))
        }
        return parts.joined(separator: "|")
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
