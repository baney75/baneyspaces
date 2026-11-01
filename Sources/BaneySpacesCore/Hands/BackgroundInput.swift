import CoreGraphics
import Foundation

// Phase 4: keys and a pointer for agent windows that are not in front, posted to one process, never to the
// session. Everything here decides and judges; nothing here posts an event. The app target posts, and only
// with a `BackgroundPermit`, which only `BackgroundPlanner.plan` can make.
//
// The rules of cua-driver's macos-background-input-v1-plan (MIT, trycua/cua; see NOTICE) are the model: an
// exact (pid, window) from the request to the proof, one route chosen by a pure table, no second route after
// a failed proof, and a refusal instead of a guess.

// MARK: - Keys

/// One key with its modifiers, as the window server wants it: a virtual key code and CGEventFlags bits.
public struct KeyChord: Equatable, Sendable {
    public var keyCode: UInt16
    public var flags: UInt64
    /// What the caller wrote, for messages.
    public var label: String

    public static let shift: UInt64 = 0x0002_0000
    public static let control: UInt64 = 0x0004_0000
    public static let option: UInt64 = 0x0008_0000
    public static let command: UInt64 = 0x0010_0000
    public static let function: UInt64 = 0x0080_0000

    public init(keyCode: UInt16, flags: UInt64, label: String) { self.keyCode = keyCode; self.flags = flags; self.label = label }
    public var hasCommand: Bool { flags & Self.command != 0 }
}

public enum KeyParse {
    public static let maxChords = 64

    /// ANSI US layout codes (the layout the window server's virtual keys name), as in cua-driver's key table.
    static let base: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
        "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
    ]

    static let named: [String: UInt16] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "home": 115, "pageup": 116, "forwarddelete": 117, "del": 117, "end": 119, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "minus": 27, "equals": 24, "comma": 43, "period": 47, "slash": 44, "backslash": 42, "semicolon": 41,
        "quote": 39, "grave": 50, "leftbracket": 33, "rightbracket": 30,
    ]

    /// Names for keys that need Shift on this layout.
    static let shiftedNames: [String: String] = ["asterisk": "8", "plus": "=", "underscore": "-", "colon": ";", "question": "/", "pipe": "\\"]
    static let shiftedSymbols: [Character: String] = [
        "*": "8", "+": "=", "_": "-", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "|": "\\", "{": "[", "}": "]", "~": "`",
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "(": "9", ")": "0",
    ]

    static let modifiers: [String: UInt64] = [
        "cmd": KeyChord.command, "command": KeyChord.command, "super": KeyChord.command, "meta": KeyChord.command,
        "shift": KeyChord.shift, "alt": KeyChord.option, "option": KeyChord.option, "opt": KeyChord.option,
        "ctrl": KeyChord.control, "control": KeyChord.control, "fn": KeyChord.function,
    ]

    static func bad(_ spec: String, _ why: String) -> HandsError {
        HandsError(.badArguments, "\(why): \(spec)",
                   suggestion: "Write a key like Return, Tab, a, 9, asterisk, cmd+a or cmd+shift+z; several keys are separated by spaces (\"h i Return\"). Modifiers: cmd, shift, alt, ctrl, fn.",
                   retry: .safe)
    }

    /// `"cmd+shift+z"`, `"Return"`, `"*"`, `"cmd++"`.
    public static func chord(_ spec: String) -> Result<KeyChord, HandsError> {
        let s = spec.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return .failure(bad(spec, "an empty key")) }
        var parts: [String]
        if s == "+" { parts = ["+"] }
        else if s.hasSuffix("+") && s.count > 1 { parts = s.dropLast().split(separator: "+", omittingEmptySubsequences: true).map(String.init) + ["+"] }
        else { parts = s.split(separator: "+", omittingEmptySubsequences: false).map(String.init) }
        guard let keyName = parts.popLast(), !keyName.isEmpty else { return .failure(bad(spec, "no key after the modifiers")) }
        var flags: UInt64 = 0
        for m in parts {
            guard let f = modifiers[m.lowercased()] else { return .failure(bad(spec, "\(m) is not a modifier")) }
            flags |= f
        }
        let lower = keyName.lowercased()
        var code: UInt16?
        if keyName.count == 1, let c = keyName.first {
            if let shifted = shiftedSymbols[c] { code = base[shifted]; flags |= KeyChord.shift }
            else if let b = base[lower] {
                code = b
                // A capital is Shift only when it stands alone ("A"); "cmd+A" is how menus write cmd+a, not cmd+shift+a.
                if c.isUppercase, parts.isEmpty { flags |= KeyChord.shift }
            }
        } else if let n = named[lower.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")] {
            code = n
        } else if let s = shiftedNames[lower], let b = base[s] {
            code = b; flags |= KeyChord.shift
        } else if let alias = aliases[lower.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")], let n = named[alias] {
            code = n
        }
        guard let code else { return .failure(bad(spec, "no such key")) }
        return .success(KeyChord(keyCode: code, flags: flags, label: s))
    }

    static let aliases: [String: String] = [
        "pgup": "pageup", "pgdn": "pagedown", "arrowleft": "left", "arrowright": "right", "arrowup": "up", "arrowdown": "down",
        "leftarrow": "left", "rightarrow": "right", "uparrow": "up", "downarrow": "down", "fwddelete": "forwarddelete", "bksp": "backspace",
    ]

    /// The character a chord types, when it types one: no command, control, option or fn; letters, digits, punctuation
    /// and space (Return, Delete and the others are not text).
    public static func character(of c: KeyChord) -> Character? {
        if c.flags & ~KeyChord.shift != 0 { return nil }
        if c.keyCode == 49 { return c.flags == 0 ? " " : nil }
        guard let key = base.first(where: { $0.value == c.keyCode })?.key, let ch = key.first else { return nil }
        guard c.flags & KeyChord.shift != 0 else { return ch }
        if ch.isLetter { return Character(ch.uppercased()) }
        return shiftedSymbols.first(where: { $0.value == key })?.key
    }

    /// Several chords separated by spaces. At most `maxChords`.
    public static func sequence(_ spec: String) -> Result<[KeyChord], HandsError> {
        let words = spec.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        guard !words.isEmpty else { return .failure(bad(spec, "an empty key")) }
        guard words.count <= maxChords else {
            return .failure(HandsError(.badArguments, "\(words.count) keys in one call (at most \(maxChords))",
                                       suggestion: "Send them in several calls, or use `type` to put text in an element.", retry: .safe))
        }
        var out: [KeyChord] = []
        for w in words {
            switch chord(w) {
            case .success(let c): out.append(c)
            case .failure(let e): return .failure(e)
            }
        }
        return .success(out)
    }
}

