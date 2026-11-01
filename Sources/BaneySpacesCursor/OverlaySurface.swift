import AppKit
import BaneySpacesCore
import QuartzCore

/// The real `CursorSurface`: Core Animation layers in click-through overlay panels, one panel per display.
/// Main thread only. Nothing here runs per frame: a glide is one keyframe animation handed to the compositor.
public final class OverlaySurface: CursorSurface {
    private var displays: [CursorDisplay] = []
    private var cursors: [String: AgentCursor] = [:]

    private let ordersFront: Bool

    /// `ordersFront: false` builds the panels without ever putting one on screen (tests).
    public init(displays specs: [CursorDisplaySpec], ordersFront: Bool = true) {
        self.ordersFront = ordersFront
        displays = specs.map { CursorDisplay($0, ordersFront: ordersFront) }
    }

    /// The displays changed: the overlays are rebuilt, and every cursor is kept. One that was shown comes back at
    /// the same place if that place is still on a display (its marks and look intact), and is hidden if it is not.
    public func setDisplays(_ specs: [CursorDisplaySpec]) {
        let shown = cursors.filter { $0.value.isShown }.map { ($0.value, $0.value.point) }
        cursors.values.forEach { $0.detach() }
        displays.forEach { $0.close() }
        displays = specs.map { CursorDisplay($0, ordersFront: ordersFront) }
        for (c, p) in shown {
            guard let d = display(containing: p) else { continue }
            c.attach(to: d)
            c.appear(at: p)
        }
    }

    /// The displays' frames in the hands' coordinates.
    public var frames: [CGRect] { displays.map(\.spec.globalFrame) }

    private func display(containing p: CGPoint) -> CursorDisplay? { displays.first { $0.contains(p) } }

    private func cursor(_ id: String) -> AgentCursor? { cursors[id] }

    public func configure(_ agent: String, look: CursorLook) {
        if let c = cursors[agent] { c.apply(look) } else { cursors[agent] = AgentCursor(id: agent, look: look) }
    }

    public func appear(_ agent: String, at point: CGPoint) {
        guard let c = cursors[agent], let d = display(containing: point) else { return }
        c.attach(to: d)
        c.appear(at: point)
    }

    public func move(_ agent: String, motion: CursorMotion) {
        guard let c = cursors[agent], let d = display(containing: motion.target) else { return }
        if c.display !== d {
            // Across displays the cursor lands instead of gliding over the gap.
            c.detach()
            c.attach(to: d)
            c.appear(at: motion.target)
            return
        }
        c.glide(motion)
    }

    public func jump(_ agent: String, to point: CGPoint) {
        guard let c = cursors[agent], let d = display(containing: point) else { return }
        if c.display !== d { c.detach(); c.attach(to: d); c.appear(at: point); return }
        c.jump(to: point)
    }

    public func act(_ agent: String, effect: CursorEffect, point: CGPoint, frame: CGRect, delay: TimeInterval) {
        cursors[agent]?.act(effect, at: point, frame: frame, delay: delay)
    }

    public func hide(_ agent: String) { cursors[agent]?.hide() }

    public func remove(_ agent: String) {
        cursors[agent]?.detach()
        cursors[agent] = nil
    }

    /// For checks: how many cursors the overlay holds, and whether one's marks are attached.
    public var cursorCount: Int { cursors.count }
    public func marksAreAttached(_ agent: String) -> Bool { cursors[agent]?.marksAreAttached ?? false }

    /// Where a cursor is drawn right now (its presentation layer), in the hands' coordinates: for the probe.
    public func presentedPoint(_ agent: String) -> CGPoint? {
        guard let c = cursors[agent], let d = c.display, let p = c.root.presentation()?.position else { return nil }
        return CGPoint(x: p.x + d.spec.globalFrame.minX, y: d.spec.globalFrame.maxY - p.y)
    }

    public func isGliding(_ agent: String) -> Bool { cursors[agent]?.root.animation(forKey: AgentCursor.glideKey) != nil }

    public func isShown(_ agent: String) -> Bool { cursors[agent]?.isShown ?? false }

    /// Every overlay panel, for checks that they can't take focus.
    public var panels: [NSPanel] { displays.map(\.panel) }
}
