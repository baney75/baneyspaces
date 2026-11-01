import CoreGraphics
import Foundation

/// The corners of the screens that used to open Mission Control, answered by BaneySpaces now.
/// Points and frames are AppKit's: bottom-left origin, y up.
public enum HotCorners {
    /// How close to the corner the pointer must be. The pointer stops at the edge of the screen,
    /// so only a pointer pushed into the corner gets this close.
    public static let reach: CGFloat = 4
    /// How long the pointer rests in the corner before it counts, as the Dock waits.
    public static let dwell: TimeInterval = 0.12

    public typealias Corner = MissionControlTakeover.Corner

    /// The corner the pointer is in, on whichever screen, or nil. A corner with another screen
    /// next to it isn't one: the pointer passes through it on its way over.
    public static func corner(at p: CGPoint, screens: [CGRect]) -> Corner? {
        for (i, s) in screens.enumerated() {
            let others = screens.enumerated().filter { $0.offset != i }.map(\.element)
            for c in Corner.allCases {
                let left = c == .topLeft || c == .bottomLeft, top = c == .topLeft || c == .topRight
                let x = left ? s.minX : s.maxX
                let y = top ? s.maxY : s.minY
                guard abs(p.x - x) <= reach, abs(p.y - y) <= reach else { continue }
                // Just inside the corner, then one point beyond it along each edge.
                let inX = left ? s.minX + 1 : s.maxX - 1, inY = top ? s.maxY - 1 : s.minY + 1
                let outX = left ? s.minX - 1 : s.maxX + 1, outY = top ? s.maxY + 1 : s.minY - 1
                let beside = CGPoint(x: outX, y: inY), above = CGPoint(x: inX, y: outY)
                if others.contains(where: { $0.contains(beside) || $0.contains(above) }) { continue }
                return c
            }
        }
        return nil
    }

    /// Whether the keys macOS wanted held for a corner are down. `required` and `held` are
    /// NSEvent modifier flags: ⇧ 1<<17, ⌃ 1<<18, ⌥ 1<<19, ⌘ 1<<20.
    public static func modifiersHeld(required: Int, held: Int) -> Bool {
        let mask = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20)
        let need = required & mask
        return held & need == need
    }
}

/// One hot-corner use at a time: a pointer rests in a corner, the overview opens once, and the
/// corner stays quiet until the pointer has left it.
public struct HotCornerDwell: Sendable {
    private var corner: HotCorners.Corner?
    private var since: TimeInterval = 0
    private var fired = false

    public init() {}

    /// The pointer is now in `corner` (nil for none) at `now`. Returns true when the pointer has
    /// rested long enough to open the overview.
    public mutating func update(_ corner: HotCorners.Corner?, now: TimeInterval) -> Bool {
        if corner != self.corner {
            self.corner = corner
            since = now
            fired = false
        }
        guard corner != nil, !fired, now - since >= HotCorners.dwell else { return false }
        fired = true
        return true
    }
}
