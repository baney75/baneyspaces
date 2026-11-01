import CoreGraphics

public typealias WindowID = UInt32
/// A display, by its UUID: the same screen keeps it across sleep, reconnects and rearranging.
public typealias DisplayKey = String

/// What a workspace switch has to do to real windows.
public struct SwitchPlan: Equatable {
    public var hide: [WindowID]
    public var show: [WindowID]
    /// The window to focus after the switch, or nil when the workspace is empty.
    public var focus: WindowID?
    /// The display the workspace went to, when there's more than one: its windows that sit on
    /// another display move there.
    public var display: DisplayKey?

    public init(hide: [WindowID], show: [WindowID], focus: WindowID?, display: DisplayKey? = nil) {
        self.hide = hide
        self.show = show
        self.focus = focus
        self.display = display
    }
}

/// Nine workspaces and which window lives on each. Windows are identified by their
/// WindowServer number, which stays the same for the life of the window.
///
/// Each display shows a workspace of its own, as in AeroSpace. `current` is the one on the
/// display you're working on; ⌘N changes only that display, or, when N is already showing on
/// another display, goes there. With one display it's the plain nine workspaces.
public struct Workspaces: Codable, Equatable {
    public static let range = 1...9

    public private(set) var current = 1
    /// The workspace on each display. Empty until the displays are known (one display, then).
    public private(set) var shown: [DisplayKey: Int] = [:]
    /// The display `current` is on.
    public private(set) var focusedDisplay: DisplayKey?
    /// The displays connected, the main one first.
    public private(set) var order: [DisplayKey] = []
    /// What each display showed last, so one that comes back shows it again.
    private var lastShown: [DisplayKey: Int] = [:]
    /// Workspaces a display never gets on its own (the agent workspace).
    public var reserved: Set<Int> = []
    public private(set) var home: [WindowID: Int] = [:]
    /// The last window focused on each workspace, so coming back lands where you left off.
    public private(set) var lastFocused: [Int: WindowID] = [:]
    /// R-D2: windows that live with another window (an emulator's toolbar and extended controls),
    /// by the window they follow. They have a workspace, so a switch hides and shows them with it,
    /// but they are not windows of their own (R-D3): `windows(on:)` leaves them out.
    public private(set) var companionOf: [WindowID: WindowID] = [:]

    // The companion links are rebuilt by every scan; they are not saved.
    private enum CodingKeys: String, CodingKey {
        case current, shown, focusedDisplay, order, lastShown, reserved, home, lastFocused
    }

    public init() {}

    /// Updates the model. `seen` is what Accessibility listed just now; `alive` is every window the
    /// WindowServer still has. A window that is alive but went unlisted (a busy app, another macOS
    /// desktop) keeps its place. A window seen for the first time joins the current workspace,
    /// since that is where it appeared. Returns the newcomers.
    /// `on` says which display a newcomer appeared on: it joins that display's workspace.
    @discardableResult
    public mutating func sync(seen: [WindowID], alive: Set<WindowID>, on display: [WindowID: DisplayKey] = [:]) -> [WindowID] {
        home = home.filter { alive.contains($0.key) }
        companionOf = companionOf.filter { home[$0.key] != nil && home[$0.value] != nil }
        lastFocused = lastFocused.filter { alive.contains($0.value) && home[$0.value] == $0.key }
        var added: [WindowID] = []
        for id in seen where home[id] == nil && alive.contains(id) {
            home[id] = display[id].flatMap { shown[$0] } ?? current
            added.append(id)
        }
        return added
    }

    /// The displays connected now, in order, the main one first. One that went away stops
    /// showing its workspace (macOS moves its windows to another display; the next switch puts
    /// them out of sight). One that's new shows what it showed when it was last here, if nobody
    /// shows that now; else the first empty workspace nobody shows, or failing that the first
    /// nobody shows, never a `reserved` one. The first time, the main display shows `current`.
    public mutating func displays(_ keys: [DisplayKey]) {
        order = keys
        shown = shown.filter { keys.contains($0.key) }
        if shown.isEmpty, let main = keys.first { shown[main] = current }
        for key in keys where shown[key] == nil { shown[key] = pick(for: key, taken: Set(shown.values)) }
        settleFocus()
    }

