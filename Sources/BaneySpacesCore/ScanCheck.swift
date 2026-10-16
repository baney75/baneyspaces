import Foundation

/// When a refresh may skip the Accessibility scan. It skips when the window server's list of app
/// windows hasn't changed, which is right as long as the last scan saw them all. When
/// Accessibility answers with nothing for a while (10-14, 10-16), the scan drops every window,
/// the list stays the same, and every later refresh skipped: the dock showed the workspace you're
/// on as empty, with its windows in plain sight, until some window opened or closed.
public enum ScanCheck {
    /// The app windows on screen that no workspace holds. `onScreen` maps each window the server
    /// is drawing to its app; `notWindows` are the ones Accessibility listed but aren't standard
    /// windows (sheets, panels), which never get a workspace; `unsure` are apps the last scan
    /// couldn't read, which the retry timer handles.
    public static func unplaced(onScreen: [WindowID: Int32], placed: Set<WindowID>,
                                notWindows: Set<WindowID>, unsure: Set<Int32>) -> Set<WindowID> {
        Set(onScreen.filter { id, pid in !placed.contains(id) && !notWindows.contains(id) && !unsure.contains(pid) }.keys)
    }

    /// Scan again for unplaced windows, but at most once per `every` seconds: a window
    /// Accessibility never lists would otherwise cost a full scan on each switch.
    public static func shouldRescan(unplaced: Set<WindowID>, lastScan: Date, now: Date, every: TimeInterval = 3) -> Bool {
        !unplaced.isEmpty && now.timeIntervalSince(lastScan) >= every
    }
}