// MARK: - Routes

public enum InputKind: String, Codable, Sendable { case keys, pointer }

/// How an event reaches the process. SkyLight when its symbol resolved, the public per-process call otherwise;
/// never the session or HID tap.
public enum PostTransport: String, Codable, Sendable {
    case skyLightPid = "skylight_pid"
    case publicPid = "cgevent_pid"
}

public struct TransportSupport: Equatable, Sendable {
    public var skyLight: Bool
    public var publicPid: Bool
    /// Every setter the pointer recipe needs resolved (the integer-field writer and the window-location writer).
    /// A pointer event with some of its fields missing is never posted: it could be handled by another window.
    public var pointerStamps: Bool
    public init(skyLight: Bool, publicPid: Bool = true, pointerStamps: Bool = true) {
        self.skyLight = skyLight; self.publicPid = publicPid; self.pointerStamps = pointerStamps
    }
    /// One transport per action, decided once: no second attempt after a post whose proof failed.
    public func pick() -> PostTransport? { skyLight ? .skyLightPid : (publicPid ? .publicPid : nil) }
}

public enum BackgroundRoute: String, Codable, Sendable {
    case pidKeys = "pid_keys"
    case windowPointer = "window_pointer"
}

public enum ScopeKind: String, Sendable { case agentWorkspace, lent, outside }
public enum WindowCondition: String, Sendable { case normal, minimized, appHidden }

/// What reads the result back. An action with `.none` is refused before anything is posted.
public enum VerifierPlan: String, Sendable {
    /// Accessibility readings of the window's focused element and tree.
    case ax
    /// A capture of the window, compared inside the stroke.
    case pixels
    case axAndPixels
    case none
    public var hasAX: Bool { self == .ax || self == .axAndPixels }
    public var hasPixels: Bool { self == .pixels || self == .axAndPixels }
}

/// Why a route is shut for an app for the rest of this run.
public enum RouteBlock: String, Sendable {
    /// The app came to the front by itself after an event was posted to it.
    case selfActivates = "self_activates"
    /// The app received the events and did nothing with them, twice.
    case refusesBackgroundInput = "refuses_background_input"
}

/// Everything the planner needs, collected by the app at the moment of execution.
public struct BackgroundFacts: Equatable, Sendable {
    public var kind: InputKind
    public var app: String
    public var pid: Int32
    public var window: UInt32
    public var scope: ScopeKind
    /// The pid is one BaneySpaces started (same pid and start time), not just any process with a window here.
    public var pidIsAgentOwned: Bool
    /// What the window server says owns the window now.
    public var windowOwnerPid: Int32?
    /// The window is among the app's accessibility windows (`_AXUIElementGetWindow`).
    public var axWindowResolved: Bool
    /// Other windows of the same process a key could land in.
    public var siblingWindows: Int
    public var condition: WindowCondition
    /// A sheet or an Open or Save panel is up.
    public var hasSheetOrPanel: Bool
    public var focusedWindow: UInt32?
    public var focusedElementWindow: UInt32?
    /// Donovan is in this app.
    public var targetIsFront: Bool
    public var transports: TransportSupport
    public var block: RouteBlock?
    public var verifier: VerifierPlan
    /// Pointer only: the point lies inside the window's frame.
    public var pointInsideWindow: Bool
    /// The app has a focused element and accessibility cannot say which window it is in (not even through its window
    /// attribute). Keys could be going anywhere, so they are refused.
    public var focusedElementUnplaced: Bool
    /// Pointer only: a point lies in the title bar (close, minimize, zoom, and the drag that moves the window).
    public var pointInTitleBar: Bool

    public init(kind: InputKind, app: String, pid: Int32, window: UInt32, scope: ScopeKind, pidIsAgentOwned: Bool,
                windowOwnerPid: Int32?, axWindowResolved: Bool, siblingWindows: Int, condition: WindowCondition,
                hasSheetOrPanel: Bool, focusedWindow: UInt32?, focusedElementWindow: UInt32?, targetIsFront: Bool,
                transports: TransportSupport, block: RouteBlock?, verifier: VerifierPlan, pointInsideWindow: Bool = true, pointInTitleBar: Bool = false, focusedElementUnplaced: Bool = false) {
        self.kind = kind; self.app = app; self.pid = pid; self.window = window; self.scope = scope
        self.pidIsAgentOwned = pidIsAgentOwned; self.windowOwnerPid = windowOwnerPid; self.axWindowResolved = axWindowResolved
        self.siblingWindows = siblingWindows; self.condition = condition; self.hasSheetOrPanel = hasSheetOrPanel
        self.focusedWindow = focusedWindow; self.focusedElementWindow = focusedElementWindow; self.targetIsFront = targetIsFront
        self.transports = transports; self.block = block; self.verifier = verifier; self.pointInsideWindow = pointInsideWindow; self.pointInTitleBar = pointInTitleBar
        self.focusedElementUnplaced = focusedElementUnplaced
    }
}

/// Leave to post: one exact process and window, one route, one transport. Only the planner makes one, so
/// the poster cannot be handed a pid that did not pass the checks.
public struct BackgroundPermit: Equatable, Sendable {
    public let route: BackgroundRoute
    public let transport: PostTransport
    public let pid: Int32
    public let window: UInt32
    public let verifier: VerifierPlan
    init(route: BackgroundRoute, transport: PostTransport, pid: Int32, window: UInt32, verifier: VerifierPlan) {
        self.route = route; self.transport = transport; self.pid = pid; self.window = window; self.verifier = verifier
    }
}

/// Every refusal says what to do instead.
public enum BackgroundRefusal {
    static let sandboxLine = "Do this in the sandbox (phase 2), or use `type`, `set-value`, `click`, `toggle` or `select` on the element."

