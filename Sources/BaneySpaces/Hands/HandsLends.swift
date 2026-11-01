import AppKit
import BaneySpacesCore

/// The apps lent to agents right now, shared between the hands (which lend and check) and
/// Spaces (which parks a lent app's windows instead of hiding them, and writes state.json).
final class HandsLends {
    static let shared = HandsLends()
    private let lock = NSLock()
    private var book = LendBook()
    /// Called after the list changes, on any thread: persist state.json, re-apply the workspace.
    var onChange: (() -> Void)?

    func current(now: Date = Date()) -> LendBook {
        lock.lock(); defer { lock.unlock() }
        book.expire(now: now)
        return book
    }

    func lend(app: String, bundle: String, session: String, for duration: TimeInterval) -> Lend? {
        lock.lock()
        book.lend(app: app, bundle: bundle, session: session, now: Date(), for: duration)
        let entry = book.entries.first { $0.app == app }
        lock.unlock()
        onChange?()
        return entry
    }

    @discardableResult
    func giveBack(_ name: String) -> Bool {
        lock.lock(); let was = book.giveBack(name); lock.unlock()
        if was { onChange?() }
        return was
    }

    /// Returns the apps lent to `session`, or every app when it is nil.
    @discardableResult
    func giveBackAll(session: String? = nil) -> [Lend] {
        lock.lock()
        let gone = session.map { book.endSession($0) } ?? book.giveBackAll()
        lock.unlock()
        if !gone.isEmpty { onChange?() }
        return gone
    }

    /// Timed-out lends go back; returns whether any did.
    @discardableResult
    func expire() -> Bool {
        lock.lock(); let gone = book.expire(now: Date()); lock.unlock()
        if !gone.isEmpty { onChange?() }
        return !gone.isEmpty
    }

    /// For state.json.
    func stateEntries() -> [[String: Any]] {
        current().entries.map {
            ["app": $0.app, "bundle": $0.bundle, "since": Int($0.since.timeIntervalSince1970),
             "until": Int($0.until.timeIntervalSince1970), "session": $0.session]
        }
    }

    func isLent(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return current().isLent(app: app.localizedName ?? "", bundle: app.bundleIdentifier ?? "", now: Date())
    }
}
