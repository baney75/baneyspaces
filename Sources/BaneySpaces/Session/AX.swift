import AppKit
import ApplicationServices

/// Accessibility helpers for the session engine, added in Windows.swift.
extension AXUIElement {
    var frame: CGRect? {
        guard let p: CGPoint = value(kAXPositionAttribute, .cgPoint), let s: CGSize = value(kAXSizeAttribute, .cgSize) else { return nil }
        return CGRect(origin: p, size: s)
    }

    func set(origin: CGPoint) { set(kAXPositionAttribute, origin, .cgPoint) }
    func set(size: CGSize) { set(kAXSizeAttribute, size, .cgSize) }
    /// Size, move, size again: a window crossing a screen edge gets clamped otherwise.
    func set(frame f: CGRect) {
        set(size: f.size)
        set(origin: f.origin)
        set(size: f.size)
    }

    /// The macOS window number (CGWindowID), the ID BaneySpaces and `baneyspaces agent` use; 0 when unknown.
    var windowNumber: UInt32 { windowID ?? 0 }

    func raise() { AXUIElementPerformAction(self, kAXRaiseAction as CFString) }
}

enum AX {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's own "allow Accessibility" prompt. Donovan clicks it; nothing here changes it.
    static func askForTrust() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    static func app(_ pid: pid_t, timeout: Float = 0.25) -> AXUIElement {
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, timeout)
        return ax
    }

    /// Converts between AppKit screen space (y up) and Accessibility space (y down from the main screen's top).
    static func flip(_ r: CGRect) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: r.minX, y: top - r.maxY, width: r.width, height: r.height)
    }

    /// AppKit animates Accessibility moves while AXEnhancedUserInterface is on (BaneySpaces measured
    /// Ghostty sliding through 20 positions). Off for the move, then back as it was.
    static func withoutAnimation(_ app: AXUIElement, _ body: () -> Void) {
        let key = "AXEnhancedUserInterface" as CFString
        let on = app.bool("AXEnhancedUserInterface")
        if on { AXUIElementSetAttributeValue(app, key, kCFBooleanFalse) }
        body()
        if on { AXUIElementSetAttributeValue(app, key, kCFBooleanTrue) }
    }
}

/// One window as Accessibility sees it.
struct NativeWindow {
    let ax: AXUIElement
    let number: UInt32
    let title: String
    let frame: CGRect
    let minimized: Bool
    let fullScreen: Bool

    /// Mostly on a screen. Windows BaneySpaces parked off screen for another workspace aren't.
    var onScreen: Bool {
        guard !minimized, frame.width > 0, frame.height > 0 else { return false }
        let visible = NSScreen.screens.map { AX.flip($0.frame) }.reduce(CGFloat(0)) { sum, s in
            let i = s.intersection(frame)
            return sum + (i.isNull ? 0 : i.width * i.height)
        }
        return visible >= 0.5 * frame.width * frame.height
    }

    /// The app's standard windows, front to back. Panels, sheets and popovers are left out.
    static func list(pid: pid_t) -> [NativeWindow] {
        let app = AX.app(pid)
        let all: [AXUIElement] = app.value(kAXWindowsAttribute) ?? []
        return all.compactMap { w in
            guard w.string(kAXSubroleAttribute) == kAXStandardWindowSubrole as String else { return nil }
            return NativeWindow(ax: w, number: w.windowNumber, title: w.string(kAXTitleAttribute) ?? "",
                                frame: w.frame ?? .zero, minimized: w.bool(kAXMinimizedAttribute), fullScreen: w.bool("AXFullScreen"))
        }
    }
}
