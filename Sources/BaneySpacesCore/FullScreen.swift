import CoreGraphics
import Foundation

// Full screen, the part that decides things. No AppKit and no Accessibility: the app reads
// the facts (`Spaces.swift`, `Windows.swift`) and this file says what they mean, so every
// way a window can vanish around full screen is a unit test.
//
// Why windows vanished (2026-11-01, "things sometimes disappear when in full screen"):
// macOS puts a full-screen window on a macOS desktop of its own, where BaneySpaces can neither
// hide nor show it. A switch hides the windows of the workspace you leave. A window still in
// full screen when its app was hidden or its workspace left is on its own desktop, out of sight
// on the workspace you return to. Every way that happened came down to one of these:
//   1. The question "is it in full screen?" was answered by a size check on the window server's
//      bounds plus an Accessibility read that said "no" when the app didn't answer. A window in
//      Split View (half the screen), one that an app sizes differently in full screen, and one
//      whose app was busy with the transition all read "no".
//   2. After asking a window to leave, an app that stopped answering counted as "left".
//   3. A window that refused was carried only when the switch changed workspace, so moving one
//      from the overview hid a window that could not be hidden.
//   4. A window that entered full screen after the switch decided (a green button pressed while
//      a switch ran) was never looked at again.

/// What `behavior.fullscreen` does (spec/config.md).
public enum FullScreenMode: String, CaseIterable, Sendable {
    /// The green button and ⌃⌘F fill the window's own workspace. Never a macOS desktop.
    case baneyspaces
    /// macOS full screen, with a switch taking a window out of it first.
    case native

    public static let `default` = FullScreenMode.baneyspaces

    public init?(setting: String?) {
        guard let v = setting?.trimmingCharacters(in: .whitespaces).lowercased(), let m = FullScreenMode(rawValue: v) else { return nil }
        self = m
    }

    public static var usage: String { allCases.map(\.rawValue).joined(separator: "|") }
}

/// A fact that may not be known: an app that doesn't answer is not an app that said no.
public enum Answer: Equatable, Sendable {
    case yes, no, unknown
}

/// One full-screen desktop in the window server's list of Spaces (`CGSCopyManagedDisplaySpaces`,
/// type 4). `window` is the window that owns it; Split View puts a second window on the same
/// desktop. Read on macOS 27 on 2026-11-01: `type`, `fs_wid`, `pid` and `ManagedSpaceID` are all there.
public struct FullScreenSpace: Equatable, Sendable {
    public var space: Int
    public var display: String
    public var window: WindowID?
    public var pid: Int32?
    /// The display is showing this desktop right now.
    public var isCurrent: Bool

    public init(space: Int, display: String, window: WindowID?, pid: Int32?, isCurrent: Bool) {
        self.space = space
        self.display = display
        self.window = window
        self.pid = pid
        self.isCurrent = isCurrent
    }
}

public enum FullScreenSpaces {
    /// The window server's `type` of a full-screen desktop (0 is an ordinary one).
    public static let typeFullScreen = 4

    /// The full-screen desktops in `CGSCopyManagedDisplaySpaces`'s answer.
    public static func parse(_ displays: [[String: Any]]) -> [FullScreenSpace] {
        func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }
        var found: [FullScreenSpace] = []
        for d in displays {
            let key = (d["Display Identifier"] as? String) ?? ""
            let current = int((d["Current Space"] as? [String: Any])?["ManagedSpaceID"])
            for s in (d["Spaces"] as? [[String: Any]]) ?? [] {
                guard int(s["type"]) == typeFullScreen, let id = int(s["ManagedSpaceID"]) ?? int(s["id64"]) else { continue }
                found.append(FullScreenSpace(space: id, display: key, window: int(s["fs_wid"]).map { WindowID($0) },
                                             pid: int(s["pid"]).map { Int32($0) }, isCurrent: current == id))
            }
        }
        return found
    }

    /// Whether a window on `spaces` (its Space numbers, from `CGSCopySpacesForWindows`) is on one
    /// of the full-screen desktops. Unknown when the window server wouldn't say.
    public static func contains(_ windowSpaces: [Int]?, in fullScreen: [FullScreenSpace]) -> Answer {
        guard let windowSpaces else { return .unknown }
        let ids = Set(fullScreen.map(\.space))
        return windowSpaces.contains(where: ids.contains) ? .yes : .no
    }

    /// Windows that own a full-screen desktop but that the model has never heard of: they live on
    /// a desktop Accessibility can't list from here, so nothing can hide, show or even find them.
    public static func missing(_ fullScreen: [FullScreenSpace], known: Set<WindowID>) -> [FullScreenSpace] {
        fullScreen.filter { $0.window.map { !known.contains($0) } ?? false }
    }
}

