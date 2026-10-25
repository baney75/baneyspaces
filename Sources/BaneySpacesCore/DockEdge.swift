import CoreGraphics
import Foundation

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

    /// Where the pointer can be while the dock stays up: the dock itself, everything between it
    /// and its edge of the screen (for the top dock, the menu bar the pointer came down from),
    /// and a little slack all around.
    public func keepZone(dock: CGRect, screen: CGRect) -> CGRect {
        var r = dock
        switch self {
        case .bottom: r = CGRect(x: r.minX, y: screen.minY - 1, width: r.width, height: r.maxY - screen.minY + 1)
        case .top: r = CGRect(x: r.minX, y: r.minY, width: r.width, height: screen.maxY + 1 - r.minY)
        case .left: r = CGRect(x: screen.minX - 1, y: r.minY, width: r.maxX - screen.minX + 1, height: r.height)
        case .right: r = CGRect(x: r.minX, y: r.minY, width: screen.maxX + 1 - r.minX, height: r.height)
        }
        return r.insetBy(dx: -24, dy: -24)
    }

    /// Whether a menu open in another app is what the pointer is there for: one within reach of
    /// it, including a menu bar menu hanging just below a pointer resting on the top edge.
    /// `menus` are in the same coordinates as `pointer`, and only fresh ones (`MenuWindows`).
    public static func menuInTheWay(_ menus: [CGRect], pointer: CGPoint) -> Bool {
        menus.contains { $0.insetBy(dx: -48, dy: -48).contains(pointer) }
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

/// Other apps' windows at the pop-up menu level, and how long each has been on screen. Any one
/// anywhere used to keep the dock down, and macOS 27's MenuBarAgent left an empty one under the
/// menu bar for hours, so the dock never came up (2026-10-25). A real menu is opened by hand and
/// closed within moments; one seen on screen longer than `staleAfter` isn't counted.
public struct MenuWindows {
    public var staleAfter: TimeInterval = 30
    private var firstSeen: [Int: TimeInterval] = [:]
    private var sampled = false

    public init() {}

    /// Notes which menu windows are on screen at `now` (seconds of uptime, which never steps
    /// back); returns the frames of the fresh ones. Windows already up at the first sample count
    /// as old: at launch, one is far likelier stuck than a menu someone just opened.
    @discardableResult
    public mutating func update(_ windows: [(id: Int, frame: CGRect)], now: TimeInterval) -> [CGRect] {
        let ids = Set(windows.map(\.id))
        firstSeen = firstSeen.filter { ids.contains($0.key) }
        for w in windows where firstSeen[w.id] == nil { firstSeen[w.id] = sampled ? now : now - staleAfter }
        sampled = true
        return windows.filter { now - (firstSeen[$0.id] ?? now) < staleAfter }.map(\.frame)
    }

    /// The menu-level windows of other processes in a window server list, flipped from its
    /// top-left origin to AppKit's bottom-left one.
    public static func parse(_ list: [[String: Any]], level: Int, ownPID: Int32, primaryHeight: CGFloat) -> [(id: Int, frame: CGRect)] {
        list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == level, (w[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  let id = w[kCGWindowNumber as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) else { return nil }
            return (id, Geometry.toAX(r, primaryHeight: primaryHeight))
        }
    }
}
