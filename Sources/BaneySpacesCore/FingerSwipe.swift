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
    public static let defaultAspect: Float = 1.6
    /// Fingers moving together keep their spread. Show Desktop (thumb and fingers apart) and
    /// pinches change it: a spread that has grown or shrunk by this share isn't a swipe.
    public static let spreadChange: Float = 0.3
    /// ...and by at least this much of the pad's height, so fingers settling don't count.
    public static let spreadSlack: Float = 0.04

    public struct Touch: Equatable, Sendable {
        public var x: Float, y: Float
        public init(x: Float, y: Float) { self.x = x; self.y = y }
    }

    private enum Phase: Equatable {
        case waiting
        case tracking(count: Int, x: Float, y: Float, spread: Float)
        /// Fired, or not a swipe: nothing more until fewer fingers than a swipe needs are down.
        case spent
    }

    /// The finger counts macOS gives Mission Control (3 and/or 4).
    public var fingers: Set<Int>
    /// The pad's width over its height, from the device when known.
    public var aspect: Float
    private var phase = Phase.waiting

    public init(fingers: Set<Int>, aspect: Float = FingerSwipe.defaultAspect) {
        self.fingers = fingers
        self.aspect = aspect
    }

    /// The finger counts macOS sends to Mission Control, from the trackpad settings. A missing
    /// setting is macOS's default: four fingers on, three off. Three fingers dragging windows
    /// isn't a swipe.
    public static func fingerCounts(threeFingers: Int?, fourFingers: Int?, threeFingerDrag: Bool) -> Set<Int> {
        var set = Set<Int>()
        if (threeFingers ?? 0) == 2, !threeFingerDrag { set.insert(3) }
        if (fourFingers ?? 2) == 2 { set.insert(4) }
        return set
    }

    /// Mean distance of the fingers from their centre, in the pad's real shape.
    private func spread(_ touches: [Touch], _ cx: Float, _ cy: Float) -> Float {
        touches.map { (((($0.x - cx) * aspect) * (($0.x - cx) * aspect)) + (($0.y - cy) * ($0.y - cy))).squareRoot() }
            .reduce(0, +) / Float(touches.count)
    }

    /// One frame of the fingers touching the pad (empty once every finger is up). Returns a
    /// direction once, when the fingers have moved far enough.
    public mutating func frame(_ touches: [Touch]) -> Direction? {
        guard let fewest = fingers.min() else { return nil }
        let n = touches.count
        if n < fewest { phase = .waiting; return nil }
        let cx = touches.map(\.x).reduce(0, +) / Float(n), cy = touches.map(\.y).reduce(0, +) / Float(n)
        switch phase {
        case .spent:
            return nil
        case .waiting:
            phase = fingers.contains(n) ? .tracking(count: n, x: cx, y: cy, spread: spread(touches, cx, cy)) : .spent
            return nil
        case .tracking(let count, let x0, let y0, let s0):
            if n != count {
                // Fingers landing one at a time start over from where they are; any other count isn't a swipe.
                phase = fingers.contains(n) ? .tracking(count: n, x: cx, y: cy, spread: spread(touches, cx, cy)) : .spent
                return nil
            }
            if abs(spread(touches, cx, cy) - s0) > max(Self.spreadChange * s0, Self.spreadSlack) {
                phase = .spent
                return nil
            }
            let dy = cy - y0, dx = (cx - x0) * aspect
            guard abs(dy) >= Self.distance, abs(dy) >= Self.steepness * abs(dx) else { return nil }
            phase = .spent
            return dy > 0 ? .up : .down
        }
    }

    /// The device went away or came back from sleep.
    public mutating func reset() { phase = .waiting }
}

/// Which multitouch devices are trackpads, and which of macOS's settings are theirs.
public enum TrackpadDevice {
    /// A built-in trackpad, or an external surface that is wider than tall and big enough for
    /// three fingers (a Magic Trackpad). A Magic Mouse's surface is narrow and tall. Sizes are in
    /// hundredths of a millimetre, as MultitouchSupport reports them.
    public static func isTrackpad(builtIn: Bool, width: Int, height: Int) -> Bool {
        builtIn || (width >= 8000 && width > height)
    }

    /// The preferences domain holding a trackpad's gesture settings.
    public static func preferenceDomain(builtIn: Bool) -> String {
        builtIn ? "com.apple.AppleMultitouchTrackpad" : "com.apple.driver.AppleBluetoothMultitouch.trackpad"
    }
}
