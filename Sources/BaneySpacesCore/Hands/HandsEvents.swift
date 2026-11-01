import CoreGraphics
import Foundation

/// What an agent action is about to do, announced once, before it is sent. Phase 1b's on-screen agent
/// cursor listens here to show where the hands are working; with no listener (the default) nothing
/// is measured, drawn or slowed down.
public struct HandsActionEvent: Equatable, Sendable {
    /// `click`, `type`, `set-value`, `press`, `scroll`, `select`, `toggle`.
    public var kind: String
    public var ref: String
    public var window: UInt32
    public var pid: Int32
    public var app: String
    /// The center of the target element in screen coordinates, when it could be read.
    public var point: CGPoint?
    public init(kind: String, ref: String, window: UInt32, pid: Int32, app: String, point: CGPoint?) {
        self.kind = kind; self.ref = ref; self.window = window; self.pid = pid; self.app = app; self.point = point
    }
}

public protocol HandsEventListener: AnyObject {
    /// Called on the hands' thread, before the action is dispatched. Must return quickly.
    func handsWillAct(_ event: HandsActionEvent)
}

/// The one place every action handler reports its target through.
public enum HandsEvents {
    private static let lock = NSLock()
    private static weak var listener: HandsEventListener?

    public static func setListener(_ l: HandsEventListener?) {
        lock.lock(); listener = l; lock.unlock()
    }

    /// Whether anyone is listening: handlers skip measuring the target point when no one is.
    public static var hasListener: Bool {
        lock.lock(); defer { lock.unlock() }
        return listener != nil
    }

    public static func willAct(_ event: @autoclosure () -> HandsActionEvent) {
        lock.lock(); let l = listener; lock.unlock()
        l?.handsWillAct(event())
    }

    /// The center of a `get bounds` value: `{"x","y","width","height"}`.
    public static func center(ofBounds v: JSONValue?) -> CGPoint? {
        guard let o = v?.object, let x = o["x"]?.double, let y = o["y"]?.double,
              let w = o["width"]?.double, let h = o["height"]?.double else { return nil }
        return CGPoint(x: x + w / 2, y: y + h / 2)
    }
}

extension JSONValue {
    public var double: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
}
