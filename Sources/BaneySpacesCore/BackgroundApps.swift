import Foundation

/// Apps that are running with nothing to see: no window on any workspace, or only minimized ones.
/// The Workspace Dock's "Background" tile lists them, so an app that opened itself in the
/// background (an updater, a helper that turned regular) can be seen and brought forward.
///
/// Pure over value types so the rule is tested without AppKit. An app BaneySpaces hid because its
/// windows live on another workspace has a tracked window that is not minimized, so it is not here:
/// it already shows on that workspace's tile.
public enum BackgroundApps {
    /// Finder always runs, usually with no window; listing it would be noise.
    public static let finderBundleID = "com.apple.finder"
    /// A just-launched app has no window yet; it isn't listed until it has had this long to open one,
    /// or every launch would flash the tile up and away.
    public static let launchGrace: TimeInterval = 3

    /// One running app, as `NSRunningApplication` reports it.
    public struct Running: Equatable {
        public let pid: Int32
        public let name: String
        public let bundleID: String?
        /// `activationPolicy == .regular`; menu-bar (accessory) and background-only apps are not.
        public let isRegular: Bool
        public let isTerminated: Bool
        public let isHidden: Bool
        /// When it launched, if macOS knows (`NSRunningApplication.launchDate`).
        public let launchedAt: Date?
        /// It shows a window BaneySpaces doesn't track: a dialog or alert on screen, or a full-screen
        /// window on its own macOS desktop. There is something to see, so it isn't listed.
        public let hasUntrackedWindow: Bool

        public init(pid: Int32, name: String, bundleID: String? = nil, isRegular: Bool = true,
                    isTerminated: Bool = false, isHidden: Bool = false, launchedAt: Date? = nil,
                    hasUntrackedWindow: Bool = false) {
            self.pid = pid
            self.name = name
            self.bundleID = bundleID
            self.isRegular = isRegular
            self.isTerminated = isTerminated
            self.isHidden = isHidden
            self.launchedAt = launchedAt
            self.hasUntrackedWindow = hasUntrackedWindow
        }
    }

    /// A window BaneySpaces tracks on some workspace (the agent workspace included).
    public struct TrackedWindow: Equatable {
        public let pid: Int32
        public let isMinimized: Bool

        public init(pid: Int32, isMinimized: Bool) {
            self.pid = pid
            self.isMinimized = isMinimized
        }
    }

    /// Why the app is listed, and so what bringing it forward does.
    public enum State: String, Equatable {
        /// Hidden (⌘H) with no window to show.
        case hidden
        /// Every window it has is minimized.
        case minimized
        /// Running with no window at all.
        case noWindow

        /// The short word on the dock's row.
        public var label: String {
            switch self {
            case .hidden: "hidden"
            case .minimized: "minimized"
            case .noWindow: "no window"
            }
        }
    }

    public struct Entry: Equatable, Identifiable {
        public let pid: Int32
        public let name: String
        public let state: State
        public var id: Int32 { pid }

        public init(pid: Int32, name: String, state: State) {
            self.pid = pid
            self.name = name
            self.state = state
        }
    }

    /// The background apps, sorted by name. `selfPID` is BaneySpaces itself.
    ///
    /// An app with any tracked window that is not minimized is not listed, hidden or not. One whose
    /// tracked windows are all minimized is `.minimized` (unhiding it would show nothing, so the
    /// window is what a click restores). One with none is `.hidden` if the app is hidden, else `.noWindow`.
    /// An app launched less than `launchGrace` before `now`, or one with an untracked window, is not listed.
    public static func list(running: [Running], trackedWindows: [TrackedWindow], selfPID: Int32,
                            now: Date = Date()) -> [Entry] {
        var visible = Set<Int32>()
        var minimized = Set<Int32>()
        for w in trackedWindows {
            if w.isMinimized { minimized.insert(w.pid) } else { visible.insert(w.pid) }
        }
        var seen = Set<Int32>()
        var out: [Entry] = []
        for app in running {
            guard app.isRegular, !app.isTerminated, app.pid != selfPID, app.bundleID != finderBundleID,
                  !visible.contains(app.pid), !app.hasUntrackedWindow,
                  app.launchedAt.map({ now.timeIntervalSince($0) >= launchGrace }) ?? true,
                  seen.insert(app.pid).inserted else { continue }
            let state: State = minimized.contains(app.pid) ? .minimized : app.isHidden ? .hidden : .noWindow
            out.append(Entry(pid: app.pid, name: app.name, state: state))
        }
        return out.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.pid < $1.pid : order == .orderedAscending
        }
    }

    /// The list as shown while the pointer is on it: rows already there keep their places, so a row
    /// doesn't move under the pointer between aiming and clicking. Apps that left the background
    /// drop out; new ones go at the end. The sorted order comes back once the pointer leaves.
    public static func held(_ shown: [Entry], now fresh: [Entry]) -> [Entry] {
        let byPid = Dictionary(fresh.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let kept = shown.compactMap { byPid[$0.pid] }
        let keptPids = Set(kept.map(\.pid))
        return kept + fresh.filter { !keptPids.contains($0.pid) }
    }
}