    public static func outside(_ app: String, window: UInt32) -> HandsError {
        HandsError(.outsideAgentWorkspace, "window \(window) of \(app) is not on the agent workspace and is not lent",
                   suggestion: "Open it on the agent workspace with `baneyspaces agent open \(app)`; Donovan can lend an app he is not using.")
    }
    public static func notOurProcess(_ app: String, pid: Int32) -> HandsError {
        HandsError(.needsLend, "process \(pid) (\(app)) is not one BaneySpaces started for an agent, so keys and pointer events are never posted to it",
                   suggestion: "Start your own copy with `baneyspaces agent open \(app)`, or ask Donovan to lend this one; a lent app gets keys only while he is away from it.",
                   retry: .never)
    }
    public static func windowChanged(window: UInt32, owner: Int32?, pid: Int32) -> HandsError {
        HandsError(.staleRef, "window \(window) belongs to process \(owner.map(String.init) ?? "none") now, not \(pid)",
                   suggestion: "Run `baneyspaces agent windows` and take a new snapshot.", retry: .afterSnapshot)
    }
    public static func inUse(_ app: String) -> HandsError {
        HandsError(.inUse, "\(app) is in front: Donovan is using it", suggestion: "Wait until he has been away from \(app) for 30 seconds.", retry: .safe)
    }
    public static func notVisibleToInput(_ app: String, _ condition: WindowCondition) -> HandsError {
        HandsError(.notSupported, "\(app)'s window is \(condition == .minimized ? "minimized" : "hidden"); a process-addressed key or pointer event cannot be proven to reach it",
                   suggestion: "Use `click`, `toggle`, `select` or `set-value` on an element (accessibility works on it), or " + sandboxLine, retry: .never)
    }
    public static func sheet(_ app: String) -> HandsError {
        HandsError(.needsSandbox, "\(app)'s window has a sheet or a file panel up; agents never drive those on this Mac",
                   suggestion: "Close the sheet with `click` on its Cancel button, or " + sandboxLine, retry: .never)
    }
    public static func blocked(_ app: String, _ why: RouteBlock) -> HandsError {
        switch why {
        case .selfActivates:
            return HandsError(.notSupported, "\(app) brought itself to the front after an event was posted to it, so keys and pointer events to it are refused for the rest of this run",
                              suggestion: sandboxLine, retry: .never)
        case .refusesBackgroundInput:
            return HandsError(.notSupported, "\(app) did not act on background keys or pointer events twice, so they are refused for the rest of this run",
                              suggestion: sandboxLine, retry: .never)
        }
    }
    public static func axUnresolved(_ app: String, window: UInt32) -> HandsError {
        HandsError(.notSupported, "window \(window) of \(app) is not among the app's accessibility windows, so no event can be proven to land in it",
                   suggestion: "Run `baneyspaces agent windows` and snapshot the window again; if it stays missing, " + sandboxLine, retry: .never)
    }
    public static func siblings(_ app: String, count: Int) -> HandsError {
        HandsError(.notSupported, "\(app) has \(count) other window\(count == 1 ? "" : "s"); a key goes to a process, not a window, and could land in one of them",
                   suggestion: "Close the other window\(count == 1 ? "" : "s") of this copy of \(app), or use `type` or `set-value` on the element.", retry: .never)
    }
    public static func notKeyWindow(_ app: String, focused: UInt32?, window: UInt32) -> HandsError {
        HandsError(.notSupported, "window \(window) is not where \(app)'s keys go now (its focused window is \(focused.map(String.init) ?? "none"))",
                   suggestion: "`click` the element in this window first so the app focuses it, then press the key again; or use `type` on it.", retry: .never)
    }
    public static func noTransport(_ app: String) -> HandsError {
        HandsError(.notSupported, "this Mac has no per-process event route that BaneySpaces can use (SkyLight symbol missing and the public call unavailable)",
                   suggestion: sandboxLine, retry: .never)
    }
    public static func noVerifier(_ app: String) -> HandsError {
        HandsError(.notSupported, "nothing in \(app)'s window can be read back, so a key or pointer event there could not be proven",
                   suggestion: "Take a snapshot to confirm the window exposes an accessibility tree, allow Screen Recording for BaneySpaces for pixel proof, or " + sandboxLine, retry: .never)
    }
    public static func pointerStampsMissing(_ app: String) -> HandsError {
        HandsError(.notSupported, "this Mac does not offer every field a pointer event needs to name one window, so no pointer event is posted to \(app) (it could be handled by another window of the process)",
                   suggestion: "Use `click`, `toggle`, `select` or `set-value` on an element, or " + sandboxLine, retry: .never)
    }
    public static func pointInTitleBar(window: UInt32) -> HandsError {
        HandsError(.badArguments, "the point is in window \(window)'s title bar, where a click presses close, minimize or zoom and a drag moves the window",
                   suggestion: "Give a point below the title bar. Coordinates start at the window's top-left corner, title bar included (`baneyspaces agent shot` shows the window at twice that size in pixels).", retry: .safe)
    }
    public static func pointOutside(window: UInt32) -> HandsError {
        HandsError(.badArguments, "the point is outside window \(window)",
                   suggestion: "Give x and y in points from the window's top-left corner, inside its size (`baneyspaces agent shot` shows it at twice that in pixels).", retry: .safe)
    }
    /// After a post: nothing proved it.
    public static func unverified(basis: String) -> HandsError {
        HandsError(.unverified, "the events were posted, and nothing read back from the window shows they landed (\(basis))",
                   suggestion: "Do not send them again. Read the element with `baneyspaces agent get` or take a snapshot; if they did not land, " + sandboxLine, retry: .never)
    }
    public static func elementNotPlaced(_ app: String) -> HandsError {
        HandsError(.notSupported, "\(app)'s focused element cannot be placed in any window, so a key could go to a window nobody can name",
                   suggestion: "`click` the element in this window first so the app focuses something accessibility can place, or use `type` or `set-value` on it, or " + sandboxLine, retry: .never)
    }
    public static func userActivated(_ app: String) -> HandsError {
        HandsError(.inUse, "Donovan brought \(app) forward while events were being posted to it; the rest were not sent",
                   suggestion: "Read the element back before doing anything else: part of the input may have landed. Wait until he has been away from \(app) for 30 seconds.", retry: .never)
    }
    /// Some steps of a multi-key press were proved and one was not; the steps after it were not sent.
    public static func partial(landed: Int, of total: Int, basis: String) -> HandsError {
        HandsError(.unverified, "\(landed) of \(total) steps landed; step \(landed + 1) showed no sign of landing (\(basis)) and the steps after it were not sent",
                   suggestion: "Do not send the whole press again: the first \(landed) step\(landed == 1 ? "" : "s") already landed. Read the element with `baneyspaces agent get` and continue from step \(landed + 1) if it did not land.", retry: .never)
    }
    public static func frontUnknown(_ app: String) -> HandsError {
        HandsError(.actionFailed, "the front app could not be read while events were being posted to \(app); the rest were not sent",
                   suggestion: "Read the element back before doing anything else: part of the input may have landed.", retry: .never)
    }
    public static func frontChanged(_ app: String, to pid: Int32?) -> HandsError {
        HandsError(.actionFailed, "the front app changed while events were being posted to \(app); the rest were not sent",
                   suggestion: "Read the element back before doing anything else: part of the input may have landed. BaneySpaces did not follow the change.", retry: .never)
    }
    public static func pointerMoved(from: CGPoint, to: CGPoint) -> HandsError {
        HandsError(.actionFailed, "the real pointer moved from (\(Int(from.x)), \(Int(from.y))) to (\(Int(to.x)), \(Int(to.y))) while an event was posted",
                   suggestion: "Read the element back before doing anything else. If Donovan was using the mouse, wait until he is away.", retry: .never)
    }
}

