/// When the sidebar is on screen. Unpinned, it's a drawer: it opens on request and gets out of the
/// way by itself. Pinned, it stays while Ghostty is in front and windows move out of its strip.
public struct SidebarVisibility: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        /// The pointer rested on the left screen edge.
        case edgeRest
        /// ⌘⇧B.
        case toggleKey
        case pointerEntered
        /// The pointer left the sidebar and stayed out for the grace period.
        case pointerLeft
        /// A terminal was picked, or an action button pressed.
        case picked
        case escape
        case pin(Bool)
        /// Ghostty stopped being the front app.
        case ghosttyInactive
    }

    public private(set) var pinned: Bool
    public private(set) var open = false
    /// The pointer has been inside since it opened. Until then, leaving can't close it: opened by
    /// ⌘⇧B, it waits for you instead of vanishing because the pointer happened to be elsewhere.
    public private(set) var pointerVisited = false

    public init(pinned: Bool = false) { self.pinned = pinned }

    /// Shown now, given whether Ghostty is the front app.
    public func visible(ghosttyFront: Bool) -> Bool { ghosttyFront && (pinned || open) }

    public mutating func handle(_ e: Event) {
        switch e {
        case .edgeRest:
            if !open { open = true; pointerVisited = true }
        case .toggleKey:
            if pinned { pinned = false; close() }
            else if open { close() }
            else { open = true; pointerVisited = false }
        case .pointerEntered:
            if open { pointerVisited = true }
        case .pointerLeft:
            if !pinned && pointerVisited { close() }
        case .picked, .escape, .ghosttyInactive:
            if !pinned { close() }
        case .pin(let on):
            pinned = on
            if !on { close() }
        }
    }

    private mutating func close() { open = false; pointerVisited = false }
}
