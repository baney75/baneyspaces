import CoreGraphics

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
}
