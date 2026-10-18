import CoreGraphics
import Foundation

/// A drag that started in another app (a file from Finder, a link or image from a browser):
/// the system's drag pasteboard changes while the mouse button is down. A drag inside the dock,
/// or a window being moved by its title bar, never touches that pasteboard.
public struct OutsideDrag: Sendable {
    /// The pasteboard's change count when the button went down. A drag starts only once the
    /// pointer moves, so a count read on the first tick with the button down is from before it.
    private var baseline: Int?
    public private(set) var active = false

    public init() {}

    /// Call on every tick; true while such a drag is under way. The count is read only while a
    /// button is down.
    @discardableResult
    public mutating func update(buttonsDown: Bool, changeCount: () -> Int) -> Bool {
        guard buttonsDown else {
            baseline = nil
            active = false
            return false
        }
        let count = changeCount()
        if let baseline { if count != baseline { active = true } } else { baseline = count }
        return active
    }
}

/// What a drag from another app rests on in the dock.
public enum DockSpringTarget: Equatable, Sendable {
    /// An app's icon on a workspace's tile: its window there comes forward.
    case app(workspace: Int, id: String)
    /// A tile, between its icons: that workspace comes up.
    case tile(Int)

    public var workspace: Int {
        switch self {
        case .app(let n, _), .tile(let n): n
        }
    }

    /// The icon under the pointer, else its tile. `apps` are keyed "workspace:app id" and
    /// `tiles` "tile:workspace", as the dock reports its frames.
    public static func at(_ p: CGPoint, frames: [String: CGRect]) -> DockSpringTarget? {
        var tile: Int?
        for (key, frame) in frames where frame.contains(p) {
            if key.hasPrefix("tile:") {
                if let n = Int(key.dropFirst(5)) { tile = n }
                continue
            }
            let parts = key.split(separator: ":", maxSplits: 1)
            if parts.count == 2, let n = Int(parts[0]) { return .app(workspace: n, id: String(parts[1])) }
        }
        return tile.map { .tile($0) }
    }
}

/// Resting a drag on one target opens it once, after `delay`, the way the macOS Dock springs an
/// app open under a file held over its icon. Moving to another target starts the wait again.
public struct SpringLoad: Sendable {
    public static let delay: TimeInterval = 0.6
    private var target: DockSpringTarget?
    private var since = Date.distantPast
    private var fired = false

    public init() {}

    /// The target to open now, at most once per rest.
    public mutating func update(_ t: DockSpringTarget?, now: Date = Date()) -> DockSpringTarget? {
        if t != target {
            target = t
            since = now
            fired = false
            return nil
        }
        guard let t, !fired, now.timeIntervalSince(since) >= SpringLoad.delay else { return nil }
        fired = true
        return t
    }

    public mutating func reset() { self = SpringLoad() }
}
