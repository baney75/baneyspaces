import Foundation

/// The dock's on/off switch (spec/themes.md, "The dock switch"). Off, there is no dock window at
/// all, not a hidden one: the edge watcher is stopped, nothing can build a panel, and a window
/// carried toward the bottom edge is nobody's business. On, the panel is built the next time the
/// pointer reveals the dock. `WorkspaceDock` owns the real panel through one of these, so the
/// rule is here, tested with stand-in panels, and the app can't build one around it.
public final class DockSwitch<Panel: AnyObject> {
    public private(set) var enabled = false
    public private(set) var watching = false
    public private(set) var panel: Panel?

    private let make: () -> Panel
    private let startWatching: () -> Void
    private let stopWatching: () -> Void
    private let release: (Panel) -> Void

    public init(make: @escaping () -> Panel, startWatching: @escaping () -> Void,
                stopWatching: @escaping () -> Void, release: @escaping (Panel) -> Void) {
        self.make = make
        self.startWatching = startWatching
        self.stopWatching = stopWatching
        self.release = release
    }

    /// Turning it on starts the edge watcher (the panel waits for the first reveal); turning it
    /// off stops the watcher and takes the panel down.
    public func set(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            watching = true
            startWatching()
        } else {
            watching = false
            stopWatching()
            if let p = panel { panel = nil; release(p) }
        }
    }

    /// The panel for a reveal: the one there is, or a new one. Nil when the dock is off.
    public func panelForReveal() -> Panel? {
        guard enabled else { return nil }
        if let panel { return panel }
        let p = make()
        panel = p
        return p
    }

    /// The app dropped its panel itself (a rebuild after the window server lost it).
    public func forgetPanel() { panel = nil }

    /// Whether a window carried to the bottom edge is the dock's to take (`DockCarry`).
    public var carryActs: Bool { enabled && watching }

    /// Whether the window-drag watcher is needed: the top drag wants it, and so does the dock's
    /// carry. With both off nothing watches window drags.
    public static func windowDragsNeeded(topDrag: Bool, dockEnabled: Bool) -> Bool { topDrag || dockEnabled }
}
