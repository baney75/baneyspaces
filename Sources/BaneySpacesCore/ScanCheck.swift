import Foundation

/// When a refresh may skip the Accessibility scan. It skips when the window server's list of app
/// windows hasn't changed, which is right as long as the last scan saw them all. When
/// Accessibility answers with nothing for a while (10-14, 10-16), the scan drops every window,
/// the list stays the same, and every later refresh skipped: the dock showed the workspace you're
/// on as empty, with its windows in plain sight, until some window opened or closed.
public enum ScanCheck {
    /// The app windows on screen that no workspace holds. `onScreen` maps each window the server
    /// is drawing to its app; `notWindows` are the ones Accessibility listed and said aren't
    /// standard windows (sheets, panels), which never get a workspace; `unsure` are apps the last
    /// scan couldn't read at all, which the retry timer handles.
    public static func unplaced(onScreen: [WindowID: Int32], placed: Set<WindowID>,
                                notWindows: Set<WindowID>, unsure: Set<Int32>) -> Set<WindowID> {
        Set(onScreen.filter { id, pid in !placed.contains(id) && !notWindows.contains(id) && !unsure.contains(pid) }.keys)
    }
}

/// On-screen windows that a scan looked at and couldn't place, each with its own back-off, so
/// the model heals within 12 s of Accessibility coming back, while a window it never lists (an
/// overlay) costs one background scan every 12 s instead of one on every switch.
public struct UnplacedWindows: Equatable {
    /// Seconds to the next look after each miss; the last repeats.
    public static let backoff: [TimeInterval] = [3, 6, 12]
    /// A window first found unplaced this recently is still a new window, not one that sat in
    /// plain sight while Accessibility was out: Ghostty's appear before Accessibility lists them.
    public static let newFor: TimeInterval = 5

    struct Entry: Equatable {
        var firstSeen: Date
        var misses: Int
        var next: Date
    }

    private var entries: [WindowID: Entry] = [:]

    public init() {}

    /// Records a scan. `unplaced` is what it left on screen with no workspace; everything else is
    /// forgotten. Only a window's due look counts as a miss: a scan that ran early for another
    /// reason (an app launching, a window opening) leaves its next look where it was, so a burst
    /// of scans during a short outage doesn't push it out.
    public mutating func scanned(unplaced: Set<WindowID>, now: Date) {
        keep(unplaced)
        for id in unplaced {
            guard var e = entries[id] else {
                entries[id] = Entry(firstSeen: now, misses: 0, next: now.addingTimeInterval(Self.backoff[0]))
                continue
            }
            guard e.next <= now else { continue }
            e.misses += 1
            e.next = now.addingTimeInterval(Self.backoff[min(e.misses, Self.backoff.count - 1)])
            entries[id] = e
        }
    }

    /// Forgets windows that stopped counting without a scan (hidden, minimized, moved to another
    /// desktop), so the timer doesn't wait on a look nothing will take.
    public mutating func keep(_ unplaced: Set<WindowID>) {
        entries = entries.filter { unplaced.contains($0.key) }
    }

    /// Whether any of `unplaced` is due another scan: one no scan has looked at yet, or one whose
    /// wait is over.
    public func due(_ unplaced: Set<WindowID>, now: Date) -> Bool {
        unplaced.contains { id in entries[id].map { $0.next <= now } ?? true }
    }

    /// When the next one is due, for the background timer.
    public var nextDue: Date? { entries.values.map(\.next).min() }

    /// Whether a window a scan just placed should get new-window rules.
    public func isNew(_ id: WindowID, now: Date) -> Bool {
        entries[id].map { now.timeIntervalSince($0.firstSeen) < Self.newFor } ?? true
    }
}