/// What was learned about one window, from three independent sources.
public struct FullScreenEvidence: Equatable, Sendable {
    /// The window server puts the window on a full-screen desktop. It needs no help from the app.
    public var desktop: Answer
    /// The app's own `AXFullScreen`.
    public var attribute: Answer
    /// The window server's bounds equal a screen. Only a hint: a window in Split View is half a
    /// screen, and a window that isn't in full screen can be exactly this size.
    public var screenSized: Answer

    public init(desktop: Answer, attribute: Answer, screenSized: Answer) {
        self.desktop = desktop
        self.attribute = attribute
        self.screenSized = screenSized
    }
}

public enum FullScreenCall: Equatable, Sendable {
    case inFullScreen(String)
    case notInFullScreen(String)
    /// Neither source can say and the size is suspicious. Treated as in full screen until proven out.
    case cannotTell(String)

    public var isOut: Bool { if case .notInFullScreen = self { return true } else { return false } }
    /// Must be asked to leave before its workspace can be left: in full screen, or not provably out.
    public var needsLeaving: Bool { !isOut }

    public var reason: String {
        switch self {
        case let .inFullScreen(r), let .notInFullScreen(r), let .cannotTell(r): return r
        }
    }

    public var word: String {
        switch self {
        case .inFullScreen: return "in-full-screen"
        case .notInFullScreen: return "not-in-full-screen"
        case .cannotTell: return "cannot-tell"
        }
    }
}

public enum FullScreenDecision {
    /// The window server's desktop list is authoritative when it answers; the app's attribute can
    /// only add (a window entering full screen), never remove, and a missing answer is never a "no".
    public static func call(_ e: FullScreenEvidence) -> FullScreenCall {
        if e.desktop == .yes { return .inFullScreen("on a full-screen desktop") }
        if e.attribute == .yes { return .inFullScreen("the app says AXFullScreen is true") }
        if e.desktop == .no {
            return .notInFullScreen(e.attribute == .no ? "on no full-screen desktop and AXFullScreen is false"
                                                       : "on no full-screen desktop (the app didn't answer AXFullScreen)")
        }
        // The window server didn't say.
        if e.attribute == .no { return .notInFullScreen("AXFullScreen is false") }
        if e.screenSized == .yes { return .cannotTell("no answer from the window server or the app, and the window is screen-sized") }
        return .notInFullScreen("no answer from the window server or the app, and the window is not screen-sized")
    }
}

/// Windows that would not leave full screen. They are carried to the workspace being shown instead
/// of hidden, because a window in full screen cannot be hidden. Remembered so a switch doesn't
/// stall 5 s on each of them again; forgotten when one is seen out of full screen.
public struct RefusedFullScreen: Equatable {
    /// How long a refusal is believed. Asking a Chromium video again costs a stall, but an app that
    /// was only busy deserves another try.
    public static let memory: TimeInterval = 600
    private var since: [WindowID: Date] = [:]

    public init() {}

    public mutating func refuse(_ id: WindowID, now: Date) { since[id] = now }
    public mutating func forget(_ id: WindowID) { since[id] = nil }
    public mutating func keep(alive: Set<WindowID>) { since = since.filter { alive.contains($0.key) } }
    public func contains(_ id: WindowID, now: Date) -> Bool {
        since[id].map { now.timeIntervalSince($0) < Self.memory } ?? false
    }
    public var ids: Set<WindowID> { Set(since.keys) }
}

/// What a switch does about the windows it is about to hide that are in full screen.
public struct FullScreenSwitch: Equatable {
    /// Asked to leave full screen before anything is hidden.
    public var ask: [WindowID]
    /// Would not leave before: they come along to the workspace being shown instead of being hidden.
    public var carry: [WindowID]

    /// `calls` has an entry for every window in `hide` that was looked at. Anything that is not
    /// provably out of full screen is asked, or carried if it has refused before. Carried even
    /// when the switch stays on the same workspace (a move made from the overview): a window that
    /// cannot be hidden must not be sent where it would have to be.
    public static func plan(hide: [WindowID], calls: [WindowID: FullScreenCall], refused: RefusedFullScreen, now: Date) -> FullScreenSwitch {
        var ask: [WindowID] = [], carry: [WindowID] = []
        for id in hide {
            guard let call = calls[id], call.needsLeaving else { continue }
            if refused.contains(id, now: now) { carry.append(id) } else { ask.append(id) }
        }
        return FullScreenSwitch(ask: ask, carry: carry)
    }

