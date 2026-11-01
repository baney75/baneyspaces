import AppKit
import BaneySpacesCore

/// The apps lent to agents right now, shared between the hands (which check scope against it) and
/// Spaces (which parks a lent app's windows instead of hiding them, and writes state.json). Only
/// Donovan lends: the menu, the Deck, or `baneyspaces agent lend` from a terminal he types in.
final class HandsLends {
    static let shared = HandsLends()
    private let lock = NSLock()
    private var book = LendBook()
    /// Called after the list changes, on any thread, with the lock released: persist state.json,
    /// re-apply the workspace. Each change is announced once.
    var onChange: (() -> Void)?

    /// A copy of the book. Reading never changes it; timed-out entries are removed only by `expire()`
    /// (and every check ignores an entry past its time anyway).
    func current() -> LendBook {
        lock.lock(); defer { lock.unlock() }
        return book
    }

    @discardableResult
    func lend(app: String, bundle: String, pid: Int32, windows: [UInt32], session: String, for duration: TimeInterval) -> Lend? {
        lock.lock()
        book.lend(app: app, bundle: bundle, pid: pid, windows: windows, session: session, now: Date(), for: duration)
        let entry = book.entries.first { $0.pid == pid }
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

    /// Returns what was lent to `session`, or everything when it is nil.
    @discardableResult
    func giveBackAll(session: String? = nil) -> [Lend] {
        lock.lock()
        let gone = session.map { book.endSession($0) } ?? book.giveBackAll()
        lock.unlock()
        if !gone.isEmpty { onChange?() }
        return gone
    }

    /// Removes what has timed out. Whichever caller removes an entry announces it; the other finds nothing.
    @discardableResult
    func expire() -> Bool {
        lock.lock(); let gone = book.expire(now: Date()); lock.unlock()
        if !gone.isEmpty { onChange?() }
        return !gone.isEmpty
    }

    /// For state.json.
    func stateEntries() -> [[String: Any]] {
        current().active(now: Date()).map {
            ["app": $0.app, "bundle": $0.bundle, "pid": Int($0.pid), "windows": $0.windows.map(Int.init),
             "since": Int($0.since.timeIntervalSince1970), "until": Int($0.until.timeIntervalSince1970), "session": $0.session]
        }
    }

    func isLent(pid: pid_t) -> Bool { current().active(now: Date()).contains { $0.pid == pid } }
    var hasAny: Bool { !current().active(now: Date()).isEmpty }
}

/// When Donovan last used each app, for `in_use`.
final class UserActivity {
    static let shared = UserActivity()
    private let lock = NSLock()
    private var use = UserUse()

    func activated(_ pid: pid_t) {
        lock.lock(); use.activated(pid, now: Date()); lock.unlock()
    }

    /// In front now, or in front within the last 30 s.
    func inUse(_ pid: pid_t) -> Bool {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        lock.lock(); defer { lock.unlock() }
        return use.inUse(pid, frontNow: front, now: Date())
    }
}