// MARK: - The planner

public enum BackgroundPlanner {
    /// One route or one refusal, from the facts as they are now. The first unmet condition decides, in the order
    /// that matters: whose process, then whether Donovan is there, then the window, then the route's own needs.
    public static func plan(_ f: BackgroundFacts) -> Result<BackgroundPermit, HandsError> {
        if f.scope == .outside { return .failure(BackgroundRefusal.outside(f.app, window: f.window)) }
        // On the agent workspace the process must be one BaneySpaces started. A lent app is Donovan's own process;
        // the lend names its windows.
        if f.scope == .agentWorkspace, !f.pidIsAgentOwned { return .failure(BackgroundRefusal.notOurProcess(f.app, pid: f.pid)) }
        if f.windowOwnerPid != f.pid { return .failure(BackgroundRefusal.windowChanged(window: f.window, owner: f.windowOwnerPid, pid: f.pid)) }
        if f.targetIsFront { return .failure(BackgroundRefusal.inUse(f.app)) }
        if f.condition != .normal { return .failure(BackgroundRefusal.notVisibleToInput(f.app, f.condition)) }
        if f.hasSheetOrPanel { return .failure(BackgroundRefusal.sheet(f.app)) }
        if let b = f.block { return .failure(BackgroundRefusal.blocked(f.app, b)) }
        if !f.axWindowResolved { return .failure(BackgroundRefusal.axUnresolved(f.app, window: f.window)) }
        switch f.kind {
        case .keys:
            if f.siblingWindows > 0 { return .failure(BackgroundRefusal.siblings(f.app, count: f.siblingWindows)) }
            if f.focusedElementUnplaced { return .failure(BackgroundRefusal.elementNotPlaced(f.app)) }
            // The app's focused window must be this one. Its focused element, if it has one, must be in it too (an app
            // like Calculator has none: its keys go to the window, and the proof reads the window's content).
            if f.focusedWindow != f.window || (f.focusedElementWindow != nil && f.focusedElementWindow != f.window) {
                return .failure(BackgroundRefusal.notKeyWindow(f.app, focused: f.focusedWindow, window: f.window))
            }
            if !f.verifier.hasAX { return .failure(BackgroundRefusal.noVerifier(f.app)) }
        case .pointer:
            if !f.pointInsideWindow { return .failure(BackgroundRefusal.pointOutside(window: f.window)) }
            if f.pointInTitleBar { return .failure(BackgroundRefusal.pointInTitleBar(window: f.window)) }
            if !f.transports.pointerStamps { return .failure(BackgroundRefusal.pointerStampsMissing(f.app)) }
            if f.verifier == .none { return .failure(BackgroundRefusal.noVerifier(f.app)) }
        }
        guard let transport = f.transports.pick() else { return .failure(BackgroundRefusal.noTransport(f.app)) }
        return .success(BackgroundPermit(route: f.kind == .keys ? .pidKeys : .windowPointer, transport: transport,
                                         pid: f.pid, window: f.window, verifier: f.verifier))
    }
}

/// Routes shut for an app after it misbehaved, for the rest of this run. An app that came forward by itself is shut
/// out by bundle (the app does that wherever it runs). Dropped input is judged for one process only: one agent's copy
/// ignoring keys says nothing about another's.
public struct RouteBreaker: Equatable, Sendable {
    private var shut: [String: RouteBlock] = [:]
    private var silent: [String: Int] = [:]
    public static let silentLimit = 2
    public init() {}

    public func block(bundle: String, pid: Int32, kind: InputKind) -> RouteBlock? {
        shut["b:" + bundle + "|" + kind.rawValue] ?? shut["p:\(pid)|" + kind.rawValue]
    }

    /// The app became the front app by itself after a post (or the target was activated while one ran).
    public mutating func selfActivated(bundle: String, kind: InputKind) { shut["b:" + bundle + "|" + kind.rawValue] = .selfActivates }

    /// This process came forward after a post and nothing says Donovan did it (no tap to ask): shut for this process only.
    public mutating func selfActivated(pid: Int32, kind: InputKind) { shut["p:\(pid)|" + kind.rawValue] = .selfActivates }

    /// Events whose effect was certain to show (text typed into a readable text field) changed nothing. Two in a row
    /// shut the route for that process; a proof opens the count again. Keys whose effect may be nothing (Home at the
    /// top, Right at the end) never come here.
    public mutating func dropped(pid: Int32, kind: InputKind) {
        let k = "p:\(pid)|" + kind.rawValue
        silent[k, default: 0] += 1
        if silent[k, default: 0] >= Self.silentLimit, shut[k] == nil { shut[k] = .refusesBackgroundInput }
    }
    public mutating func proved(pid: Int32, kind: InputKind) { silent["p:\(pid)|" + kind.rawValue] = 0 }
}

// MARK: - Events, always balanced

public enum InputEvent: Equatable, Sendable {
    case keyDown(KeyChord), keyUp(KeyChord)
    case mouseMoved(CGPoint), mouseDown(CGPoint), mouseDragged(CGPoint), mouseUp(CGPoint)

    public var isRelease: Bool {
        switch self {
        case .keyUp, .mouseUp: return true
        default: return false
        }
    }
    public var isPress: Bool {
        switch self {
        case .keyDown, .mouseDown: return true
        default: return false
        }
    }
}

public enum InputScript {
    /// Down then up for each chord.
    public static func chords(_ chords: [KeyChord]) -> [InputEvent] { chords.flatMap { [InputEvent.keyDown($0), .keyUp($0)] } }
    /// The pointer arriving at a point, before anything is pressed.
    public static func hover(at p: CGPoint) -> [InputEvent] { [.mouseMoved(p)] }
    public static func click(at p: CGPoint) -> [InputEvent] { [.mouseDown(p), .mouseUp(p)] }
    public static func drag(path: [CGPoint]) -> [InputEvent] {
        guard let first = path.first else { return [] }
        return [.mouseDown(first)] + path.dropFirst().map(InputEvent.mouseDragged) + [.mouseUp(path.last ?? first)]
    }
}

