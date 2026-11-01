import Foundation

/// The trackpad swipe that opens Mission Control: three or four fingers moving up. Swipe down
/// closes BaneySpaces' overview. Fed one frame of touches at a time; positions are the trackpad's
/// own, 0...1 from the left and from the bottom.
public struct FingerSwipe: Sendable {
    public enum Direction: Equatable, Sendable { case up, down }

    /// How far the fingers travel, as a share of the trackpad's height.
    public static let distance: Float = 0.12
    /// A swipe must be this much taller than wide, both in the trackpad's real shape.
    public static let steepness: Float = 1.5
    /// A trackpad is about this much wider than tall; sideways travel is scaled by it.
    public static let aspect: Float = 1.6

    public struct Touch: Equatable, Sendable {
        public var x: Float, y: Float
        public init(x: Float, y: Float) { self.x = x; self.y = y }
    }

    private enum Phase: Equatable {
        case waiting
        case tracking(count: Int, x: Float, y: Float)
        /// Fired, or not a swipe: nothing more until fewer fingers than a swipe needs are down.
        case spent
    }

    /// The finger counts macOS gives Mission Control (3 and/or 4).
    public var fingers: Set<Int>
    private var phase = Phase.waiting

    public init(fingers: Set<Int>) { self.fingers = fingers }

    /// The finger counts macOS sends to Mission Control, from the trackpad settings. A missing
    /// setting is macOS's default: four fingers on, three off. Three fingers dragging windows
    /// isn't a swipe.
    public static func fingerCounts(threeFingers: Int?, fourFingers: Int?, threeFingerDrag: Bool) -> Set<Int> {
        var set = Set<Int>()
        if (threeFingers ?? 0) == 2, !threeFingerDrag { set.insert(3) }
        if (fourFingers ?? 2) == 2 { set.insert(4) }
        return set
    }

    /// One frame of the fingers touching the pad. Returns a direction once, when the fingers have
    /// moved far enough.
    public mutating func frame(_ touches: [Touch]) -> Direction? {
        guard let fewest = fingers.min() else { return nil }
        let n = touches.count
        if n < fewest { phase = .waiting; return nil }
        let centre = (x: touches.map(\.x).reduce(0, +) / Float(n), y: touches.map(\.y).reduce(0, +) / Float(n))
        switch phase {
        case .spent:
            return nil
        case .waiting:
            phase = fingers.contains(n) ? .tracking(count: n, x: centre.x, y: centre.y) : .spent
            return nil
        case .tracking(let count, let x0, let y0):
            if n != count {
                // Fingers landing one at a time start over from where they are; any other count isn't a swipe.
                phase = fingers.contains(n) ? .tracking(count: n, x: centre.x, y: centre.y) : .spent
                return nil
            }
            let dy = centre.y - y0, dx = (centre.x - x0) * Self.aspect
            guard abs(dy) >= Self.distance, abs(dy) >= Self.steepness * abs(dx) else { return nil }
            phase = .spent
            return dy > 0 ? .up : .down
        }
    }

    /// The pad was let go of entirely or the device went away.
    public mutating func reset() { phase = .waiting }
}
