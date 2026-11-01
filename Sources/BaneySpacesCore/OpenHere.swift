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
        /// An app icon in a dock tile. It opens here only when the tile is the workspace you're on;
        /// another workspace's tile goes to that workspace's window, as it always did.
        case dockApp(tile: Int, current: Int)
    }

    /// The workspace an open from `entry` lands on, or nil when the entry isn't an open here.
    public static func target(_ entry: Entry) -> Int? {
        let n: Int
        switch entry {
        case .dockPlus(let w), .dockTileMenu(let w), .overviewSlot(let w), .overviewTile(let w), .launcher(shownOn: let w):
            n = w
        case .dockApp(tile: let tile, current: let current):
            guard tile == current else { return nil }
            n = tile
        }
        return Workspaces.range.contains(n) ? n : nil
    }

    /// What is known about the app when it's opened.
    public struct Situation: Equatable, Sendable {
        public var target: Int
        public var running: Bool
        /// The workspaces where the app has a window (minimized ones included); empty when it has none.
        public var windowsOn: [Int]
        /// Its New Window menu item exists and is enabled.
        public var canMakeWindow: Bool
        public init(target: Int, running: Bool, windowsOn: [Int] = [], canMakeWindow: Bool = false) {
            self.target = target
            self.running = running
            self.windowsOn = windowsOn
            self.canMakeWindow = canMakeWindow
        }
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
        return s.canMakeWindow ? .newWindow : .moveWindowHere
    }

    /// Whether the activation an open causes is followed to the app's other workspace. It never is
    /// for the actions that put a window on the target: the app comes forward about 54 ms before
    /// its new window exists (Ghostty, measured), and following that is the bug.
    public static func followsActivation(_ action: Action) -> Bool { action == .goThere }

    /// Whether the person is on the target afterward: every action that opens here.
    public static func staysOnTarget(_ action: Action) -> Bool { action != .goThere }
}
