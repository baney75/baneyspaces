import AppKit
import ApplicationServices

/// Tells BaneySpaces when an app moves focus between its own windows. App activation alone
/// misses this: close a window with ⌘W and the app focuses its next window, which may sit on
/// another workspace, without any app switch. One Accessibility observer per running app.
final class FocusWatcher {
    private var observers: [pid_t: AXObserver] = [:]
    /// Apps that should be watched but aren't yet (busy, or refused an observer), when to try
    /// again, and how many tries failed: each failure waits longer, so a frozen app is rarely asked.
    private var retryAfter: [pid_t: Date] = [:]
    private var failures: [pid_t: Int] = [:]
    private var wanted: Set<pid_t> = []

    /// Some app that should be watched isn't yet.
    var missing: Bool { !wanted.subtracting(observers.keys).isEmpty }
    private let onChange: (pid_t) -> Void

    init(onChange: @escaping (pid_t) -> Void) {
        self.onChange = onChange
    }

    /// Watches exactly the apps in `pids`: new apps are added, quit apps dropped.
    func sync(_ pids: Set<pid_t>) {
        wanted = pids
        for pid in Set(observers.keys).subtracting(pids) { remove(pid) }
        retryAfter = retryAfter.filter { pids.contains($0.key) }
        failures = failures.filter { pids.contains($0.key) }
        retry()
    }

    /// Tries again for every wanted app whose wait is over.
    func retry() {
        let now = Date()
        for pid in wanted.subtracting(observers.keys) where Windows.isResponsive(pid) && retryAfter[pid].map({ $0 < now }) ?? true {
            if add(pid) { failures[pid] = nil; retryAfter[pid] = nil; continue }
            let n = failures[pid, default: 0]
            failures[pid] = n + 1
            retryAfter[pid] = now.addingTimeInterval([5, 30, 120, 600][min(n, 3)])
        }
    }

    func removeAll() {
        Array(observers.keys).forEach(remove)
        wanted = []
    }

    @discardableResult
    private func add(_ pid: pid_t) -> Bool {
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success else { return }
            Unmanaged<FocusWatcher>.fromOpaque(refcon).takeUnretainedValue().onChange(pid)
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard app.checked(AXObserverAddNotification(observer, app, kAXFocusedWindowChangedNotification as CFString, me)) else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
        return true
    }

    private func remove(_ pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }
}
