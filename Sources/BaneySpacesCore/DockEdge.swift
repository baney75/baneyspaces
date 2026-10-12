import CoreGraphics

/// Which side of the screen the Workspace Dock lives on. Rectangles are in AppKit's screen
/// coordinates: the origin at the bottom left, y growing upward.
public enum DockEdge: String, CaseIterable, Sendable {
    case bottom, left, right, top

    public var isVertical: Bool { self == .left || self == .right }

    public var title: String {
        switch self {
        case .bottom: "Bottom"
        case .left: "Left"
        case .right: "Right"
        case .top: "Top"
        }
    }

    /// How long the pointer rests on the edge before the dock comes. The top edge is where the
    /// menu bar is, so it waits longer there: reaching for a menu shouldn't bring up the dock.
    public var dwell: Double { self == .top ? 0.5 : 0.12 }

    /// The screen whose edge the pointer is resting on, if any. An edge shared with another
    /// screen (the pointer would just cross onto it) doesn't count, as with the macOS Dock.
    public func screen(at p: CGPoint, among screens: [CGRect]) -> Int? {
        screens.firstIndex { s in
            let onEdge: Bool
            let beyond: CGPoint
            switch self {
            case .bottom:
                onEdge = p.x >= s.minX && p.x < s.maxX && p.y >= s.minY - 1 && p.y < s.minY + 2
                beyond = CGPoint(x: p.x, y: s.minY - 1)
            case .top:
                onEdge = p.x >= s.minX && p.x < s.maxX && p.y > s.maxY - 2 && p.y <= s.maxY + 1
                beyond = CGPoint(x: p.x, y: s.maxY + 1)
            case .left:
                onEdge = p.y >= s.minY && p.y < s.maxY && p.x >= s.minX - 1 && p.x < s.minX + 2
                beyond = CGPoint(x: s.minX - 1, y: p.y)
            case .right:
                onEdge = p.y >= s.minY && p.y < s.maxY && p.x > s.maxX - 2 && p.x <= s.maxX + 1
                beyond = CGPoint(x: s.maxX + 1, y: p.y)
            }
            return onEdge && !screens.contains { $0 != s && $0.contains(beyond) }
        }
    }

    /// Whether the pointer is along the stretch of edge the dock covers (with a little slack),
    /// so the corners and the rest of the edge stay free. `length` is the dock's length along it.
    public func withinSpan(_ p: CGPoint, screen: CGRect, visible: CGRect, length: CGFloat) -> Bool {
        isVertical ? abs(p.y - visible.midY) <= length / 2 + 24 : abs(p.x - screen.midX) <= length / 2 + 24
    }

    /// Where a dock of `size` sits: centered along its edge, 6 points in. The top dock sits under
    /// the menu bar, and side docks are centered in the space the menu bar leaves.
    public func frame(size: CGSize, screen: CGRect, visible: CGRect) -> CGRect {
        let inset: CGFloat = 6
        let origin: CGPoint
        switch self {
        case .bottom: origin = CGPoint(x: screen.midX - size.width / 2, y: screen.minY + inset)
        case .top: origin = CGPoint(x: screen.midX - size.width / 2, y: visible.maxY - size.height - inset)
        case .left: origin = CGPoint(x: screen.minX + inset, y: visible.midY - size.height / 2)
        case .right: origin = CGPoint(x: screen.maxX - size.width - inset, y: visible.midY - size.height / 2)
        }
        return CGRect(origin: origin, size: size)
    }

    /// The way it slides out of sight: toward its edge.
    public var away: CGVector {
        switch self {
        case .bottom: CGVector(dx: 0, dy: -18)
        case .top: CGVector(dx: 0, dy: 18)
        case .left: CGVector(dx: -18, dy: 0)
        case .right: CGVector(dx: 18, dy: 0)
        }
    }
}