    /// After asking: a window is out only when it is provably out. One whose app stopped answering
    /// during the transition has not left; it is treated as refusing (and carried), never as gone.
    public static func refused(asked: [WindowID], after calls: [WindowID: FullScreenCall]) -> [WindowID] {
        asked.filter { !(calls[$0]?.isOut ?? false) }
    }
}

/// One window as the audit sees it after a switch.
public struct WindowObservation: Equatable {
    public var id: WindowID
    public var app: String
    public var workspace: Int
    /// The window server is drawing it.
    public var onScreen: Bool
    /// BaneySpaces holds a parked frame for it.
    public var parked: Bool
    /// Its frame is at the hiding spot (mostly off every screen).
    public var atHidingSpot: Bool
    public var appHidden: Bool
    public var minimized: Bool
    /// On a full-screen desktop (`FullScreenSpaces.contains`).
    public var onFullScreenDesktop: Bool
    /// The window server still has the window, off screen, and the app doesn't list it: closed but kept.
    public var closedButKept: Bool

    public init(id: WindowID, app: String, workspace: Int, onScreen: Bool, parked: Bool, appHidden: Bool,
                atHidingSpot: Bool = false, minimized: Bool = false, onFullScreenDesktop: Bool = false, closedButKept: Bool = false) {
        self.id = id
        self.app = app
        self.workspace = workspace
        self.onScreen = onScreen
        self.parked = parked
        self.atHidingSpot = atHidingSpot
        self.appHidden = appHidden
        self.minimized = minimized
        self.onFullScreenDesktop = onFullScreenDesktop
        self.closedButKept = closedButKept
    }
}

/// A window that is where nobody can get it. Each finding names the window, so trace.log says which.
public struct VanishFinding: Equatable {
    public enum Kind: String {
        /// On a workspace that is not shown, yet on a full-screen desktop: hiding it did nothing, and
        /// it stays on its own desktop, out of sight on the workspace it belongs to.
        case hiddenButInFullScreen = "hidden-but-in-full-screen"
        /// On a workspace that is not shown, drawn on screen, not parked, its app not hidden.
        case inSightOnHiddenWorkspace = "in-sight-on-hidden-workspace"
        /// On a shown workspace but sitting at the hiding spot.
        case shownButParked = "shown-but-parked"
        /// On a shown workspace, not drawn, not minimized, not on a full-screen desktop: its app may be hidden.
        case shownButNotVisible = "shown-but-not-visible"
        /// On a hidden workspace, not drawn, not parked, its app not hidden: nothing of ours put it away.
        case neitherShownNorHidden = "neither-shown-nor-hidden"
    }
    public var id: WindowID
    public var app: String
    public var workspace: Int
    public var kind: Kind

    public var line: String { "window=\(id) app=\(app) workspace=\(workspace) \(kind.rawValue)" }
}

public enum VanishAudit {
    /// Every window that is neither shown where it belongs nor hidden by BaneySpaces. A window on a
    /// shown workspace is fine drawn on screen, minimized, or on its full-screen desktop; one on a
    /// hidden workspace is fine parked, with its app hidden, minimized, or closed-but-kept.
    public static func findings(_ windows: [WindowObservation], shown: Set<Int>) -> [VanishFinding] {
        var out: [VanishFinding] = []
        for w in windows where !w.closedButKept {
            func add(_ k: VanishFinding.Kind) { out.append(VanishFinding(id: w.id, app: w.app, workspace: w.workspace, kind: k)) }
            if shown.contains(w.workspace) {
                if w.minimized || w.onFullScreenDesktop { continue }
                if w.atHidingSpot { add(.shownButParked) } else if !w.onScreen { add(.shownButNotVisible) }
            } else {
                if w.onFullScreenDesktop { add(.hiddenButInFullScreen); continue }
                if w.minimized || w.parked || w.appHidden || w.atHidingSpot { continue }
                add(w.onScreen ? .inSightOnHiddenWorkspace : .neitherShownNorHidden)
            }
        }
        return out.sorted { $0.id < $1.id }
    }

    /// The findings a full-screen event can explain and a repair can fix. Others are only traced.
    public static func repairable(_ findings: [VanishFinding]) -> [VanishFinding] {
        findings.filter { $0.kind == .hiddenButInFullScreen }
    }
}