    /// The workspace a display without one gets: its last, else an empty one, else any free.
    private func pick(for key: DisplayKey, taken: Set<Int>) -> Int? {
        if let last = lastShown[key], !taken.contains(last) { return last }
        let free = Self.range.filter { !taken.contains($0) && !reserved.contains($0) }
        return free.first(where: { windows(on: $0).isEmpty }) ?? free.first ?? Self.range.first { !taken.contains($0) }
    }

    /// The focused display is one that's connected, and `current` is what it shows.
    private mutating func settleFocus() {
        if focusedDisplay.map({ shown[$0] == nil }) ?? true {
            focusedDisplay = shown.first { $0.value == current }?.key ?? order.first { shown[$0] != nil }
        }
        if let d = focusedDisplay, let n = shown[d] { current = n }
        for (key, n) in shown { lastShown[key] = n }
    }

    /// Whether workspace `n` is on some display now.
    public func isShown(_ n: Int) -> Bool { shown.isEmpty ? n == current : shown.values.contains(n) }

    /// The display showing workspace `n`, if any.
    public func display(showing n: Int) -> DisplayKey? { shown.first { $0.value == n }?.key }

    /// Every window on a workspace some display shows.
    public var visibleWindows: [WindowID] { home.filter { isShown($0.value) }.map(\.key).sorted() }

    /// You're working on display `d` now (a window there took focus, or the pointer went there):
    /// its workspace becomes `current`. Nothing is hidden or shown.
    public mutating func focus(display d: DisplayKey) {
        guard let n = shown[d] else { return }
        focusedDisplay = d
        current = n
    }

    /// A window you moved onto display `d` joins the workspace that display shows. True if it
    /// changed workspace.
    @discardableResult
    public mutating func moved(_ id: WindowID, to d: DisplayKey) -> Bool {
        // Only a window in sight can be dragged: one whose workspace no display shows was moved
        // by macOS (its display went away), not by you.
        guard let n = shown[d], let old = home[id], old != n, isShown(old) else { return false }
        assign(id, to: n, focus: false)
        return true
    }

    public func workspace(of id: WindowID) -> Int? { home[id] }

    /// The windows on workspace `n`. A companion is not one (R-D3).
    public func windows(on n: Int) -> [WindowID] {
        home.filter { $0.value == n && companionOf[$0.key] == nil }.map(\.key).sorted()
    }

    public func isCompanion(_ id: WindowID) -> Bool { companionOf[id] != nil }

    /// R-D2: `companion` lives with `main` from now on, and is on its workspace right away. Nothing
    /// happens if either is unknown, or if `main` is itself a companion.
    public mutating func attach(_ companion: WindowID, to main: WindowID) {
        guard companion != main, let n = home[main], home[companion] != nil, companionOf[main] == nil else { return }
        companionOf[companion] = main
        home[companion] = n
        if lastFocused[n] == companion { lastFocused[n] = nil }
    }

    /// The window a companion follows, or the window itself.
    public func main(of id: WindowID) -> WindowID { companionOf[id] ?? id }

    public mutating func noteFocus(_ id: WindowID) {
        let id = main(of: id)
        guard let n = home[id] else { return }
        lastFocused[n] = id
    }

    /// Moves a window to workspace `n`. With `focus`, it becomes the window that workspace
    /// focuses next; without, it only takes that role when the workspace has none.
    public mutating func assign(_ id: WindowID, to n: Int, focus: Bool = true) {
        guard Self.range.contains(n), home[id] != nil else { return }
        // R-D4: a companion is not moved alone; its window moves and takes it along.
        let id = main(of: id)
        if let old = home[id], lastFocused[old] == id { lastFocused[old] = nil }
        home[id] = n
        for (c, m) in companionOf where m == id { home[c] = n }
        if focus || lastFocused[n] == nil { lastFocused[n] = id }
    }

