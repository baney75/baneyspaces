import AppKit
import ApplicationServices

/// Hears about window changes in the wrapped apps the moment they happen, through Accessibility
/// notifications, so nothing has to poll: a window opening, closing, retitling (Claude's spinner
/// and ✳ live in the title), moving, or taking focus.
final class Watcher {
    enum Change { case windows, title, focus, frame }

    /// Called on the main thread with the app's pid and what changed.
    var onChange: (pid_t, Change) -> Void = { _, _ in }

    private var observers: [pid_t: AXObserver] = [:]
    private var watchedWindows: [pid_t: [AXUIElement]] = [:]

    private static let appNotes = [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
                                   kAXMainWindowChangedNotification, kAXApplicationActivatedNotification]
    private static let windowNotes = [kAXTitleChangedNotification, kAXUIElementDestroyedNotification,
                                      kAXWindowMovedNotification, kAXWindowResizedNotification,
                                      kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification]

    var watching: Set<pid_t> { Set(observers.keys) }

    func watch(_ pid: pid_t) {
        guard observers[pid] == nil, AX.isTrusted else { return }
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, element, note, refcon in
            guard let refcon else { return }
            let me = Unmanaged<Watcher>.fromOpaque(refcon).takeUnretainedValue()
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            me.received(pid: pid, note: note as String, element: element)
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }
        observers[pid] = obs
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let app = AX.app(pid)
        for n in Self.appNotes { AXObserverAddNotification(obs, app, n as CFString, refcon) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        rewatchWindows(pid)
    }

    func unwatch(_ pid: pid_t) {
        guard let obs = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        watchedWindows[pid] = nil
    }

    /// Per-window notifications have to be added to each window; done again whenever windows come and go.
    func rewatchWindows(_ pid: pid_t) {
        guard let obs = observers[pid] else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let current: [AXUIElement] = AX.app(pid).value(kAXWindowsAttribute) ?? []
        let old = watchedWindows[pid] ?? []
        for w in current where !old.contains(where: { CFEqual($0, w) }) {
            for n in Self.windowNotes { AXObserverAddNotification(obs, w, n as CFString, refcon) }
        }
        watchedWindows[pid] = current
    }

    private func received(pid: pid_t, note: String, element: AXUIElement) {
        let change: Change
        switch note {
        case kAXWindowCreatedNotification, kAXUIElementDestroyedNotification,
             kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification:
            rewatchWindows(pid)
            change = .windows
        case kAXTitleChangedNotification: change = .title
        case kAXWindowMovedNotification, kAXWindowResizedNotification: change = .frame
        default: change = .focus
        }
        onChange(pid, change)
    }
}