public struct RunReport: Equatable, Sendable {
    /// Everything posted, in order, releases included.
    public var posted: [InputEvent] = []
    public var stopped: HandsError?
    /// Releases posted because the run was stopped or an event could not be made.
    public var released = 0
    public init() {}
}

/// Posts a script of events with one rule: a stop means "post nothing new", and every press already posted gets its
/// release, newest first, before the run returns. A release is never subject to the stop.
///
/// A release can never fail after its press went out: the release event is made BEFORE the press is posted, and if it
/// cannot be made the press is not posted. `prepare` makes an event ready to post (nil if it cannot be made); posting
/// a prepared event cannot fail.
public enum EventRunner {
    public typealias Prepared = () -> Void

    public static func run(_ events: [InputEvent], stop: () -> HandsError?, prepare: (InputEvent) -> Prepared?) -> RunReport {
        var report = RunReport()
        struct Held { var press: InputEvent; var release: InputEvent; var post: Prepared }
        var held: [Held] = []
        func cannotMake() -> HandsError {
            HandsError(.engineError, "an input event could not be made, so nothing further was posted", suggestion: "Read the element back before trying again.", retry: .never)
        }
        /// The event that undoes a press at its current position.
        func release(for e: InputEvent) -> InputEvent? {
            switch e {
            case .keyDown(let c): return .keyUp(c)
            case .mouseDown(let p), .mouseDragged(let p): return .mouseUp(p)
            default: return nil
            }
        }
        loop: for e in events {
            if e.isRelease {
                // Sent at once: the matching release made ahead of the press, or, for a script release with no press, made now.
                if let i = held.lastIndex(where: { matches($0.press, e) }) {
                    let h = held.remove(at: i)
                    h.post(); report.posted.append(h.release)
                } else if let post = prepare(e) { post(); report.posted.append(e) }
                continue
            }
            if let s = stop() { report.stopped = s; break loop }
            guard let post = prepare(e) else { report.stopped = cannotMake(); break loop }
            if let rel = release(for: e) {
                // The release first. A drag step moves the pending mouse release to where the gesture now stands.
                guard let relPost = prepare(rel) else { report.stopped = cannotMake(); break loop }
                post(); report.posted.append(e)
                if case .mouseDragged = e, let i = held.lastIndex(where: { if case .mouseDown = $0.press { return true }; return false }) {
                    held[i].release = rel; held[i].post = relPost
                } else {
                    held.append(Held(press: e, release: rel, post: relPost))
                }
            } else {
                post(); report.posted.append(e)
            }
        }
        for h in held.reversed() { h.post(); report.posted.append(h.release); report.released += 1 }
        return report
    }

    private static func matches(_ press: InputEvent, _ release: InputEvent) -> Bool {
        switch (press, release) {
        case (.keyDown(let a), .keyUp(let b)): return a == b
        case (.mouseDown, .mouseUp): return true
        default: return false
        }
    }
}

// MARK: - Guards while posting

public enum FrontChange: Equatable, Sendable {
    case same
    /// The app we posted to is the front app now: it activated itself (or Donovan chose it).
    case targetCameForward
    case other(Int32?)
    /// The front app could not be read at the start or now. That is not a pass.
    case unknown
}

public enum PostGuard {
    public enum PointerVerdict: Equatable, Sendable {
        case unmoved
        /// A reading was missing, or the pointer moved and nothing can say whose doing it was.
        case unchecked
        /// The pointer moved and a hardware event explains it: Donovan's own hand.
        case userMoved
        case moved(from: CGPoint, to: CGPoint)
        /// An event posted by BaneySpaces' own process reached the session: it was not sent to one process only.
        case leaked(Int)
        public var error: HandsError? {
            switch self {
            case .moved(let f, let t): return BackgroundRefusal.pointerMoved(from: f, to: t)
            case .leaked(let n):
                return HandsError(.actionFailed, "\(n) event(s) posted by BaneySpaces reached the session instead of one process",
                                  suggestion: "Read the element back before doing anything else. This is a bug in BaneySpaces' posting; report it.", retry: .never)
            default: return nil
            }
        }
        public var label: String {
            switch self {
            case .unmoved: return "unmoved"
            case .unchecked: return "unchecked"
            case .userMoved: return "user_moved"
            case .moved: return "moved"
            case .leaked: return "leaked"
            }
        }
    }

    public static func front(start: Int32?, now: Int32?, target: Int32) -> FrontChange {
        guard let start, let now else { return .unknown }
        if start == now { return .same }
        return now == target ? .targetCameForward : .other(now)
    }

    /// Every app that was activated while an action ran (from the workspace's activation notifications).
    public static func activations(_ pids: [Int32], target: Int32) -> FrontChange {
        if pids.isEmpty { return .same }
        return pids.contains(target) ? .targetCameForward : .other(pids.first)
    }

    /// The notification history and a synchronous look at the front app, together. Either one seeing a change is a
    /// change: a front app that moved before its notification arrived is not forgotten.
    public static func span(activations pids: [Int32], start: Int32?, now: Int32?, target: Int32) -> FrontChange {
        let seen = activations(pids, target: target)
        if seen != .same { return seen }
        return front(start: start, now: now, target: target)
    }

    public enum FrontVerdict: Equatable, Sendable {
        case same
        /// Donovan brought the app forward: hardware events in the span. Stop, and do not blame the route.
        case userActivated
        /// The app came forward by itself: a tap was listening and heard no hardware.
        case selfActivated
        /// The app came forward and nothing can say who did it (no tap): blamed on the process only.
        case unattributed
        case other(Int32?)
        case unknown
    }

    /// `hardware`: whether a hardware event (source process 0) was seen in the span; nil when nothing was listening.
    public static func verdict(_ change: FrontChange, hardware: Bool?) -> FrontVerdict {
        switch change {
        case .same: return .same
        case .unknown: return .unknown
        case .other(let p): return .other(p)
        case .targetCameForward:
            guard let hardware else { return .unattributed }
            return hardware ? .userActivated : .selfActivated
        }
    }
}

/// One keyboard or mouse event as a listen-only session tap reports it.
public struct SessionEvent: Equatable, Sendable {
    /// The process that posted it; 0 is hardware.
    public var sourcePid: Int64
    public init(sourcePid: Int64) { self.sourcePid = sourcePid }
}

