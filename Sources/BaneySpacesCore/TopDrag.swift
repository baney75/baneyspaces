import CoreGraphics
import Foundation

/// A window dragged by its title bar up to the top edge of a screen, the gesture macOS answers
/// with Mission Control. BaneySpaces answers it with its own overview instead, where letting go
/// over a workspace sends the window there.
///
/// Fed from a mouse press on another app's window and then a tick every frame while the button
/// stays down. Every point and frame is in the window server's space: top-left origin, y down.
public struct TopDrag: Sendable {
    /// How close to the top of the screen the pointer must be. The menu bar stops the window
    /// itself, so only the pointer reaches the very edge.
    public static let band: CGFloat = 3
    /// How long the pointer rests there before the overview opens, so a drag that only passes
    /// the top on its way to another screen doesn't open it.
    public static let dwell: TimeInterval = 0.25

    /// The window under the press, and its frame before the drag moved it.
    public struct Grab: Equatable, Sendable {
        public let window: WindowID
        public let frame: CGRect
        public init(window: WindowID, frame: CGRect) {
            self.window = window
            self.frame = frame
        }
    }

    public private(set) var grab: Grab?
    /// The window has followed the pointer: its origin changed and its size didn't. A resize, a
    /// text selection or a click inside the window never sets it.
    public private(set) var moving = false
    /// The overview opened for this drag; nothing more happens until the button comes up.
    public private(set) var fired = false
    private var topSince: TimeInterval?

    public init() {}

    /// The button went down on `grab`'s window (nil: not on a window that can move).
    public mutating func press(_ grab: Grab?) {
        self = TopDrag()
        self.grab = grab
    }

    /// The button came up.
    public mutating func release() { self = TopDrag() }

    /// One tick with the button down: the pointer, the window's frame now (nil once it's gone),
    /// and every screen's frame. Returns the grab once, when the overview should open for it.
    public mutating func tick(cursor: CGPoint, frame: CGRect?, screens: [CGRect], now: TimeInterval) -> Grab? {
        guard let grab, !fired else { return nil }
        guard let frame else { self = TopDrag(); return nil }
        if !moving {
            let sameSize = abs(frame.width - grab.frame.width) < 1 && abs(frame.height - grab.frame.height) < 1
            let shifted = hypot(frame.minX - grab.frame.minX, frame.minY - grab.frame.minY) > 2
            moving = sameSize && shifted
        }
        guard moving, TopDrag.atTop(cursor, screens: screens) else { topSince = nil; return nil }
        let since = topSince ?? now
        topSince = since
        guard now - since >= TopDrag.dwell else { return nil }
        fired = true
        return grab
    }

    /// True when `p` is on a screen's top edge, and that edge doesn't lead onto a screen above.
    public static func atTop(_ p: CGPoint, screens: [CGRect]) -> Bool {
        guard let s = screens.first(where: { $0.contains(p) }), p.y < s.minY + band else { return false }
        let above = CGPoint(x: p.x, y: s.minY - 1)
        return !screens.contains { $0.contains(above) }
    }
}
