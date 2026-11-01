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

    /// The full-screen desktops in `CGSCopyManagedDisplaySpaces`'s answer, or nil when the answer is not
    /// in the shape this was written against: at least one display, each with a `Spaces` array whose every
    /// entry has a numeric `type` and `ManagedSpaceID`, and each full-screen one a `fs_wid`. A macOS point
    /// release that renames a key must never read as "no full-screen desktops": the caller stops acting
    /// on the list and falls back to Accessibility.
    public static func parse(_ displays: [[String: Any]]) -> [FullScreenSpace]? {
        func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }
        guard !displays.isEmpty else { return nil }
        var found: [FullScreenSpace] = []
        for d in displays {
            guard let spaces = d["Spaces"] as? [[String: Any]] else { return nil }
            let key = (d["Display Identifier"] as? String) ?? ""
            let current = int((d["Current Space"] as? [String: Any])?["ManagedSpaceID"])
            for s in spaces {
                guard let type = int(s["type"]), let id = int(s["ManagedSpaceID"]) else { return nil }
                guard type == typeFullScreen else { continue }
                guard let window = int(s["fs_wid"]) else { return nil }
                found.append(FullScreenSpace(space: id, display: key, window: WindowID(truncatingIfNeeded: window),
                                             pid: int(s["pid"]).map { Int32(truncatingIfNeeded: $0) }, isCurrent: current == id))
            }
        }
        return found
    }

    /// Whether a window on `windowSpaces` (its Space numbers, from `CGSCopySpacesForWindows`) is on a
    /// full-screen desktop. The window that owns the desktop (`fs_wid`) is, whatever else is reported;
    /// any other window must be on full-screen desktops only, so a window that an app assigns to all
    /// desktops is not taken for one in full screen. Unknown when the window server wouldn't say.
    public static func contains(_ windowSpaces: [Int]?, window: WindowID? = nil, in fullScreen: [FullScreenSpace]) -> Answer {
        guard let windowSpaces else { return .unknown }
        let ids = Set(fullScreen.map(\.space))
        guard windowSpaces.contains(where: ids.contains) else { return .no }
        if let window, fullScreen.contains(where: { $0.window == window }) { return .yes }
        return windowSpaces.allSatisfy(ids.contains) ? .yes : .no
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

public extension FullScreenEvidence {
    /// Whether the app's own `AXFullScreen` is read for a window a switch is about to hide. With a readable window
    /// server list, only where it can add something. With an unreadable one, always: that read is then all there is,
    /// and a Split View window is half a screen, so size cannot rule anything out.
    static func shouldReadAttribute(desktopsReadable: Bool, desktop: Answer, screenSized: Answer, seenInFullScreen: Bool) -> Bool {
        !desktopsReadable || desktop != .no || screenSized == .yes || seenInFullScreen
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
                                                       : "on no full-screen desktop (AXFullScreen unread or unanswered)")
        }
        // The window server didn't say.
        if e.attribute == .no { return .notInFullScreen("AXFullScreen is false") }
        // Nobody can say. A window is never hidden on that: Split View windows are half a screen, so size cannot clear it.
        return .cannotTell(e.screenSized == .yes ? "no answer from the window server or the app, and the window is screen-sized"
                                                 : "no answer from the window server or the app")
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
    /// `unaskable` are windows in full screen that have no Accessibility handle (known to the window server alone):
    /// there is nothing to ask, so they are carried at once and never hidden.
    public static func plan(hide: [WindowID], calls: [WindowID: FullScreenCall], refused: RefusedFullScreen, now: Date,
                            unaskable: Set<WindowID> = []) -> FullScreenSwitch {
        var ask: [WindowID] = [], carry: [WindowID] = []
        for id in hide {
            guard let call = calls[id], call.needsLeaving else { continue }
            if unaskable.contains(id) || refused.contains(id, now: now) { carry.append(id) } else { ask.append(id) }
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
    /// `displayOnFullScreenDesktop`: the display is showing a full-screen desktop now, so the windows of
    /// its workspace that live on the ordinary desktop are not on screen, and that is not a loss.
    public static func findings(_ windows: [WindowObservation], shown: Set<Int>, displayOnFullScreenDesktop: Bool = false) -> [VanishFinding] {
        var out: [VanishFinding] = []
        for w in windows where !w.closedButKept {
            func add(_ k: VanishFinding.Kind) { out.append(VanishFinding(id: w.id, app: w.app, workspace: w.workspace, kind: k)) }
            if shown.contains(w.workspace) {
                if w.minimized || w.onFullScreenDesktop { continue }
                if w.atHidingSpot { add(.shownButParked) } else if !w.onScreen && !displayOnFullScreenDesktop { add(.shownButNotVisible) }
            } else {
                if w.onFullScreenDesktop { add(.hiddenButInFullScreen); continue }
                if w.minimized || w.parked || w.appHidden || w.atHidingSpot { continue }
                add(w.onScreen ? .inSightOnHiddenWorkspace : .neitherShownNorHidden)
            }
        }
        return out.sorted { $0.id < $1.id }
    }

    /// The findings a full-screen event can explain and a repair can fix. A window on a hidden workspace
    /// that is on a full-screen desktop is asked to leave. One that left full screen on its own and is
    /// now in plain sight on a hidden workspace is put away again at once, after a change of desktop
    /// (or a switch a full-screen window was part of): that is the moment it appears. Others are only traced.
    public static func repairable(_ findings: [VanishFinding], afterDesktopChange: Bool = false) -> [VanishFinding] {
        findings.filter { $0.kind == .hiddenButInFullScreen || (afterDesktopChange && $0.kind == .inSightOnHiddenWorkspace) }
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

    public enum Fill: Equatable {
        case fill(from: CGRect, to: CGRect)
        /// Already recorded as filled: nothing to do but keep the record.
        case unchanged
    }

    /// One-way: fills and records, never restores. For a window that has just left macOS full screen.
    public mutating func fill(_ id: WindowID, current: CGRect, area: CGRect) -> Fill {
        if entries[id] != nil { return .unchanged }
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

/// Windows already in macOS full screen when the fixed build starts move into BaneySpaces full screen
/// (Donovan, 2026-11-01: Word, Helium and Obsidian full screen on workspace 1, every click on the dock
/// tile playing macOS's sideways slide). Only in `baneyspaces` mode.
public enum FullScreenMigration {
    public struct Plan: Equatable {
        /// On the desktop being shown: Accessibility lists them, so they are asked to leave now.
        public var now: [WindowID]
        /// On desktops no scan can see: the app is brought forward, which shows its desktop, then asked. In order.
        public var visit: [FullScreenSpace]
    }

    /// `listed` is what Accessibility listed. A full-screen desktop's window that it listed is asked
    /// to leave where it is; one it did not is visited, current one first so nothing slides for it.
    /// It happens once (`alreadyMigrated`): a window in native full screen at any later start is there on
    /// purpose, and so is any window in `chosen` (an Option-click on the green button).
    public static func plan(mode: FullScreenMode, desktops: [FullScreenSpace], listed: Set<WindowID>,
                            alreadyMigrated: Bool = false, chosen: Set<WindowID> = []) -> Plan {
        guard mode == .baneyspaces, !alreadyMigrated else { return Plan(now: [], visit: []) }
        var now: [WindowID] = [], visit: [FullScreenSpace] = []
        for d in desktops {
            guard let w = d.window, !chosen.contains(w) else { continue }
            if listed.contains(w) { now.append(w) } else { visit.append(d) }
        }
        return Plan(now: now, visit: visit.sorted { $0.isCurrent && !$1.isCurrent })
    }
}

/// Windows the person sent to macOS full screen on purpose (an Option-click on the green button), by
/// window and owning process so a number reused later is not mistaken for one. Kept across restarts.
public struct NativeChoices: Codable, Equatable {
    public private(set) var pids: [WindowID: Int32] = [:]
    public init() {}
    public mutating func note(_ id: WindowID, pid: Int32) { pids[id] = pid }
    public func contains(_ id: WindowID, pid: Int32?) -> Bool { pids[id].map { pid == nil || $0 == pid } ?? false }
    public var ids: Set<WindowID> { Set(pids.keys) }
    public mutating func keep(alive: Set<WindowID>) { pids = pids.filter { alive.contains($0.key) } }
    public static func load(from url: URL) -> NativeChoices {
        guard let d = try? Data(contentsOf: url), let v = try? JSONDecoder().decode(NativeChoices.self, from: d) else { return NativeChoices() }
        return v
    }
    public func save(to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let d = try? JSONEncoder().encode(self) else { return }
        try? d.write(to: url, options: .atomic)
    }
}

/// macOS slides between desktops for about 0.7 s. A window asked to leave full screen mid-slide
/// shrinks while another slides in over it (the recording of 2026-11-01, 11:56), so nothing is asked
/// until the slide is over.
public struct SpaceTransition: Equatable {
    /// How long after the last change of desktop one is still taken to be in flight.
    public static let duration: TimeInterval = 1.0
    public private(set) var lastChange = Date.distantPast

    public init() {}

    public mutating func changed(at now: Date) { lastChange = now }

    /// Seconds to wait before a window may be asked to leave full screen; 0 when none is in flight.
    public func wait(now: Date) -> TimeInterval { max(0, lastChange.addingTimeInterval(Self.duration).timeIntervalSince(now)) }
}

/// One step of asking windows to leave full screen, decided from what is known now. The app calls it on
/// a timer; nothing in it touches a window.
public enum FullScreenLeave {
    public enum Step: Equatable {
        /// Every window asked is provably out.
        case done
        /// Wait; ask again shortly.
        case wait
        /// Press the green button of these windows, once (the app ignored the request).
        case press([WindowID])
        /// The hard deadline passed: these are carried, not hidden.
        case refused([WindowID])
    }

    /// How long a window gets before its green button is pressed, and the hard deadline for the whole ask.
    public static let pressAfter: TimeInterval = 0.8
    public static let deadline: TimeInterval = 5

    /// `transitionWait` is `SpaceTransition.wait`: nothing is pressed while a desktop change is in flight,
    /// and only a window that positively reports full screen is pressed (never one nobody can read).
    /// `elapsed` runs from the start of the whole ask, including any wait for a desktop change before the
    /// request went out, and is never extended: the deadline is absolute. `sinceAsk` is the time since the request
    /// itself (the button is pressed 0.8 s after it).
    public static func step(asked: [WindowID], elapsed: TimeInterval, sinceAsk: TimeInterval? = nil, transitionWait: TimeInterval,
                            calls: [WindowID: FullScreenCall], evidence: [WindowID: FullScreenEvidence], pressed: Bool) -> Step {
        let notOut = asked.filter { !(calls[$0]?.isOut ?? false) }
        if notOut.isEmpty { return .done }
        if elapsed >= deadline { return .refused(notOut) }
        if transitionWait > 0 || pressed || (sinceAsk ?? elapsed) < pressAfter { return .wait }
        let sure = notOut.filter { id in
            guard let e = evidence[id] else { return false }
            return e.desktop == .yes || e.attribute == .yes
        }
        return sure.isEmpty ? .wait : .press(sure)
    }
}

/// What a switch does about full screen, as one flow the app and the tests both run: the plan, the
/// windows carried, then the outcome of asking.
public enum FullScreenFlow {
    public struct Begin {
        public var plan: SwitchPlan
        public var ask: [WindowID]
        public var carried: [WindowID]
    }

    /// `plan` is `model.switchTo(n)`. `calls` reads the windows being hidden. Refusals seen out are forgotten;
    /// windows that refused before are carried to `n` (the model is changed) and the plan made again.
    public static func begin(plan: SwitchPlan, model: inout Workspaces, to n: Int, refused: inout RefusedFullScreen, now: Date,
                             unaskable: Set<WindowID> = [], calls read: ([WindowID]) -> [WindowID: FullScreenCall]) -> Begin {
        let calls = read(plan.hide)
        for (id, call) in calls where call.isOut { refused.forget(id) }
        let p = FullScreenSwitch.plan(hide: plan.hide, calls: calls, refused: refused, now: now, unaskable: unaskable)
        for id in p.carry { model.assign(id, to: n, focus: false) }
        return Begin(plan: p.carry.isEmpty ? plan : model.switchTo(n), ask: p.ask, carried: p.carry)
    }

    /// After asking: those that did not provably leave are carried to `n`. Returns the plan to apply and the refusals.
    public static func complete(model: inout Workspaces, to n: Int, asked: [WindowID], after: [WindowID: FullScreenCall],
                                refused: inout RefusedFullScreen, now: Date) -> (plan: SwitchPlan, refused: [WindowID]) {
        let no = FullScreenSwitch.refused(asked: asked, after: after)
        for id in asked where !no.contains(id) { refused.forget(id) }
        for id in no {
            refused.refuse(id, now: now)
            model.assign(id, to: n, focus: false)
        }
        return (model.switchTo(n), no)
    }
}

/// A window's traffic-light corner, in Accessibility coordinates. The green button is the third light:
/// about 14 to 70 pt across and 34 pt down on macOS 26 and 27. The zone is generous, because it only
/// decides whether to look closer.
public struct ClickZones {
    public struct Entry: Equatable {
        public var id: WindowID
        public var pid: Int32
        public var frame: CGRect
        /// A window of a regular app that a scan lists. Anything else on screen (BaneySpaces' own panels, Spotlight,
        /// a menu-extra popover) is in the list too, so that what covers a button is never mistaken for the window.
        public var regular: Bool
        public init(id: WindowID, pid: Int32, frame: CGRect, regular: Bool = true) { self.id = id; self.pid = pid; self.frame = frame; self.regular = regular }
    }

    public static let width: CGFloat = 110
    public static let height: CGFloat = 56

    /// Every on-screen window, front to back, as the window server lists them.
    public var windows: [Entry]
    public init(_ windows: [Entry] = []) { self.windows = windows }

    public static func zone(of w: Entry) -> CGRect { CGRect(x: w.frame.minX, y: w.frame.minY, width: width, height: height) }

    /// The topmost window under `p`, if `p` is in its traffic-light zone. Nil for every other point,
    /// without touching anything else.
    public func candidate(at p: CGPoint) -> Entry? {
        guard let top = windows.first(where: { $0.frame.contains(p) }), top.regular else { return nil }
        return Self.zone(of: top).contains(p) ? top : nil
    }
}

/// The decision about one click, with the Accessibility look injected so a test can count it.
public enum ClickFilter {
    /// `look` is the AX hit test (slow, bounded); it runs only for a point in a window's traffic-light zone.
    public static func request(at p: CGPoint, zones: ClickZones, look: (ClickZones.Entry) -> Bool) -> ClickZones.Entry? {
        guard let w = zones.candidate(at: p), look(w) else { return nil }
        return w
    }
}

/// A swallowed press holds its release (by the event number the press had), and a release anywhere but on
/// the button cancels. Keys: a swallowed F is released by keycode, whatever modifiers are held then.
public struct PressPairing: Equatable {
    public private(set) var downNumber: Int64?
    public private(set) var keyArmed = false
    public init() {}

    public mutating func armMouse(_ number: Int64) { downNumber = number }
    public mutating func armKey() { keyArmed = true }
    public mutating func reset() { downNumber = nil; keyArmed = false }

    public enum Release: Equatable { case pass, swallowAndAct, swallowAndCancel }

    /// A mouse release: ours when its number matches; it acts only if it is still on the button.
    public mutating func mouseUp(number: Int64, onButton: Bool) -> Release {
        guard let d = downNumber, d == number else { return .pass }
        downNumber = nil
        return onButton ? .swallowAndAct : .swallowAndCancel
    }

    /// A key release (or repeat) of F: swallowed whenever its press was.
    public mutating func keyUp() -> Bool {
        defer { keyArmed = false }
        return keyArmed
    }
}

// MARK: Windows the dock must keep listing

/// What the window server says about one app window: all it has to say when Accessibility cannot.
public struct ServerWindowInfo: Equatable {
    public var id: WindowID
    public var pid: Int32
    public var app: String
    public var title: String
    public var bounds: CGRect
    public var onScreen: Bool
    public init(id: WindowID, pid: Int32, app: String, title: String, bounds: CGRect, onScreen: Bool) {
        self.id = id; self.pid = pid; self.app = app; self.title = title; self.bounds = bounds; self.onScreen = onScreen
    }
}

/// A window listed from the window server alone.
public struct ServerListing: Equatable {
    public enum Why: String { case fullScreen = "full screen", notResponding = "not responding" }
    public var id: WindowID
    public var pid: Int32
    public var app: String
    public var title: String
    public var why: Why
}

public enum ServerListings {
    /// Smaller than this is a helper, not a window a person has.
    public static let minWidth: CGFloat = 120, minHeight: CGFloat = 80

    /// Windows with no Accessibility handle that still belong in the model (Donovan, 2026-11-01: "full
    /// screen apps keep disappearing from the dock"):
    /// - a window on a macOS full-screen desktop: its desktop is not the one Accessibility is reading, so no
    ///   scan lists it, but it is not closed, gone, unplaced or dormant;
    /// - a window of an app whose Accessibility doesn't answer: the window server knows its owner, number,
    ///   bounds and often title. One the model already knows stays; one it doesn't is listed only if it is
    ///   on screen and big enough to be a window.
    /// `withHandle` are windows the app lists (or listed before): they are not repeated here.
    public static func decide(info: [ServerWindowInfo], withHandle: Set<WindowID>, silentApps: Set<Int32>,
                              fullScreenWindows: Set<WindowID>, known: Set<WindowID>) -> [ServerListing] {
        var out: [ServerListing] = []
        for w in info where !withHandle.contains(w.id) {
            if fullScreenWindows.contains(w.id) {
                out.append(ServerListing(id: w.id, pid: w.pid, app: w.app, title: w.title, why: .fullScreen))
            } else if silentApps.contains(w.pid), known.contains(w.id) || (w.onScreen && w.bounds.width >= minWidth && w.bounds.height >= minHeight) {
                out.append(ServerListing(id: w.id, pid: w.pid, app: w.app, title: w.title, why: .notResponding))
            }
        }
        return out.sorted { $0.id < $1.id }
    }

    /// How a listing reads in the dock, the overview and ⌘Tab: a small badge before the title.
    public static func badge(_ why: ServerListing.Why?) -> String {
        switch why {
        case .fullScreen?: return "⤢ "
        case .notResponding?: return "◌ "
        case nil: return ""
        }
    }
}

public enum ClosedWindows {
    /// Known windows that their app closed but keeps (Ghostty keeps every one; a tab behind another tab is
    /// one): the app answered and didn't list them, they're off screen, and they're on no macOS desktop or on
    /// one being shown. A window the window server holds on a full-screen desktop is never one: Accessibility
    /// can't see it from here, and that is all.
    public static func find(candidates: Set<WindowID>, listed: Set<WindowID>, answered: Set<Int32>, offscreen: [WindowID: Int32],
                            heldByFullScreen: Set<WindowID>, onNoOtherDesktop: (WindowID) -> Bool) -> Set<WindowID> {
        Set(candidates.filter { id in
            guard !listed.contains(id), !heldByFullScreen.contains(id), let pid = offscreen[id], answered.contains(pid) else { return false }
            return onNoOtherDesktop(id)
        })
    }
}
