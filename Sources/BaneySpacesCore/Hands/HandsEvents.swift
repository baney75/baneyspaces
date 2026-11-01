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
    /// The target element's frame (screen coordinates, y down), when it could be read: the agent cursor
    /// glides to its center and outlines it.
    public var frame: CGRect?
    /// The agent session the command came from (its terminal, or `mcp:<pid>`).
    public var session: String
    /// `agent_workspace` or `lent`: why the scope guard let the action through.
    public var scope: String
    /// The workspace the target window lives on.
    public var workspace: Int?
    /// For a scroll: `up`, `down`, `left` or `right`.
    public var direction: String?
    /// Names this action, so a frame that is measured while the action runs can find it (`handsFrame`).
    public var id: UInt64
    /// The frame is being measured off the action's thread and follows as `handsFrame(actionID:frame:)`.
    public var frameComing: Bool
    public init(kind: String, ref: String, window: UInt32, pid: Int32, app: String, point: CGPoint?, frame: CGRect? = nil,
                session: String = "", scope: String = "", workspace: Int? = nil, direction: String? = nil,
                id: UInt64 = 0, frameComing: Bool = false) {
        self.kind = kind; self.ref = ref; self.window = window; self.pid = pid; self.app = app; self.point = point
        self.frame = frame; self.session = session; self.scope = scope; self.workspace = workspace; self.direction = direction
        self.id = id; self.frameComing = frameComing
    }
}

public protocol HandsEventListener: AnyObject {
    /// Called on the hands' thread, before the action is dispatched. Must return quickly.
    func handsWillAct(_ event: HandsActionEvent)
    /// Whether the listener will use the target's frame: the hands measure it (an engine call) only if so.
    /// Called on the hands' thread, so it must be cheap and thread-safe.
    func handsWantsFrame(scope: String, workspace: Int?) -> Bool
    /// The frame of an action announced with `frameComing`, from the thread that measured it; nil if it couldn't be read in time.
    func handsFrame(actionID: UInt64, frame: CGRect?)
}

extension HandsEventListener {
    public func handsWantsFrame(scope: String, workspace: Int?) -> Bool { true }
    public func handsFrame(actionID: UInt64, frame: CGRect?) {}
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

    /// Whether anyone wants the target's frame for an action in `scope` on `workspace`: no listener, or one that
    /// won't draw it (the cursor is off, or you are not looking there), means no measuring and no cost.
    public static func wantsFrame(scope: String, workspace: Int?) -> Bool {
        lock.lock(); let l = listener; lock.unlock()
        return l?.handsWantsFrame(scope: scope, workspace: workspace) ?? false
    }

    private static var nextID: UInt64 = 0
    /// A number for an action to be named by.
    public static func newActionID() -> UInt64 { lock.lock(); defer { lock.unlock() }; nextID += 1; return nextID }

    /// The measured frame of an action announced with `frameComing`.
    public static func frameMeasured(actionID: UInt64, frame: CGRect?) {
        lock.lock(); let l = listener; lock.unlock()
        l?.handsFrame(actionID: actionID, frame: frame)
    }

    public static func willAct(_ event: @autoclosure () -> HandsActionEvent) {
        lock.lock(); let l = listener; lock.unlock()
        l?.handsWillAct(event())
    }

    /// The center of a `get bounds` value: `{"x","y","width","height"}`.
    public static func center(ofBounds v: JSONValue?) -> CGPoint? {
        frame(ofBounds: v).map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    /// The frame of a `get bounds` value.
    public static func frame(ofBounds v: JSONValue?) -> CGRect? {
        guard let o = v?.object, let x = o["x"]?.double, let y = o["y"]?.double,
              let w = o["width"]?.double, let h = o["height"]?.double else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
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
