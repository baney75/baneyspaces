import Foundation

/// What the Workspace Dock's 30 Hz tick decides, apart from AppKit. The tick gathers what it
/// reads into an `Input`, calls `step`, and performs the returned actions in order.
///
/// The order of the checks is the point (#43, #44): a panel left up after the dock went down is
/// put away FIRST, before the overview's early return, or it would stay up the whole time the
/// overview is open. Then the overview (the dock stays down), a drag whose mouse-up never came,
/// then, with the dock up, the keep zone, a menu holding it and the away delay; with the dock
/// down, the edge, the re-arm, the span, the dwell, a menu in the way and a carry that can't drop.
public enum DockTick {
    /// How long the pointer is off the dock before it goes down.
    public static let awayDelay: TimeInterval = 0.4
    /// How long a dock drag with the buttons up is left before it's cancelled.
    public static let dragStuckAfter: TimeInterval = 0.3

    /// What the tick remembers between calls. Times are on the `Input.clock` scale.
    public struct State: Equatable, Sendable {
        /// When the pointer began resting on the edge.
        public var edgeSince: TimeInterval?
        /// When the pointer left the keep zone of the dock that's up.
        public var awaySince: TimeInterval?
        /// When a dock drag was first seen with the buttons up.
        public var buttonsUpSince: TimeInterval?
        /// Hidden with the pointer still on the edge: it comes back only after the pointer leaves.
        public var needsRearm: Bool

        public init(edgeSince: TimeInterval? = nil, awaySince: TimeInterval? = nil,
                    buttonsUpSince: TimeInterval? = nil, needsRearm: Bool = false) {
            self.edgeSince = edgeSince
            self.awaySince = awaySince
            self.buttonsUpSince = buttonsUpSince
            self.needsRearm = needsRearm
        }
    }

    /// Everything the tick reads, gathered before `step`. Whatever costs something, or changes
    /// something when asked, is a closure passed to `step` instead, and is asked only when the
    /// decision reaches it.
    public struct Input: Sendable {
        /// Seconds of uptime (`DockStray`).
        public var uptime: TimeInterval
        /// Wall-clock seconds, for `State`'s times and the delays.
        public var clock: TimeInterval
        /// The dock thinks it is up.
        public var shown: Bool
        public var panelPresent: Bool
        /// The panel exists and is on screen.
        public var panelUp: Bool
        /// When the dock last went down, in uptime.
        public var hiddenAt: TimeInterval?
        /// The overview is open.
        public var viewerOpen: Bool
        /// Any mouse button is down.
        public var buttonsDown: Bool
        /// The dock has a drag of its own going.
        public var dragActive: Bool
        /// That drag is of a tile (not a carried window) and may stray off the dock.
        public var dragStraying: Bool
        /// The pointer is in the keep zone of the dock that's up.
        public var inKeepZone: Bool
        /// The screen whose dock edge the pointer rests on, if any.
        public var edgeScreen: Int?
        /// Something is being dragged in from another app.
        public var carrying: Bool
        /// A window is being dragged by its title bar toward the dock.
        public var windowCarry: Bool
        /// That window was already refused for this press.
        public var carryRefused: Bool
        /// The edge screen is the one the dock was hidden on.
        public var onRearmScreen: Bool
        /// The pointer is along the stretch of edge the dock covers.
        public var withinSpan: Bool
        /// How long the pointer rests on the edge before the dock comes (`DockEdge.dwell`).
        public var dwell: TimeInterval

        public init(uptime: TimeInterval = 0, clock: TimeInterval = 0, shown: Bool = false,
                    panelPresent: Bool = false, panelUp: Bool = false, hiddenAt: TimeInterval? = nil,
                    viewerOpen: Bool = false, buttonsDown: Bool = false, dragActive: Bool = false,
                    dragStraying: Bool = false, inKeepZone: Bool = false, edgeScreen: Int? = nil,
                    carrying: Bool = false, windowCarry: Bool = false, carryRefused: Bool = false,
                    onRearmScreen: Bool = false, withinSpan: Bool = false, dwell: TimeInterval = 0.12) {
            self.uptime = uptime
            self.clock = clock
            self.shown = shown
            self.panelPresent = panelPresent
            self.panelUp = panelUp
            self.hiddenAt = hiddenAt
            self.viewerOpen = viewerOpen
            self.buttonsDown = buttonsDown
            self.dragActive = dragActive
            self.dragStraying = dragStraying
            self.inKeepZone = inKeepZone
            self.edgeScreen = edgeScreen
            self.carrying = carrying
            self.windowCarry = windowCarry
            self.carryRefused = carryRefused
            self.onRearmScreen = onRearmScreen
            self.withinSpan = withinSpan
            self.dwell = dwell
        }
    }