/// What the window under a green-button click, or the key ⌃⌘F, should do.
public enum FullScreenRequest: Equatable {
    /// Leave the event to macOS.
    case passThrough
    /// Fill the window's workspace (BaneySpaces full screen).
    case fill
    /// Press the button for macOS full screen (an Option-click).
    case native
}

public enum FullScreenRoute {
    public struct Modifiers: Equatable {
        public var control = false, command = false, option = false, shift = false
        public init(control: Bool = false, command: Bool = false, option: Bool = false, shift: Bool = false) {
            self.control = control; self.command = command; self.option = option; self.shift = shift
        }
    }

    /// ⌃⌘F: the key code of F.
    public static let keyF = 3

    public static func isFullScreenKey(code: Int64, _ m: Modifiers) -> Bool {
        code == Int64(keyF) && m.control && m.command && !m.option && !m.shift
    }

    /// Whether a fill may act on a window: one on a workspace that is in sight, or one no scan has
    /// placed yet (it is in sight, or the person could not have used its button). A window out of
    /// sight on another workspace is left alone.
    public static func mayFill(workspace: Int?, shown: Set<Int>) -> Bool {
        workspace.map(shown.contains) ?? true
    }

    public static func key(mode: FullScreenMode, windowInNativeFullScreen: Bool) -> FullScreenRequest {
        mode == .baneyspaces && !windowInNativeFullScreen ? .fill : .passThrough
    }

    /// A click on the green button. In macOS full screen the button leaves it, whatever the mode.
    /// Option asks for macOS full screen; any other modifier is not a plain click.
    public static func click(mode: FullScreenMode, _ m: Modifiers, windowInNativeFullScreen: Bool) -> FullScreenRequest {
        guard mode == .baneyspaces, !windowInNativeFullScreen else { return .passThrough }
        if m.control || m.command || m.shift { return .passThrough }
        return m.option ? .native : .fill
    }
}

/// Windows BaneySpaces has filled, with the frame each had before. Filling is an ordinary resize:
/// the window stays on its workspace, so switching away parks it and switching back restores it,
/// still filled, exactly as for any window.
public struct FilledWindows: Codable, Equatable {
    public struct Entry: Codable, Equatable {
        public var before: CGRect
        /// The frame the window really took (an app can snap to a grid, so not always the target).
        public var fill: CGRect
    }
    public enum Toggle: Equatable {
        case fill(from: CGRect, to: CGRect)
        case restore(to: CGRect)
    }

    public static let tolerance: CGFloat = 6
    public private(set) var entries: [WindowID: Entry] = [:]

    public init() {}

    private static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    public func isFilled(_ id: WindowID) -> Bool { entries[id] != nil }

    /// `current` is the window's frame, `area` what filling means now (the screen's visible frame).
    /// A window the person resized since is not "filled" any more: the key fills it again.
    /// A window that already fills the area without our record shrinks to the middle three quarters.
    public mutating func toggle(_ id: WindowID, current: CGRect, area: CGRect, screens: [CGRect]) -> Toggle {
        if let e = entries[id] {
            if Self.near(current, e.fill) {
                entries[id] = nil
                return .restore(to: Geometry.restoreFrame(saved: e.before, size: e.before.size, screens: screens))
            }
            entries[id] = nil
        }
        if Self.near(current, area) {
            let inner = area.insetBy(dx: area.width / 8, dy: area.height / 8).integral
            return .restore(to: inner)
        }
        entries[id] = Entry(before: current, fill: area)
        return .fill(from: current, to: area)
    }

    /// The frame the window took, read back after the fill.
    public mutating func settled(_ id: WindowID, actual: CGRect) {
        guard var e = entries[id] else { return }
        e.fill = actual
        entries[id] = e
    }

    /// A display changed under a filled window: the frame to fill now, or nil if it isn't filled
    /// (or already fits).
    public mutating func refit(_ id: WindowID, current: CGRect, area: CGRect) -> CGRect? {
        guard var e = entries[id], Self.near(current, e.fill), !Self.near(e.fill, area) else { return nil }
        e.fill = area
        entries[id] = e
        return area
    }

    public mutating func forget(_ id: WindowID) { entries[id] = nil }
    public mutating func keep(alive: Set<WindowID>) { entries = entries.filter { alive.contains($0.key) } }

    public static func load(from url: URL) -> FilledWindows {
        guard let data = try? Data(contentsOf: url), let v = try? JSONDecoder().decode(FilledWindows.self, from: data) else { return FilledWindows() }
        return v
    }

    public func save(to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
