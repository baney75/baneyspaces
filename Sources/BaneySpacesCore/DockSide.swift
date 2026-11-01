import CoreGraphics
import QuartzCore
import Foundation

/// The window strip and the "+N" list of the Workspace Dock live in a panel of their own, a child
/// of the dock's, so opening or closing one never changes the dock panel's size or where its bar
/// sits (Donovan, 2026-10-31: the dock "visibly jumps" when the list opens, and once drew it
/// clipped mid-update). Rectangles are in AppKit's screen coordinates, y growing upward.
public enum DockSide {
    /// Space between the bar and the list.
    public static let gap: CGFloat = 6

    /// Where a side panel of `size` goes: on the screen side of the bar, centered on `anchor` (the
    /// tile or icon it belongs to) along the edge, never reaching past either end of the bar, and on
    /// the screen. A list wider than the bar centers on it.
    public static func frame(size: CGSize, anchor: CGRect, bar: CGRect, edge: DockEdge, screen: CGRect) -> CGRect {
        let along: (min: CGFloat, max: CGFloat, size: CGFloat, mid: CGFloat)
        if edge.isVertical {
            along = (bar.minY, bar.maxY, size.height, anchor.midY)
        } else {
            along = (bar.minX, bar.maxX, size.width, anchor.midX)
        }
        let lo = along.min + along.size / 2, hi = along.max - along.size / 2
        let center = lo > hi ? (along.min + along.max) / 2 : min(max(along.mid, lo), hi)
        var origin: CGPoint
        switch edge {
        case .bottom: origin = CGPoint(x: center - size.width / 2, y: bar.maxY + gap)
        case .top: origin = CGPoint(x: center - size.width / 2, y: bar.minY - gap - size.height)
        case .left: origin = CGPoint(x: bar.maxX + gap, y: center - size.height / 2)
        case .right: origin = CGPoint(x: bar.minX - gap - size.width, y: center - size.height / 2)
        }
        // On the screen: a long list can't run off its far end.
        origin.x = min(max(origin.x, screen.minX), max(screen.minX, screen.maxX - size.width))
        origin.y = min(max(origin.y, screen.minY), max(screen.minY, screen.maxY - size.height))
        return CGRect(origin: origin, size: size)
    }

    /// Slack around the list, and around the tile it belongs to, past which the pointer has left it.
    public static let slack: CGFloat = 12

    /// Whether the pointer is still with the list: on it, or on the tile that opened it, each with
    /// a little slack, so crossing the gap between them doesn't count as leaving.
    public static func pointerWithList(_ p: CGPoint, list: CGRect, anchor: CGRect?) -> Bool {
        list.insetBy(dx: -slack, dy: -slack).contains(p) || (anchor?.insetBy(dx: -slack, dy: -slack).contains(p) ?? false)
    }

    /// The point a list grows from and shrinks to, inside a panel of `size`: the middle of its anchor
    /// on the side that faces the bar. In the panel's own coordinates (origin bottom left).
    public static func growPoint(panel: CGRect, anchor: CGRect, edge: DockEdge) -> CGPoint {
        let x = min(max(anchor.midX - panel.minX, 0), panel.width)
        let y = min(max(anchor.midY - panel.minY, 0), panel.height)
        switch edge {
        case .bottom: return CGPoint(x: x, y: 0)
        case .top: return CGPoint(x: x, y: panel.height)
        case .left: return CGPoint(x: 0, y: y)
        case .right: return CGPoint(x: panel.width, y: y)
        }
    }
}

extension DockSide {
    /// Where `grow` (in the layer's own coordinates) lies from the layer's anchor point, which is
    /// where a layer transform is applied about: `anchorPoint` is in unit coordinates, (0.5, 0.5) at
    /// the center and (0, 0) for a layer AppKit made for a view.
    public static func growOffset(grow: CGPoint, anchorPoint: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: grow.x - anchorPoint.x * size.width, y: grow.y - anchorPoint.y * size.height)
    }

    /// The transform that scales a layer by `scale` about `point`, where `point` is measured from the
    /// layer's anchor (`growOffset`), so a list grows from the tile it belongs to and that point
    /// stays where it is.
    public static func growTransform(about point: CGPoint, scale: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: point.x, y: point.y)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -point.x, y: -point.y)
    }
}

/// How long the pointer may be off an open list before it closes (250 ms): long enough to cross
/// the gap or overshoot a row, short enough that a list never outstays a pointer that left it.
public struct DockSideGrace: Equatable, Sendable {
    public static let delay: TimeInterval = 0.25
    private var outsideSince: TimeInterval?

    public init() {}

    /// True once the pointer has been off the list for the grace. `now` is a steady clock.
    public mutating func step(now: TimeInterval, inside: Bool) -> Bool {
        guard !inside else { outsideSince = nil; return false }
        if outsideSince == nil { outsideSince = now }
        return now - outsideSince! >= Self.delay
    }

    public mutating func reset() { outsideSince = nil }
}

/// The dock's motion: how far and how long. Reduce Motion (System Settings > Accessibility >
/// Display) makes every one instant. Only a view's own appearing, scaling, fading or sliding
/// animates; nothing here moves a window or the bar's resting place.
public enum DockMotion {
    /// Each of these is the theme's (`ThemeCenter`, from themes.json); the BaneySpaces theme's are
    /// the lengths and distances the dock has always had.
    ///
    /// The dock slides this far toward its edge as it fades out, and in from it. A theme that
    /// scales nothing (Omarchy) only fades.
    public static var slide: CGFloat { ThemeCenter.spec.motion.slides ? 8 : 0 }
    public static var dockIn: TimeInterval { ThemeCenter.spec.motion.inMs / 1000 }
    public static var dockOut: TimeInterval { ThemeCenter.spec.motion.outMs / 1000 }
    public static var listIn: TimeInterval { ThemeCenter.spec.motion.listInMs / 1000 }
    public static var listOut: TimeInterval { ThemeCenter.spec.motion.listOutMs / 1000 }
    public static var rowHover: TimeInterval { ThemeCenter.spec.motion.rowMs / 1000 }
    public static var settle: TimeInterval { ThemeCenter.spec.motion.seconds(0.12, .row) }
    /// A list grows from this scale.
    public static var listScale: CGFloat { CGFloat(ThemeCenter.spec.motion.scaleFrom) }
    /// A tile or row picked up for a drag.
    public static var lift: CGFloat { CGFloat(ThemeCenter.spec.motion.lift) }

    /// Arrives quickly and settles: the curve for a dock or list coming in.
    public static let arrive = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)

    public static func duration(_ seconds: TimeInterval, reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : seconds
    }
}
