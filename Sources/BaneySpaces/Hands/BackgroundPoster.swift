import ApplicationServices
import BaneySpacesCore
import CoreGraphics
import Darwin
import Foundation

/// The one file in the hands that makes and posts input events, and the only one HandsSourceTests lets name
/// `CGEvent(`. Every post is to one process (`postToPid`, or SkyLight's `SLEventPostToPid` when its symbol
/// resolves) and needs a `BackgroundPermit`, which only `BackgroundPlanner.plan` can make. Nothing here names the
/// session or HID taps, warps the pointer, activates, raises or switches anything (a source test reads this file).
///
/// The recipes (keys carrying explicit flags and no authentication message, which is the path AppKit's menu key
/// equivalents need; mouse events carrying the window number in fields 51, 91 and 92, the target pid in field 40,
/// one gesture id in field 58, and the screen point in `CGEventSetWindowLocation`) follow cua-driver's
/// `keyboard.rs`, `mouse.rs` and `skylight.rs` (MIT, trycua/cua; see NOTICE). SkyLight's functions are found by
/// name when first needed: a name that does not resolve removes that part of the route, and the public
/// per-process call takes over. It never crashes the app.
enum BackgroundPoster {
    private typealias PostToPid = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Void
    private typealias SetWindowLocation = @convention(c) (UnsafeMutableRawPointer, Double, Double) -> Void
    private typealias SetIntegerField = @convention(c) (UnsafeMutableRawPointer, UInt32, Int64) -> Void

    private static let skyLightHandle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        if let h = skyLightHandle, let p = dlsym(h, name) { return p }
        return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)   // RTLD_DEFAULT
    }

    private static let postToPid: PostToPid? = symbol("SLEventPostToPid").map { unsafeBitCast($0, to: PostToPid.self) }
    private static let setWindowLocation: SetWindowLocation? = symbol("CGEventSetWindowLocation").map { unsafeBitCast($0, to: SetWindowLocation.self) }
    private static let setIntegerField: SetIntegerField? = symbol("SLEventSetIntegerValueField").map { unsafeBitCast($0, to: SetIntegerField.self) }

    /// What this Mac offers. The public call is always there; SkyLight only when its symbol resolved.
    static var support: TransportSupport { TransportSupport(skyLight: postToPid != nil) }

    struct Report {
        var transport: PostTransport
        var events = 0
        /// Set when posting stopped early; the events before it were posted.
        var stopped: HandsError?
    }

    /// Where the real pointer is, by asking the event system for a fresh event's location (it moves nothing).
    static func pointerLocation() -> CGPoint? { CGEvent(source: nil)?.location }

    // MARK: posting

    private static func post(_ event: CGEvent, _ permit: BackgroundPermit) {
        if permit.transport == .skyLightPid, let post = postToPid {
            post(permit.pid, Unmanaged.passUnretained(event).toOpaque())
        } else {
            event.postToPid(permit.pid)
        }
    }

    private static func stamp(_ event: CGEvent, _ field: UInt32, _ value: Int64) {
        if let set = setIntegerField { set(Unmanaged.passUnretained(event).toOpaque(), field, value); return }
        // Without SkyLight only the fields the public API names can be written.
        switch field {
        case 40: event.setIntegerValueField(.eventTargetUnixProcessID, value: value)
        case 91: event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: value)
        case 92: event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: value)
        case 1: event.setIntegerValueField(.mouseEventClickState, value: value)
        default: break
        }
    }

    // MARK: keys

    /// Presses each chord: key down, a short gap, key up. `between` runs before every event and may stop the run
    /// (Donovan's front app changed, the caller gave up); what was posted before that stays posted.
    static func keys(_ chords: [KeyChord], permit: BackgroundPermit, between: () -> HandsError?) -> Report {
        var report = Report(transport: permit.transport)
        precondition(permit.route == .pidKeys, "a key post needs a key permit")
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            report.stopped = HandsError(.engineError, "the event system gave no source for keys", suggestion: "Try again.", retry: .safe)
            return report
        }
        for chord in chords {
            for down in [true, false] {
                if let stop = between() { report.stopped = stop; return report }
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: chord.keyCode, keyDown: down) else {
                    report.stopped = HandsError(.engineError, "a key event could not be made", suggestion: "Try again.", retry: .never)
                    return report
                }
                // The physical modifier state is never inherited: the flags are exactly the chord's, even none.
                event.flags = CGEventFlags(rawValue: chord.flags)
                post(event, permit)
                report.events += 1
                Thread.sleep(forTimeInterval: 0.008)
            }
        }
        return report
    }

    // MARK: pointer

    /// A click (`path` of one point) or a drag along `path`: window-local points, top-left origin. `frame` is the
    /// window's frame in screen coordinates, so each point becomes `frame.origin + point`. The mouse events are
    /// posted to the process with the window's number in them; the real pointer is not asked to move.
    static func pointer(path: [CGPoint], frame: CGRect, drag: Bool, permit: BackgroundPermit, between: () -> HandsError?) -> Report {
        var report = Report(transport: permit.transport)
        precondition(permit.route == .windowPointer, "a pointer post needs a pointer permit")
        guard let first = path.first, let source = CGEventSource(stateID: .hidSystemState) else {
            report.stopped = HandsError(.engineError, "the event system gave no source for the pointer", suggestion: "Try again.", retry: .safe)
            return report
        }
        let gesture = Int64(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds & 0x7fff_ffff)
        let window = Int64(permit.window)

        func emit(_ type: CGEventType, at local: CGPoint, clickState: Int64, subtype: Int64) -> Bool {
            let screen = PointerPath.screenPoint(local: local, frame: frame)
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: screen, mouseButton: .left) else { return false }
            stamp(event, 1, clickState)
            stamp(event, 3, 0)
            stamp(event, 7, subtype)
            stamp(event, 40, Int64(permit.pid))
            stamp(event, 51, window)
            stamp(event, 91, window)
            stamp(event, 92, window)
            stamp(event, 58, gesture)
            if let set = setWindowLocation { set(Unmanaged.passUnretained(event).toOpaque(), Double(screen.x), Double(screen.y)) }
            event.flags = []
            post(event, permit)
            report.events += 1
            return true
        }

        // A move first: a window that never saw the pointer has stale tracking and would take the press for a miss.
        let steps: [(CGEventType, CGPoint, Int64, Int64, TimeInterval)] =
            [(.mouseMoved, first, 0, 3, 0.02), (.leftMouseDown, first, 1, drag ? 0 : 3, drag ? 0.03 : 0.06)]
            + path.dropFirst().map { (CGEventType.leftMouseDragged, $0, 1, Int64(0), 0.012) }
            + [(.leftMouseUp, path.last ?? first, 1, drag ? 0 : 3, 0.0)]
        for (type, point, state, subtype, pause) in steps {
            if let stop = between() {
                report.stopped = stop
                // A press left down is released where the gesture stands, to the same process only.
                if report.events > 1, type != .leftMouseUp { _ = emit(.leftMouseUp, at: point, clickState: 1, subtype: drag ? 0 : 3) }
                return report
            }
            guard emit(type, at: point, clickState: state, subtype: subtype) else {
                report.stopped = HandsError(.engineError, "a mouse event could not be made", suggestion: "Try again.", retry: .never)
                return report
            }
            if pause > 0 { Thread.sleep(forTimeInterval: pause) }
        }
        return report
    }
}
