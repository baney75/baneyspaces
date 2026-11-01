import Foundation

/// "Open here" (Donovan, 2026-11-01, a recording at 11:48): "if someone presses on a space and tries
/// to open it it should open there." He clicked the empty workspace 3 in the dock, opened the
/// launcher, picked Photos (already open on workspace 2), and was taken to workspace 2.
///
/// Anything opened from a workspace lands on that workspace. This is the whole decision, with no
/// AppKit, so every case is a test: which workspace is the target, and what the open does there.
public enum OpenHere {
    /// `behavior.launcher.open` (spec/config.md): `here` opens on the workspace you asked from;
    /// `go` goes to where the app already is, as the launcher did before.
    public enum Mode: String, CaseIterable, Sendable {
        case here, go
        public static let standard = Mode.here
        /// A stored or typed value; anything else is the default.
        public init(setting: String?) {
            self = setting.flatMap { Mode(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) } ?? .standard
        }
    }

    /// Where an open starts. Each carries the workspace it was asked from.
    public enum Entry: Equatable, Sendable {
        /// The "+" tile of an empty workspace in the dock.
        case dockPlus(Int)
        /// "Open an App Here" in a dock tile's context menu.
        case dockTileMenu(Int)
        /// The overview's empty slot, or a tile in it.
        case overviewSlot(Int)
        case overviewTile(Int)
        /// The launcher, opened by ⌘Space, ⌃⌘K, the dock's search button or a link, on the
        /// workspace the screen it appears on is showing.
        case launcher(shownOn: Int)
    }

    /// The workspace an open from `entry` lands on, or nil when the entry isn't an open here.
    public static func target(_ entry: Entry) -> Int? {
        let n: Int
        switch entry {
        case .dockPlus(let w), .dockTileMenu(let w), .overviewSlot(let w), .overviewTile(let w), .launcher(shownOn: let w):
            n = w
        }
        return Workspaces.range.contains(n) ? n : nil
    }

    /// What is known about an app's New Window command. A no is only ever *known*: an app that was busy,
    /// still building its menus, showing a sheet or slow to answer says nothing, and is `unknown`, which
    /// is tried (the menu is asked again at the moment of opening) rather than assumed to be a no.
    public enum WindowCommand: Equatable, Sendable {
        /// Its New Window item was found and is enabled.
        case yes
        /// A curated single-window app, or one whose menus were read in full on three separate days
        /// and never had a New Window item (`NewWindowEvidence`).
        case no
        case unknown
    }

    /// What is known about the app when it's opened.
    public struct Situation: Equatable, Sendable {
        public var target: Int
        public var running: Bool
        /// The workspaces where the user's copy of the app has a window (minimized ones included); empty
        /// when it has none. Never the agent workspace, never a window of a process started for an agent.
        public var windowsOn: [Int]
        public var windowCommand: WindowCommand
        public init(target: Int, running: Bool, windowsOn: [Int] = [], windowCommand: WindowCommand = .unknown) {
            self.target = target
            self.running = running
            self.windowsOn = windowsOn
            self.windowCommand = windowCommand
        }
    }

    /// The workspaces open here may count windows on: all but the agent workspace, which is not the user's.
    public static func userWorkspaces(_ workspaces: [Int], agentWorkspace: Int?) -> [Int] {
        workspaces.filter { $0 != agentWorkspace }
    }

    /// Processes open here may act on: the user's. One BaneySpaces started for an agent is invisible to it.
    public static func userProcesses<P: Hashable>(_ processes: [P], agent: Set<P>) -> [P] {
        processes.filter { !agent.contains($0) }
    }

    public enum Action: Equatable, Sendable {
        /// Not running: start it. Its first window is claimed for the target.
        case launch
        /// Running with a window on the target already: that window comes forward.
        case focusHere
        /// Running and able to make a window: the app's own New Window item, claimed for the target.
        case newWindow
        /// Running with no New Window item: its existing window moves to the target.
        case moveWindowHere
        /// Running with no window at all: asked to open one, claimed for the target.
        case reopen
        /// Go to wherever the app is (`go` mode, or ⌥).
        case goThere
    }

