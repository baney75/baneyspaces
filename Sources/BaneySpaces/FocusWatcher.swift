import AppKit
import ApplicationServices

/// Tells BaneySpaces when an app moves focus between its own windows. App activation alone
/// misses this: close a window with ⌘W and the app focuses its next window, which may sit on
/// another workspace, without any app switch. One Accessibility observer per running app.
final class FocusWatcher {
    private var observers: [pid_t: AXObserver] = [:]
    private let onChange: (pid_t) -> Void

    init(onChange: @escaping (pid_t) -> Void) {
        self.onChange = onChange
    }

    /// Watches exactly the apps in `pids`: new apps are added, quit apps dropped.
    func sync(_ pids: Set<pid_t>) {
        for pid in Set(observers.keys).subtracting(pids) { remove(pid) }
        for pid in pids.subtracting(observers.keys) { add(pid) }
    }

    func removeAll() { Array(observers.keys).forEach(remove) }

    private func add(_ pid: pid_t) {
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success else { return }
            Unmanaged<FocusWatcher>.fromOpaque(refcon).takeUnretainedValue().onChange(pid)
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let app = AXUIElementCreateApplication(pid)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(observer, app, kAXFocusedWindowChangedNotification as CFString, me) == .success else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private func remove(_ pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }
}