public enum PointerAudit {
    /// The real pointer is Donovan's, and he moves it while agents work. It fails an action only when it ends where
    /// we posted, when nothing from the hardware explains that it moved, or when one of our events reached the
    /// session. `tap` is what a listen-only session tap saw during the action (nil: no tap could be made).
    public static func verdict(before: CGPoint?, after: CGPoint?, posted: [CGPoint], tap: [SessionEvent]?, ownPid: Int64) -> PostGuard.PointerVerdict {
        if let tap {
            let leaked = tap.filter { $0.sourcePid == ownPid }.count
            if leaked > 0 { return .leaked(leaked) }
        }
        guard let b = before, let a = after else { return .unchecked }
        if b == a { return .unmoved }
        if posted.contains(where: { abs($0.x - a.x) < 0.5 && abs($0.y - a.y) < 0.5 }) { return .moved(from: b, to: a) }
        guard let tap else { return .unchecked }
        return tap.contains { $0.sourcePid == 0 } ? .userMoved : .moved(from: b, to: a)
    }
}

// MARK: - Delivery proof

/// What accessibility says about one element, kept by value so a reading from one moment can be compared
/// with another. Content is hashed and measured, never kept: it can be Donovan's.
public struct ElementReading: Equatable, Sendable {
    /// The window the element belongs to, as accessibility maps it. A reading with no window proves nothing.
    public var window: UInt32?
    /// Role and frame: which element this is.
    public var identity: String
    public var valueLength: Int?
    public var valueDigest: UInt64?
    public var selectionLocation: Int?
    public var selectionLength: Int?
    /// A hash of the text's attributes (fonts, underline...) when the element answers for them.
    public var attributesDigest: UInt64?
    /// The value itself, held in memory only so that a typed segment can be looked for in it. It is never logged,
    /// returned or written; values over `maxKept` characters are not kept.
    public var value: String?
    public static let maxKept = 100_000

    public init(window: UInt32?, identity: String, valueLength: Int? = nil, valueDigest: UInt64? = nil, selectionLocation: Int? = nil,
                selectionLength: Int? = nil, attributesDigest: UInt64? = nil, value: String? = nil) {
        self.window = window; self.identity = identity; self.valueLength = valueLength; self.valueDigest = valueDigest
        self.selectionLocation = selectionLocation; self.selectionLength = selectionLength; self.attributesDigest = attributesDigest
        self.value = value
    }

    /// FNV-1a, so the same text hashes the same in a test and in the app.
    public static func digest(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100_0000_01b3 }
        return h
    }
    public static func text(window: UInt32?, identity: String, value: String?, selection: (Int, Int)? = nil, attributes: String? = nil) -> ElementReading {
        ElementReading(window: window, identity: identity, valueLength: value?.count, valueDigest: value.map(digest),
                       selectionLocation: selection?.0, selectionLength: selection?.1, attributesDigest: attributes.map(digest),
                       value: value.flatMap { $0.count <= maxKept ? $0 : nil })
    }
    /// A text element: it has a value or a selection to read.
    public var isText: Bool { valueDigest != nil || selectionLocation != nil }
}

/// The window's own state: its title (hashed), whether it is marked edited, and how many sheets hang off it.
public struct WindowReading: Equatable, Sendable {
    public var titleDigest: UInt64?
    public var edited: Bool?
    public var sheets: Int
    public init(titleDigest: UInt64?, edited: Bool?, sheets: Int) { self.titleDigest = titleDigest; self.edited = edited; self.sheets = sheets }
}

public enum KeyEffect: String, Sendable { case text, selection, focus, attributes, content, window }

/// What a key is expected to change, so that only that counts as proof.
public enum KeyPrediction {
    static let arrows: Set<UInt16> = [123, 124, 125, 126, 115, 119, 116, 121]   // arrows, Home, End, Page Up, Page Down
    static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

    /// A chord that produces or removes characters: no command or control, and not a movement, Tab, Escape or F-key.
    static func isTextual(_ c: KeyChord) -> Bool {
        if c.flags & (KeyChord.command | KeyChord.control) != 0 { return false }
        return !arrows.contains(c.keyCode) && c.keyCode != 48 && c.keyCode != 53 && !functionKeys.contains(c.keyCode)
    }

    /// What one step is expected to change (a step is a typed segment or a single chord; see `KeySteps`).
    public static func expected(_ chords: [KeyChord], focusIsText: Bool) -> Set<KeyEffect> {
        var out: Set<KeyEffect> = []
        for c in chords {
            if arrows.contains(c.keyCode) {
                out.insert(focusIsText ? .selection : .content)
            } else if c.flags == KeyChord.command, [11, 34, 32].contains(c.keyCode) {
                out.insert(.attributes)                       // bold, italic, underline
            } else if c.flags == KeyChord.command, c.keyCode == 0 {
                out.insert(.selection)                        // select all
            } else if c.flags & (KeyChord.command | KeyChord.control) != 0 {
                out.insert(.window)                           // save, new, close...: the window is what changes
            } else if c.keyCode == 36 {
                // Return types a newline in a text view, runs the action of a one-line field (the window may change).
                out.insert(focusIsText ? .text : .content); out.insert(.window)
            } else if c.keyCode == 48 {
                out.insert(.focus)
            } else if isTextual(c) {
                out.insert(focusIsText ? .text : .content)
            } else {
                out.insert(.content)
            }
        }
        return out
    }

    /// Only a typed segment (printable characters, no Option, no Return, Delete or ForwardDelete) into a readable text
    /// field must change its value; for nothing else is silence evidence that the events were dropped. Delete at the
    /// start, Escape, dead keys and a one-line field's Return may all do nothing.
    public static func certainToShow(_ step: KeyStep, focusIsText: Bool) -> Bool { focusIsText && step.typed != nil }
}

/// One thing to prove: either a run of printable characters, which must appear, or a single chord.
public struct KeyStep: Equatable, Sendable {
    public var chords: [KeyChord]
    /// The characters a typed segment puts in; nil for a single chord.
    public var typed: String?
    public init(chords: [KeyChord], typed: String?) { self.chords = chords; self.typed = typed }
}

public enum KeySteps {
    /// Consecutive printable chords are one typed segment; every other chord is a step of its own. A press is verified
    /// step by step, in order, and stops at the first step that shows nothing.
    public static func split(_ chords: [KeyChord]) -> [KeyStep] {
        var out: [KeyStep] = []
        var run: [KeyChord] = []
        var text = ""
        func flush() {
            if !run.isEmpty { out.append(KeyStep(chords: run, typed: text)); run = []; text = "" }
        }
        for c in chords {
            if let ch = KeyParse.character(of: c) { run.append(c); text.append(ch) }
            else { flush(); out.append(KeyStep(chords: [c], typed: nil)) }
        }
        flush()
        return out
    }
}

