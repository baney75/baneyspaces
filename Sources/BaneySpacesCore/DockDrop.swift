import CoreGraphics
import Foundation

/// Where a window or app dragged in the Workspace Dock lands: the workspace tile under the
/// pointer, or the empty-workspace button's workspace, but never the workspace it came from.
public enum DockDrop {
    /// `tiles[n]` is workspace `n`'s tile as drawn; `empty` is the empty-workspace button and the
    /// workspace it stands for. A little slack around each target forgives the gap between tiles.
    public static func target(at p: CGPoint, from: Int, tiles: [Int: CGRect], empty: (workspace: Int, frame: CGRect)? = nil, slack: CGFloat = 4) -> Int? {
        var targets = tiles.map { (workspace: $0.key, frame: $0.value) }
        if let empty { targets.append(empty) }
        let hit = targets.filter { $0.frame.insetBy(dx: -slack, dy: -slack).contains(p) }
        // Two targets within reach of the pointer: the closer one wins.
        let best = hit.min { distance(p, $0.frame) < distance(p, $1.frame) }
        guard let best, best.workspace != from, Workspaces.range.contains(best.workspace) else { return nil }
        return best.workspace
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        hypot(p.x - r.midX, p.y - r.midY)
    }

    /// The windows of a drag that are still on the workspace it began on. A window closed, an app
    /// quit, or a window moved elsewhere mid-drag is gone from `alive`, and is never moved.
    public static func survivors(of ids: [WindowID], alive: [WindowID]) -> [WindowID] {
        let live = Set(alive)
        return ids.filter { live.contains($0) }
    }

    /// Whether a drag in flight has lost what it carries and should end without moving anything:
    /// none of its windows are left where it began, or the row it was started from (`rowShown` is
    /// nil for a drag that began on a tile's icon, which outlives a refresh) went away, and with it
    /// the gesture, so its end would never come.
    /// Whether the "+N" row a drag began on is still on screen: the list shown must be the one of the
    /// tile the drag came from, and still list the app. Another tile's list taking its place (even
    /// one that lists the same app) is not the row the gesture is on.
    public static func rowStillShown(app: String, from tile: Int, list: (tile: Int, apps: [String])?) -> Bool {
        guard let list, list.tile == tile else { return false }
        return list.apps.contains(app)
    }

    public static func isOrphaned(ids: [WindowID], alive: [WindowID], rowShown: Bool?) -> Bool {
        survivors(of: ids, alive: alive).isEmpty || rowShown == false
    }

    /// How often a drag in flight re-reads the window list to see its windows are still there. The
    /// read scans, so it is spaced; the cheaper check against the last read runs every tick.
    public static let freshReadInterval: TimeInterval = 0.5

    public static func freshReadDue(now: TimeInterval, last: TimeInterval?) -> Bool {
        guard let last else { return true }
        return now - last >= freshReadInterval
    }
}

/// A drag the dock cancelled while the button was still down. SwiftUI's gesture lives on and keeps
/// reporting moves, which would start the same drag again at once and flicker until the button comes
/// up; the cancel holds for the rest of that press.
public struct DragCancel: Equatable, Sendable {
    private var ids: [WindowID]?

    public init() {}

    public mutating func cancelled(_ ids: [WindowID]) { self.ids = ids }

    /// A move from a gesture for `ids` starts nothing while that gesture's drag is the cancelled one.
    public func blocks(_ ids: [WindowID]) -> Bool { self.ids == ids }

    /// The press ended (button up, or the gesture's own end).
    public mutating func released() { ids = nil }
}
