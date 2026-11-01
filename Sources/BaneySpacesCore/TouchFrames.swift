import Foundation

/// Reads the touches MultitouchSupport hands to a frame callback. The layout is private and
/// unpublished, so it is checked on the device before it is trusted: the first frames must read
/// as plausible touches, including a second touch (which proves the size of each one), or the
/// swipe is switched off and Settings says so.
///
/// Each touch is 96 bytes: the state at byte 20 (3 and 4 are touching), the finger's number at
/// byte 16 and its position (0...1 from the left and the bottom) at bytes 32 and 36.
public struct TouchFrameReader: Sendable {
    public enum Layout: Equatable, Sendable { case checking, trusted, rejected }

    public static let stride = 96
    /// Plausible frames needed before touches are used.
    public static let framesNeeded = 6
    /// Implausible frames in a row that withdraw trust.
    public static let oddLimit = 3

    public private(set) var layout = Layout.checking
    private var good = 0
    private var sawSecond = false
    private var odd = 0

    public init() {}

    private struct Raw { var state: Int32, id: Int32, x: Float, y: Float }

    private static func raw(_ data: UnsafeRawPointer, _ i: Int) -> Raw {
        let base = data + i * stride
        return Raw(state: base.load(fromByteOffset: 20, as: Int32.self), id: base.load(fromByteOffset: 16, as: Int32.self),
                   x: base.load(fromByteOffset: 32, as: Float.self), y: base.load(fromByteOffset: 36, as: Float.self))
    }

    private static func touching(_ r: Raw) -> Bool { r.state == 3 || r.state == 4 }

    private static func plausible(_ r: Raw) -> Bool {
        guard (0...7).contains(r.state), (0...255).contains(r.id) else { return false }
        return !touching(r) || (r.x.isFinite && r.y.isFinite && (-0.1...1.1).contains(r.x) && (-0.1...1.1).contains(r.y))
    }

    /// The fingers on the pad in this frame; empty when every finger is up (the frame then has no
    /// data), nil while the layout isn't trusted. `count` is the callback's own count.
    public mutating func touches(in data: UnsafeRawPointer?, count: Int) -> [FingerSwipe.Touch]? {
        if layout == .rejected { return nil }
        if count <= 0 { return [] }
        guard let data else { return nil }
        if layout == .checking {
            // Only the first two touches are read until the size is proven: a wrong size can't
            // take the reads far past the end of the frame.
            let first = Self.raw(data, 0)
            var ok = Self.plausible(first)
            if ok, count >= 2 {
                let second = Self.raw(data, 1)
                ok = Self.plausible(second) && second.id != first.id
                if ok { sawSecond = true }
            }
            guard ok else { layout = .rejected; return nil }
            good += 1
            if good >= Self.framesNeeded && sawSecond { layout = .trusted }
            return nil
        }
        var found: [FingerSwipe.Touch] = []
        var bad = false
        for i in 0..<count {
            let r = Self.raw(data, i)
            guard Self.touching(r) else { continue }
            if Self.plausible(r) { found.append(.init(x: r.x, y: r.y)) } else { bad = true }
        }
        odd = bad ? odd + 1 : 0
        if odd >= Self.oddLimit { layout = .rejected; return nil }
        return bad ? nil : found
    }
}