    /// What the tick does, in the order it does it.
    public enum Action: Equatable, Sendable {
        /// Take a panel left on screen after the dock went down off the screen.
        case orderOutStray
        /// Hide the dock because the overview is open.
        case hideForViewer
        /// End the dock's drag: the buttons are up and its mouse-up never came.
        case cancelDrag
        /// Hide the dock, the pointer having left it. Remember the panel's screen as the one to
        /// re-arm on (`State.needsRearm` is already set).
        case hideAway
        /// Show the dock on this screen (the index in the screens the input was gathered from),
        /// then hand it a window being carried, if one is.
        case show(screen: Int)
    }

    /// One tick's decision. `state` is updated in place; apply it before the actions, since
    /// showing clears the dwell and away clocks itself. The closures are asked in the order the
    /// old tick asked: `menuHoldsDock` only for a dock that's up with the pointer off it,
    /// `menuInTheWay` only once the dwell is over, `carryUndroppable` last, before showing.
    public static func step(_ i: Input, state s: inout State,
                            menuHoldsDock: () -> Bool,
                            menuInTheWay: () -> Bool,
                            carryUndroppable: () -> Bool) -> [Action] {
        var out: [Action] = []
        // Down, yet its panel still up once the slide-out is over: nothing else would take it
        // away. Before the overview's return below, or it would stay up while the overview is.
        if DockStray.isStray(shown: i.shown, panelUp: i.panelUp, hiddenAt: i.hiddenAt, now: i.uptime) {
            out.append(.orderOutStray)
        }
        // The overview already shows every workspace; the dock stays down while it's open.
        if i.viewerOpen {
            if i.shown { out.append(.hideForViewer) }
            s.edgeSince = nil
            return out
        }
        // A drag whose mouse-up never reached the dock would hold it open forever; once the
        // buttons have been up a moment, it's over.
        var dragStraying = i.dragStraying
        if i.dragActive, !i.buttonsDown {
            if s.buttonsUpSince == nil { s.buttonsUpSince = i.clock }
            if i.clock - s.buttonsUpSince! > dragStuckAfter {
                out.append(.cancelDrag)
                dragStraying = false
            }
        } else {
            s.buttonsUpSince = nil
        }
        if i.shown {
            guard i.panelPresent else { return out }
            // Hovering the dock or the edge below it keeps it up; a menu open from it too, and a
            // drag that strays off it on the way to a tile.
            let keep = i.inKeepZone || menuHoldsDock() || dragStraying
            if keep { s.awaySince = nil; return out }
            if s.awaySince == nil { s.awaySince = i.clock }
            if i.clock - s.awaySince! > awayDelay {
                s.needsRearm = true
                out.append(.hideAway)
            }
            return out
        }
        // Resting on the dock's edge, buttons up unless carrying something from another app or a
        // window by its title bar.
        guard let screen = i.edgeScreen,
              !i.buttonsDown || i.carrying || i.windowCarry && !i.carryRefused
        else { s.edgeSince = nil; s.needsRearm = false; return out }
        if s.needsRearm, i.onRearmScreen { s.edgeSince = nil; return out }
        s.needsRearm = false
        guard i.withinSpan else { s.edgeSince = nil; return out }
        if s.edgeSince == nil { s.edgeSince = i.clock }
        guard i.clock - s.edgeSince! > i.dwell else { return out }
        if menuInTheWay() { return out }
        if i.buttonsDown, !i.carrying, i.windowCarry, carryUndroppable() { s.edgeSince = nil; return out }
        out.append(.show(screen: screen))
        return out
    }
}