    /// Puts windows back where a saved layout had them, after BaneySpaces restarts. Only windows
    /// the model already knows are moved; `current` becomes the saved workspace.
    /// `displays` is what each display showed, for those still connected. Every display's
    /// workspace is picked again once windows are home: the saved one, else `current` for the
    /// main display, else as a new display gets one. Picking before that saw every window on
    /// the workspace a fresh launch put them all on, so "empty" meant nothing.
    public mutating func restore(current n: Int, home saved: [WindowID: Int], lastFocused focus: [Int: WindowID],
                                 displays: [DisplayKey: Int] = [:]) {
        for (id, ws) in saved where home[id] != nil && Self.range.contains(ws) { home[id] = ws }
        let n = Self.range.contains(n) ? n : current
        if !order.isEmpty {
            // Built fresh, so two displays that swapped workspaces don't block each other.
            var next: [DisplayKey: Int] = [:]
            for key in order {
                if let ws = displays[key], Self.range.contains(ws), !next.values.contains(ws) { next[key] = ws }
            }
            if !next.values.contains(n), let main = order.first(where: { next[$0] == nil }) { next[main] = n }
            for key in order where next[key] == nil {
                lastShown[key] = nil
                if let ws = pick(for: key, taken: Set(next.values)) { next[key] = ws }
            }
            shown = next
            focusedDisplay = display(showing: n)
        }
        current = n
        settleFocus()
        for (ws, id) in focus where home[id] == ws { lastFocused[ws] = id }
    }

    /// Makes `n` current and says which windows to hide and show. Switching to the workspace
    /// you are on still returns a full plan, which repairs anything an app moved on its own.
    ///
    /// With several displays, `n` goes to the focused display unless another display already
    /// shows it; then that display becomes the focused one and nothing else changes. `show` is
    /// every window on a shown workspace, so an app with windows on two displays stays shown.
    public mutating func switchTo(_ n: Int) -> SwitchPlan {
        precondition(Self.range.contains(n), "workspace \(n) is out of range")
        if let there = display(showing: n) {
            focusedDisplay = there
        } else if let d = focusedDisplay ?? order.first(where: { shown[$0] != nil }) {
            shown[d] = n
            lastShown[d] = n
            focusedDisplay = d
        }
        current = n
        let show = home.filter { isShown($0.value) }.map(\.key).sorted()
        let hide = home.filter { !isShown($0.value) }.map(\.key).sorted()
        let mine = windows(on: n)
        let focus = lastFocused[n].flatMap { mine.contains($0) ? $0 : nil } ?? mine.first
        return SwitchPlan(hide: hide, show: show, focus: focus, display: shown.count > 1 ? display(showing: n) : nil)
    }
}

/// How a switch keeps windows out of sight. Hiding the whole app (as ⌘H does) is clean: the
/// windows don't move and Mission Control doesn't show them. That only works when none of the
/// app's windows belong on the workspace being shown; those few windows get parked out of view.
public struct Concealment: Equatable {
    public var hideApps: Set<Int32>
    public var showApps: Set<Int32>
    public var park: [WindowID]

    /// `alsoShown` are apps coming back for a window not listed yet (one from the saved layout
    /// whose app hasn't answered): they stay shown, and their other windows are parked.
    /// `neverHidden` are apps that are never hidden whole: their windows elsewhere are parked.
    public init(plan: SwitchPlan, owner: [WindowID: Int32], alsoShown: Set<Int32> = [], neverHidden: Set<Int32> = []) {
        let shown = Set(plan.show.compactMap { owner[$0] }).union(alsoShown)
        let kept = shown.union(neverHidden)
        showApps = shown
        hideApps = Set(plan.hide.compactMap { owner[$0] }).subtracting(kept)
        park = plan.hide.filter { owner[$0].map(kept.contains) ?? false }
    }
}

/// The arrow keys in the overview, which lays the workspaces out as the number keys do: 1–3 on
/// top, 7–9 at the bottom.
public enum GridStep: Sendable {
    case left, right, up, down

    /// The workspace next to `n` that way; stays at the edge rather than wrapping.
    public func from(_ n: Int) -> Int {
        guard Workspaces.range.contains(n) else { return n }
        let row = (n - 1) / 3, col = (n - 1) % 3
        switch self {
        case .left: return col > 0 ? n - 1 : n
        case .right: return col < 2 ? n + 1 : n
        case .up: return row > 0 ? n - 3 : n
        case .down: return row < 2 ? n + 3 : n
        }
    }
}