/// Attributes of text, reduced to values that read the same every time: names, numbers, flags and the components of a
/// color, never an object's description (which holds its address).
public enum StableAttributes {
    public static func describe(_ value: Any) -> String? {
        if CFGetTypeID(value as AnyObject) == CGColor.typeID {
            let c = value as! CGColor
            let space = c.colorSpace?.name as String? ?? "?"
            return "color(" + space + ":" + (c.components ?? []).map { String(format: "%.3f", Double($0)) }.joined(separator: ",") + ")"
        }
        switch value {
        case let s as String: return s
        case let n as NSNumber: return "\(n)"
        case let d as [AnyHashable: Any]:
            let parts = d.compactMap { (k, v) -> String? in describe(v).map { "\(k)=\($0)" } }
            return "{" + parts.sorted().joined(separator: ";") + "}"
        case let a as [Any]: return "[" + a.compactMap(describe).joined(separator: ",") + "]"
        default: return nil
        }
    }

    /// Runs of equal attributes, normalized: `location+length:{attributes}`.
    public static func runs(_ runs: [(range: NSRange, attributes: [AnyHashable: Any])]) -> String {
        runs.map { "\($0.range.location)+\($0.range.length):" + (describe($0.attributes) ?? "{}") }.joined(separator: "|")
    }
}

/// How many pixels changed inside the stroke's region and outside it.
public struct PixelChange: Equatable, Sendable {
    public var insideChanged: Int
    public var insideTotal: Int
    public var outsideChanged: Int
    public var outsideTotal: Int
    public init(insideChanged: Int, insideTotal: Int, outsideChanged: Int, outsideTotal: Int) {
        self.insideChanged = insideChanged; self.insideTotal = insideTotal; self.outsideChanged = outsideChanged; self.outsideTotal = outsideTotal
    }
    public var anyChange: Bool { insideChanged + outsideChanged > 0 }
    public var outsideFraction: Double { outsideTotal == 0 ? 0 : Double(outsideChanged) / Double(outsideTotal) }
}

public struct PixelRegion: Equatable, Sendable {
    public var x0: Int, y0: Int, x1: Int, y1: Int   // x1, y1 exclusive
    public init(x0: Int, y0: Int, x1: Int, y1: Int) { self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1 }
    func contains(_ x: Int, _ y: Int) -> Bool { x >= x0 && x < x1 && y >= y0 && y < y1 }
}

public enum PixelDiff {
    /// A pixel counts as changed when any color channel differs by more than `tolerance` (compression and
    /// font smoothing move values by a few). Both buffers are RGBA, 4 bytes a pixel; nil when they disagree on size.
    /// Pixels in `excluding` (the hover point's neighborhood) are not counted at all.
    public static func compare(before: [UInt8], after: [UInt8], width: Int, height: Int, region: PixelRegion,
                               excluding: PixelRegion? = nil, tolerance: Int = 8) -> PixelChange? {
        guard width > 0, height > 0, before.count == width * height * 4, after.count == before.count else { return nil }
        var inC = 0, inT = 0, outC = 0, outT = 0
        for y in 0..<height {
            for x in 0..<width {
                if let ex = excluding, ex.contains(x, y) { continue }
                let i = (y * width + x) * 4
                let d = max(abs(Int(before[i]) - Int(after[i])), abs(Int(before[i + 1]) - Int(after[i + 1])), abs(Int(before[i + 2]) - Int(after[i + 2])))
                if region.contains(x, y) { inT += 1; if d > tolerance { inC += 1 } } else { outT += 1; if d > tolerance { outC += 1 } }
            }
        }
        return PixelChange(insideChanged: inC, insideTotal: inT, outsideChanged: outC, outsideTotal: outT)
    }
}

/// Elements that changed on their own between two readings taken before the post (a clock, a spinner, a timer) are
/// noise, found by where they are in the tree and not by what they say: whatever they read afterwards is not evidence,
/// including a third value nobody has seen yet.
public enum ContentChange {
    /// Each element by its place (`0/2/1`, the child indexes down from the window) with what it shows.
    public static func entries(of tree: JSONValue) -> [String: String] {
        var out: [String: String] = [:]
        func walk(_ n: JSONValue, _ path: String) {
            guard case .object(let o) = n else { return }
            let states = (o["states"]?.array ?? []).compactMap(\.string).sorted().joined(separator: ",")
            out[path] = [o["role"]?.string ?? "", o["name"]?.string ?? o["title"]?.string ?? "", o["value"]?.string ?? "", states].joined(separator: "|")
            for (i, c) in (o["children"]?.array ?? []).enumerated() { walk(c, path + "/\(i)") }
        }
        walk(tree, "0")
        return out
    }

    /// Places that differ between the two baselines (or exist in only one).
    public static func noise(base1: JSONValue, base2: JSONValue) -> Set<String> {
        let a = entries(of: base1), b = entries(of: base2)
        return Set(Set(a.keys).union(b.keys).filter { a[$0] != b[$0] })
    }

    /// Whether anything outside the noise differs between the first baseline and now.
    public static func changed(base: [String: String], noise: Set<String>, after: JSONValue) -> Bool {
        let now = entries(of: after)
        return Set(base.keys).union(now.keys).contains { !noise.contains($0) && base[$0] != now[$0] }
    }
}

public struct DeliveryVerdict: Equatable, Sendable {
    public var verified: Bool
    /// `value_changed`, `selection_changed`, `focus_moved`, `attributes_changed`, `content_changed`, `window_changed`,
    /// `pixels_along_stroke`; or why not: `pixels_only`, `unpredicted_change`, `no_change`, `no_reading`.
    public var basis: String
    public init(verified: Bool, basis: String) { self.verified = verified; self.basis = basis }
}

public typealias ReadingPair = (before: ElementReading?, after: ElementReading?)

public enum DeliveryProof {
    /// A stroke needs this many changed pixels at least, scaled up with its length (`PointerPath.strokeMinimum`)...
    public static let minStrokePixels = 24
    /// ...and no more than this share of the rest of the window changing (a repaint is not a stroke).
    public static let maxOutsideFraction = 0.02

