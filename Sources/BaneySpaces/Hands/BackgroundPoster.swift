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
/// Every script runs through `EventRunner`: a stop means post nothing new, and every key or button already pressed is
/// released before the run returns.
///
/// The recipes (keys carrying explicit flags and no authentication message, which is the path AppKit's menu key
/// equivalents need; mouse events carrying the window number in fields 51, 91 and 92, the target pid in field 40,
/// one gesture id in field 58, and the screen point in `CGEventSetWindowLocation`) follow cua-driver's
/// `keyboard.rs`, `mouse.rs` and `skylight.rs` (MIT, trycua/cua; see NOTICE). SkyLight's functions are found by
/// name when first needed: a name that does not resolve removes that part of the route. A pointer event is posted
/// only with every field of the recipe set; a half-stamped event could be handled by another window.
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

    /// What this Mac offers. The public call is always there; SkyLight only when its symbol resolved; the pointer
    /// recipe only when both of its setters resolved.
    static var support: TransportSupport {
        TransportSupport(skyLight: postToPid != nil, pointerStamps: setIntegerField != nil && setWindowLocation != nil)
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

    private static func refused(_ why: String) -> RunReport {
        var r = RunReport()
        r.stopped = HandsError(.notSupported, why, suggestion: "Use `click`, `toggle`, `select` or `set-value` on an element, or do this in the sandbox (phase 2).", retry: .never)
        return r
    }

    // MARK: keys

    /// Presses each chord: key down, a short gap, key up. `stop` is asked before every new press (never before a
    /// release): when it answers, nothing new is posted and any key already down is released first.
    static func keys(_ chords: [KeyChord], permit: BackgroundPermit, stop: () -> HandsError?) -> RunReport {
        precondition(permit.route == .pidKeys, "a key post needs a key permit")
        guard let source = CGEventSource(stateID: .hidSystemState) else { return refused("the event system gave no source for keys") }
        return EventRunner.run(InputScript.chords(chords), stop: stop) { event in
            let chord: KeyChord, down: Bool
            switch event {
            case .keyDown(let c): chord = c; down = true
            case .keyUp(let c): chord = c; down = false
            default: return nil
            }
            // Made now, posted later: the runner makes a press's release before it posts the press.
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: chord.keyCode, keyDown: down) else { return nil }
            // The physical modifier state is never inherited: the flags are exactly the chord's, even none.
            e.flags = CGEventFlags(rawValue: chord.flags)
            return {
                post(e, permit)
                Thread.sleep(forTimeInterval: 0.008)
            }
        }
    }

    // MARK: pointer

    struct PointerPost {
        var report: RunReport
        /// Where the events were aimed on the screen, for telling them from the real pointer's position.
        var screenPoints: [CGPoint]
    }

    /// Posts `events` (window-local points, top-left origin) to the process. `frame` is the window's frame in screen
    /// coordinates, so each point becomes `frame.origin + point`. The window's number is in every event; the real
    /// pointer is not asked to move. With any setter of the recipe missing nothing is posted.
    static func pointer(_ events: [InputEvent], frame: CGRect, drag: Bool, gesture: Int64, permit: BackgroundPermit, stop: () -> HandsError?) -> PointerPost {
        precondition(permit.route == .windowPointer, "a pointer post needs a pointer permit")
        guard let setField = setIntegerField, let setLocation = setWindowLocation else {
            return PointerPost(report: refused("the pointer recipe is incomplete on this Mac, so no pointer event is posted"), screenPoints: [])
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return PointerPost(report: refused("the event system gave no source for the pointer"), screenPoints: [])
        }
        let window = Int64(permit.window)
        var aimed: [CGPoint] = []
        let report = EventRunner.run(events, stop: stop) { event in
            let type: CGEventType, local: CGPoint, state: Int64, subtype: Int64, pause: TimeInterval
            switch event {
            case .mouseMoved(let p): (type, local, state, subtype, pause) = (.mouseMoved, p, 0, 3, 0.02)
            case .mouseDown(let p): (type, local, state, subtype, pause) = (.leftMouseDown, p, 1, drag ? 0 : 3, drag ? 0.03 : 0.06)
            case .mouseDragged(let p): (type, local, state, subtype, pause) = (.leftMouseDragged, p, 1, 0, 0.012)
            case .mouseUp(let p): (type, local, state, subtype, pause) = (.leftMouseUp, p, 1, drag ? 0 : 3, 0)
            default: return nil
            }
            let screen = PointerPath.screenPoint(local: local, frame: frame)
            guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: screen, mouseButton: .left) else { return nil }
            let raw = Unmanaged.passUnretained(e).toOpaque()
            setField(raw, 1, state)
            setField(raw, 3, 0)
            setField(raw, 7, subtype)
            setField(raw, 40, Int64(permit.pid))
            setField(raw, 51, window)
            setField(raw, 91, window)
            setField(raw, 92, window)
            setField(raw, 58, gesture)
            setLocation(raw, Double(screen.x), Double(screen.y))
            e.flags = []
            return {
                post(e, permit)
                aimed.append(screen)
                if pause > 0 { Thread.sleep(forTimeInterval: pause) }
            }
        }
        return PointerPost(report: report, screenPoints: aimed)
    }

    static func newGesture() -> Int64 { Int64(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds & 0x7fff_ffff) }
}
