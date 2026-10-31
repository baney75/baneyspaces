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
    /// Given the bar's length, pass `barSlack`: the stretch that brings the dock up must lie inside
    /// the zone that keeps it up (`keepZone(bar:)`), or resting there brings it up and drops it.
    public func withinSpan(_ p: CGPoint, screen: CGRect, visible: CGRect, length: CGFloat, slack: CGFloat = 24) -> Bool {
        isVertical ? abs(p.y - visible.midY) < length / 2 + slack : abs(p.x - screen.midX) < length / 2 + slack
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
    public func keepZone(dock: CGRect, screen: CGRect, slack: CGFloat = 24) -> CGRect {
        var r = dock
        switch self {
        case .bottom: r = CGRect(x: r.minX, y: screen.minY - 1, width: r.width, height: r.maxY - screen.minY + 1)
        case .top: r = CGRect(x: r.minX, y: r.minY, width: r.width, height: screen.maxY + 1 - r.minY)
        case .left: r = CGRect(x: screen.minX - 1, y: r.minY, width: r.maxX - screen.minX + 1, height: r.height)
        case .right: r = CGRect(x: r.minX, y: r.minY, width: screen.maxX + 1 - r.minX, height: r.height)
        }
        return r.insetBy(dx: -slack, dy: -slack)
    }

    /// Slack around the bar you see, past which the pointer has left the dock.
    public static let barSlack: CGFloat = 12

    /// The keep zone of a dock that's up. The panel is bigger than the bar you see: it keeps a
    /// row for the hover label on the screen side and is at least 480 pt long, so a zone taken from
    /// the panel held the dock up with the pointer 50 pt above the bar or 100 pt beside it, over
    /// the app underneath (Donovan, 2026-10-31). The zone hugs the bar, unless the window strip or
    /// the "+N" list is open: those are on the screen side and take clicks, so the whole panel
    /// counts then. `bar` is nil until the dock has laid itself out; the panel stands in.
    public func keepZone(bar: CGRect?, panel: CGRect, sideOpen: Bool, screen: CGRect) -> CGRect {
        guard let bar, !sideOpen else { return keepZone(dock: panel, screen: screen) }
        return keepZone(dock: bar, screen: screen, slack: DockEdge.barSlack)
    }

    /// How far the pointer moves before it counts as having moved since the dock came up.
    public static let unmovedSlop: CGFloat = 4

    /// The pointer is still where it brought the dock up. Such a dock stays up whatever its keep
    /// zone says: the edge that opened it was sized from the bar as last measured, and the bar
    /// may come up shorter (review of #91, first-F4).
    public static func unmoved(_ p: CGPoint, since shown: CGPoint) -> Bool {
        hypot(p.x - shown.x, p.y - shown.y) <= unmovedSlop
    }

    /// A frame the dock reports in its own space (top-left origin at `origin` inside a panel
    /// framed at `panel`), in AppKit screen coordinates. The inverse of `DockCarry.point`.
    public static func screenRect(_ r: CGRect, panel: CGRect, origin: CGPoint) -> CGRect {
        CGRect(x: panel.minX + origin.x + r.minX, y: panel.maxY - origin.y - r.maxY, width: r.width, height: r.height)
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

    /// How many of BaneySpaces' own windows at the menu level are on screen: its right-click
    /// menus and their submenus, open now. `excluding` names its windows at that level that aren't menus.
    public static func ownCount(_ list: [[String: Any]], level: Int, ownPID: Int32, excluding: Set<Int> = []) -> Int {
        list.filter { w in
            (w[kCGWindowLayer as String] as? Int) == level && (w[kCGWindowOwnerPID as String] as? Int32) == ownPID
                && !excluding.contains(w[kCGWindowNumber as String] as? Int ?? -1)
                && (w[kCGWindowIsOnscreen as String] as? Bool ?? true)
        }.count
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

/// Whether a right-click menu from the dock holds it up. AppKit's menu-tracking notifications set
/// a flag, and nothing cleared it if an end never came, so the dock could stay up for good with
/// the pointer far away (Donovan, 2026-10-29: "it keeps getting stuck"). The flag counts while
/// the window server shows one of BaneySpaces' own menus, and for a moment after it was set,
/// before the menu's window is listed.
public enum DockMenu {
    public static let grace: TimeInterval = 1

    /// `setAt` and `now` are seconds of uptime. `ownMenusOnScreen` is asked only once the grace is over.
    public static func holdsDock(flag: Bool, setAt: TimeInterval, now: TimeInterval, ownMenusOnScreen: () -> Int) -> Bool {
        guard flag else { return false }
        if now - setAt < grace { return true }
        return ownMenusOnScreen() > 0
    }
}

/// A dock that went down whose panel is still on screen once its slide-out is over: nothing else
/// would ever take it away, since the dock only hides what it thinks is up.
public enum DockStray {
    /// The slide-out takes 0.14 s; past this, a panel still up is a stray.
    public static let after: TimeInterval = 1

    /// `hiddenAt` and `now` are seconds of uptime; `hiddenAt` is nil if it was never shown.
    public static func isStray(shown: Bool, panelUp: Bool, hiddenAt: TimeInterval?, now: TimeInterval) -> Bool {
        guard !shown, panelUp else { return false }
        guard let hiddenAt else { return true }
        return now - hiddenAt > after
    }
}