    /// What changed between two readings of one element, both of the target window. Nothing from another window counts.
    static func change(_ pair: ReadingPair, target: UInt32) -> Set<KeyEffect> {
        guard let b = pair.before, let a = pair.after, b.window == target, a.window == target else { return [] }
        var out: Set<KeyEffect> = []
        if b.identity != a.identity { out.insert(.focus) }
        else {
            if b.valueDigest != a.valueDigest || b.valueLength != a.valueLength { out.insert(.text) }
            if b.selectionLocation != a.selectionLocation || b.selectionLength != a.selectionLength { out.insert(.selection) }
            if b.attributesDigest != a.attributesDigest { out.insert(.attributes) }
        }
        return out
    }

    static func basis(_ e: KeyEffect) -> String {
        switch e {
        case .text: return "value_changed"
        case .selection: return "selection_changed"
        case .focus: return "focus_moved"
        case .attributes: return "attributes_changed"
        case .content: return "content_changed"
        case .window: return "window_changed"
        }
    }

    /// Keys, one step: proof is the change that step predicts, on the targeted element or the focused element (value,
    /// selection, attributes, focus), all inside the target window. A typed segment must also show its own characters.
    /// The window's content counts only where there is no text element to read (Calculator), and the window itself
    /// only for a shortcut that acts on the window (Save). An unrelated change does not count, and pixels never prove keys.
    public static func keys(target: UInt32, step: KeyStep, ref: ReadingPair, focus: ReadingPair, content: Bool?,
                            window: (before: WindowReading?, after: WindowReading?) = (nil, nil), pixels: PixelChange?) -> DeliveryVerdict {
        let focusIsText = (focus.before?.isText ?? false) || (ref.before?.isText ?? false)
        let expected = KeyPrediction.expected(step.chords, focusIsText: focusIsText)
        var seen = change(ref, target: target).union(change(focus, target: target))
        var wrongText = false
        // A typed segment proves itself only by appearing in the element it was typed into.
        if let typed = step.typed, seen.contains(.text) {
            func appears(_ p: ReadingPair) -> Bool {
                guard let b = p.before, let a = p.after, b.window == target, a.window == target, b.valueDigest != a.valueDigest else { return false }
                return a.value?.contains(typed) ?? false
            }
            if !(appears(ref) || appears(focus)) { seen.remove(.text); wrongText = true }
        }
        let windowChanged: Bool = {
            guard let b = window.before, let a = window.after else { return false }
            return b != a
        }()
        for e in [KeyEffect.text, .selection, .focus, .attributes] where expected.contains(e) && seen.contains(e) { return .init(verified: true, basis: basis(e)) }
        if expected.contains(.window), windowChanged { return .init(verified: true, basis: "window_changed") }
        if !focusIsText, expected.contains(.content), content == true { return .init(verified: true, basis: "content_changed") }
        if pixels?.anyChange == true { return .init(verified: false, basis: "pixels_only") }
        if !seen.isEmpty || wrongText || windowChanged || (focusIsText && content == true) { return .init(verified: false, basis: "unpredicted_change") }
        let read = ref.after != nil || focus.after != nil || content != nil
        return .init(verified: false, basis: read ? "no_change" : "no_reading")
    }

    /// Pointer: a change on an element of the target window (any: a press can do anything to its control), or, for a
    /// surface that draws and exposes nothing, pixels that changed along the stroke while the rest of the window stayed
    /// put. `minStroke` scales with the stroke's length.
    public static func pointer(target: UInt32, ref: ReadingPair, focus: ReadingPair, content: Bool?, pixels: PixelChange?, minStroke: Int = minStrokePixels) -> DeliveryVerdict {
        let seen = change(ref, target: target).union(change(focus, target: target))
        if let e = [KeyEffect.focus, .text, .selection, .attributes].first(where: { seen.contains($0) }) { return .init(verified: true, basis: basis(e)) }
        if content == true { return .init(verified: true, basis: "content_changed") }
        if let p = pixels {
            if p.insideChanged >= minStroke, p.outsideFraction <= maxOutsideFraction { return .init(verified: true, basis: "pixels_along_stroke") }
            if p.anyChange { return .init(verified: false, basis: "pixels_only") }
        }
        let read = ref.after != nil || focus.after != nil || content != nil || pixels != nil
        return .init(verified: false, basis: read ? "no_change" : "no_reading")
    }
}

// MARK: - Pointer geometry

public enum PointerPath {
    public static let maxSteps = 200

    /// Window-local points, top-left origin, in points. Inclusive of both ends.
    public static func line(from: CGPoint, to: CGPoint, steps: Int) -> [CGPoint] {
        let n = max(1, min(steps, maxSteps))
        return (0...n).map { i in
            let t = CGFloat(i) / CGFloat(n)
            return CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        }
    }

    /// Where a window-local point is on the screen, given the window's frame (screen coordinates, top-left origin).
    public static func screenPoint(local: CGPoint, frame: CGRect) -> CGPoint {
        CGPoint(x: frame.origin.x + local.x, y: frame.origin.y + local.y)
    }

    public static func inside(_ local: CGPoint, size: CGSize) -> Bool {
        local.x >= 0 && local.y >= 0 && local.x < size.width && local.y < size.height
    }

    /// The pixels a stroke through `path` can touch: its bounding box, grown by `margin` points, scaled to the
    /// capture's pixels per point and clipped to the capture.
    public static func region(path: [CGPoint], margin: CGFloat, scale: CGFloat, width: Int, height: Int) -> PixelRegion {
        guard let first = path.first else { return PixelRegion(x0: 0, y0: 0, x1: 0, y1: 0) }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in path { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
        func clip(_ v: CGFloat, _ hi: Int) -> Int { max(0, min(hi, Int(v.rounded()))) }
        return PixelRegion(x0: clip((minX - margin) * scale, width), y0: clip((minY - margin) * scale, height),
                           x1: clip((maxX + margin) * scale, width), y1: clip((maxY + margin) * scale, height))
    }

    /// The disc around the first point (where the hover left its brush outline or tint), as a box, for a drag.
    public static func hoverExclusion(path: [CGPoint], radius: CGFloat, scale: CGFloat, width: Int, height: Int) -> PixelRegion? {
        guard path.count > 1, let p = path.first else { return nil }
        return region(path: [p], margin: radius, scale: scale, width: width, height: height)
    }

    public static func length(_ path: [CGPoint]) -> CGFloat {
        zip(path, path.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    /// At least this many changed pixels for a stroke of this path: half a pixel column per pixel of length, never under 24.
    public static func strokeMinimum(path: [CGPoint], scale: CGFloat) -> Int {
        max(DeliveryProof.minStrokePixels, Int(length(path) * scale * 0.5))
    }
}
