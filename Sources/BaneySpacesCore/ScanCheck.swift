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

/// On-screen windows that a scan looked at and couldn't place, each with its own back-off. One
/// that had a workspace before (Accessibility dropped it) is looked at again within 12 s, so the
/// model heals soon after Accessibility comes back; one that never had a workspace (an overlay
/// Accessibility never lists) settles to a look a minute instead of one on every switch.
public struct UnplacedWindows: Equatable {
    /// Seconds to the next look after each miss, for a window that had a workspace; the last repeats.
    public static let backoff: [TimeInterval] = [3, 6, 12]
    /// The same for a window that never had one (r4 F3: an overlay cost a full scan every 12 s).
    public static let backoffUnknown: [TimeInterval] = [3, 6, 12, 30, 60]
    /// A window first found unplaced this recently is still a new window, not one that sat in
    /// plain sight while Accessibility was out: Ghostty's appear before Accessibility lists them.
    public static let newFor: TimeInterval = 5

    struct Entry: Equatable {
        var firstSeen: Date
        var misses: Int
        var next: Date
        var known: Bool
    }

    private var entries: [WindowID: Entry] = [:]

    public init() {}

    /// Records a scan. `unplaced` is what it left on screen with no workspace; everything else is
    /// forgotten. `known` are windows that had a workspace before. Only a window's due look counts
    /// as a miss: a scan that ran early for another reason (an app launching, a window opening)
    /// leaves its next look where it was, so a burst of scans during a short outage doesn't push it out.
    public mutating func scanned(unplaced: Set<WindowID>, known: Set<WindowID> = [], now: Date) {
        keep(unplaced)
        for id in unplaced {
            let isKnown = known.contains(id)
            guard var e = entries[id] else {
                entries[id] = Entry(firstSeen: now, misses: 0, next: now.addingTimeInterval(Self.backoff[0]), known: isKnown)
                continue
            }
            e.known = e.known || isKnown
            guard e.next <= now else { entries[id] = e; continue }
            e.misses += 1
            let steps = e.known ? Self.backoff : Self.backoffUnknown
            e.next = now.addingTimeInterval(steps[min(e.misses, steps.count - 1)])
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

    /// Whether a window a scan just placed should get new-window rules. One that had a workspace
    /// before (`known`) never does, however short the outage was or however long it was hidden:
    /// new-window rules could move it to another workspace and hide it (r4 F1, F2).
    public func isNew(_ id: WindowID, known: Set<WindowID> = [], now: Date) -> Bool {
        if known.contains(id) { return false }
        return entries[id].map { now.timeIntervalSince($0.firstSeen) < Self.newFor } ?? true
    }
}