    /// `modifier`: ⌥ was held (⌥↩ in the launcher, ⌥-click in the dock and overview).
    public static func plan(_ s: Situation, mode: Mode, modifier: Bool) -> Action {
        guard s.running else { return .launch }
        if mode == .go || modifier { return .goThere }
        if s.windowsOn.isEmpty { return .reopen }
        if s.windowsOn.contains(s.target) { return .focusHere }
        // Only a known no moves the window. An unknown is tried as a new window first (the menu is asked at
        // the moment of opening); the move is what a failed try falls back to.
        return s.windowCommand == .no ? .moveWindowHere : .newWindow
    }

    /// Whether the activation an open causes is followed to the app's other workspace. It never is
    /// for the actions that put a window on the target: the app comes forward about 54 ms before
    /// its new window exists (Ghostty, measured), and following that is the bug.
    public static func followsActivation(_ action: Action) -> Bool { action == .goThere }

    /// What a click on a workspace's tile does. On an empty workspace (the dock's "+" tile, the
    /// overview's empty slot) it is what a "+" means: go there and open the launcher for it, so what
    /// you open lands there. On a workspace with windows it only goes there.
    public enum TileClick: Equatable, Sendable { case goTo, goToAndOpenLauncher }
    public static func tileClick(empty: Bool) -> TileClick { empty ? .goToAndOpenLauncher : .goTo }

    /// Whether the person is on the target afterward: every action that opens here.
    public static func staysOnTarget(_ action: Action) -> Bool { action != .goThere }
}

/// What is known, for sure, about apps that have no New Window command. The launcher never caches a no
/// from one menu read (the app may have been busy, or showing a sheet); a no counts only from a list of
/// apps known to be single-window, or from reads that came back whole and found no item on three
/// separate days. A yes, or any day it was found, clears the record.
public struct NewWindowEvidence: Equatable, Codable, Sendable {
    /// Bundle identifiers (macOS): the apps whose one window is the app (Donovan's list, 2026-11-01).
    public static let curated: Set<String> = [
        "com.apple.Photos", "com.apple.Music", "com.apple.AppStore", "com.apple.systempreferences",
        "com.apple.calculator", "com.apple.MobileSMS",
    ]
    public static let daysNeeded = 3

    /// App key (bundle id, else path) to the days (yyyy-MM-dd) a complete read found no New Window item.
    public private(set) var noDays: [String: [String]] = [:]

    public init() {}

    public mutating func sawNo(_ key: String, day: String) {
        var days = noDays[key] ?? []
        if !days.contains(day) { days.append(day) }
        noDays[key] = Array(days.suffix(Self.daysNeeded + 2))
    }

    public mutating func sawYes(_ key: String) { noDays[key] = nil }

    /// Whether to skip asking the app: it is curated, or three separate days said no.
    public func knownSingleWindow(_ key: String) -> Bool {
        Self.curated.contains(key) || (noDays[key]?.count ?? 0) >= Self.daysNeeded
    }
}

/// A launch the launcher asked for, registered before the app is asked to start. The app activates
/// before the request returns and before its first window exists; that activation must be held, not
/// followed to the app's other workspace. Whichever arrives first, the activation or the request's
/// completion, binds the launch to the process.
public struct PendingLaunch: Equatable, Sendable {
    public let bundle: String
    public let target: Int
    /// The processes of this app running when the request was made: none of them is the new one.
    public let before: Set<Int32>
    public let until: Date

    public init(bundle: String, target: Int, before: Set<Int32>, until: Date) {
        self.bundle = bundle
        self.target = target
        self.before = before
        self.until = until
    }

    public enum Arrival: Equatable, Sendable {
        /// This is the launched process: hold its activation and claim its first window for the target.
        /// `newProcess` is false for a process that was already running (its windows are the person's).
        case bind(pid: Int32, newProcess: Bool)
        case unrelated
        case expired
    }

    /// An activation or a completion for `bundle`, process `pid`, at `now`.
    public func arrival(bundle: String?, pid: Int32, now: Date, activation: Bool) -> Arrival {
        if now >= until { return .expired }
        guard bundle == self.bundle else { return .unrelated }
        // An activation of a process that was already running is the person's own; the request's
        // completion, though, may hand back the process that was already running (it answered the request).
        if activation, before.contains(pid) { return .unrelated }
        return .bind(pid: pid, newProcess: !before.contains(pid))
    }
}
