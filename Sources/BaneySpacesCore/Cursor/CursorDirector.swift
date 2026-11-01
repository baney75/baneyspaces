import CoreGraphics
import Foundation

/// What the cursor shows for an action.
public enum CursorEffect: Equatable, Sendable {
    /// A ripple and a squish at the target, and a dot mark. Also select and toggle.
    case click
    /// A caret pulse at the target, and a caret mark.
    case type
    /// A short trail in the scroll's direction (unit vector, y down), and an arrow mark.
    case scroll(dx: Double, dy: Double)

    /// Nil for a verb that draws nothing (`press`, which is refused anyway).
    public static func of(kind: String, direction: String?) -> CursorEffect? {
        switch kind {
        case "click", "select", "toggle": return .click
        case "type", "set-value": return .type
        case "scroll":
            switch direction ?? "down" {
            case "up": return .scroll(dx: 0, dy: -1)
            case "left": return .scroll(dx: -1, dy: 0)
            case "right": return .scroll(dx: 1, dy: 0)
            default: return .scroll(dx: 0, dy: 1)
            }
        default: return nil
        }
    }
}

/// A glide for the renderer to hand to the compositor as one keyframe animation. Times are on the system
/// uptime clock (the one `CACurrentMediaTime` reads), so the animation and the planner agree on "now".
public struct CursorMotion: Equatable, Sendable {
    public var start: TimeInterval
    public var step: TimeInterval
    public var duration: TimeInterval
    /// When the cursor reaches the target: the ripple waits for it.
    public var arrival: TimeInterval
    public var points: [CGPoint]
    public var target: CGPoint

    public init(plan: GlidePlan, start: TimeInterval, step: TimeInterval = 1.0 / 240) {
        self.start = start; self.step = step; duration = plan.duration; arrival = plan.arrival
        points = plan.samples(step: step).map(\.position); target = plan.target
    }
}

/// Where the cursor is drawn. The real one is a Core Animation overlay; tests use a fake. Every call comes
/// from the director's queue, and none of them may be waited on by an action.
public protocol CursorSurface: AnyObject {
    /// The agent's look: its name, colors and theme. Called before the first draw and whenever it changes.
    func configure(_ agent: String, look: CursorLook)
    /// Shows the cursor at a point (fading in).
    func appear(_ agent: String, at point: CGPoint)
    /// Glides it; replaces any glide in flight.
    func move(_ agent: String, motion: CursorMotion)
    func jump(_ agent: String, to point: CGPoint)
    /// The mark of an action at the target: `delay` seconds from now, when the cursor arrives.
    func act(_ agent: String, effect: CursorEffect, point: CGPoint, frame: CGRect, delay: TimeInterval)
    func hide(_ agent: String)
    /// The agent is gone for good (idle for a long time): its layers are removed.
    func remove(_ agent: String)
}

/// What the director needs to know about the world; the app updates it on the main thread.
public struct CursorEnvironment: Equatable, Sendable {
    public var settings = CursorSettings()
    public var current = 1
    public var agentWorkspace: Int?
    public var reduceMotion = false
    /// The displays' frames in the hands' coordinates (global, y down).
    public var displays: [CGRect] = []
    public init() {}
}

/// Where an agent's cursor last acted, for `agent shot --cursor`.
public struct CursorMark: Equatable, Sendable {
    public var look: CursorLook
    public var point: CGPoint
    /// The window's frame when it acted, so the mark can be placed in a capture of that window.
    public var windowFrame: CGRect?
    public var at: TimeInterval
    public init(look: CursorLook, point: CGPoint, windowFrame: CGRect?, at: TimeInterval) {
        self.look = look; self.point = point; self.windowFrame = windowFrame; self.at = at
    }
}

/// The agent cursor's brain. It listens to the hands (`HandsEvents`), decides whether the cursor is drawn,
/// plans the glide, and tells a `CursorSurface` what to animate. The action never waits for any of it:
/// `handsWillAct` only queues the event and returns.
public final class CursorDirector: HandsEventListener {
    public struct Host {
        /// The Deck's name and status for an agent session.
        public var agent: (String) -> (name: String, status: DockAgent.State) = { _ in ("Agent", .working) }
        /// A window's frame now (global, y down).
        public var windowFrame: (UInt32) -> CGRect? = { _ in nil }
        public var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        public init() {}
    }

    private struct Track {
        var plan: GlidePlan?
        var planStart: TimeInterval = 0
        /// The last place it stood (its destination), kept while hidden for being idle.
        var rest: CGPoint?
        var shown = false
        var stamp = 0
        var look: CursorLook?
        var scope = ""
        var workspace: Int?
    }

    public static let maxNameLength = 18
    /// How long an action waits for its target's frame to be measured before the cursor settles for its last known point.
    public static let frameWait: TimeInterval = 0.05
    private let surface: CursorSurface
    private let queue: DispatchQueue
    private let host: Host
    private let idleAfter: TimeInterval
    private let pruneAfter: TimeInterval
    private let lock = NSLock()
    private var env = CursorEnvironment()
    private var marks: [UInt32: CursorMark] = [:]
    // Touched only on `queue`.
    private var tracks: [String: Track] = [:]
    private var pending: [UInt64: HandsActionEvent] = [:]
    private var knownDisplays: [CGRect] = []

    public init(surface: CursorSurface, queue: DispatchQueue, host: Host = Host(), idleAfter: TimeInterval = 6, pruneAfter: TimeInterval = 300) {
        self.surface = surface; self.queue = queue; self.host = host; self.idleAfter = idleAfter; self.pruneAfter = pruneAfter
    }

    // MARK: world

    private func environment() -> CursorEnvironment { lock.lock(); defer { lock.unlock() }; return env }

    /// Called by the app when a workspace, a setting or a display changes. Cursors that must not be drawn any more hide.
    public func setEnvironment(_ e: CursorEnvironment) {
        lock.lock(); let changed = env != e; env = e; lock.unlock()
        if changed { queue.async { [self] in reconcile() } }
    }

    /// Where the agent cursor last acted on `window`, if it did within `within` seconds.
    public func lastMark(window: UInt32, within: TimeInterval = 30) -> CursorMark? {
        lock.lock(); defer { lock.unlock() }
        guard let m = marks[window], host.now() - m.at <= within else { return nil }
        return m
    }

    // MARK: HandsEventListener

    public func handsWantsFrame(scope: String, workspace: Int?) -> Bool {
        let e = environment()
        return CursorVisibility.wantsFrame(enabled: e.settings.enabled, scope: scope, windowWorkspace: workspace, current: e.current, agent: e.agentWorkspace)
    }

    /// On the hands' thread, before the action is sent. It only queues the event: the action never waits for the glide.
    /// An event whose frame is still being measured waits here for up to `frameWait`, never on the hands' thread.
    public func handsWillAct(_ event: HandsActionEvent) {
        queue.async { [self] in
            guard event.frameComing else { return process(event) }
            pending[event.id] = event
            queue.asyncAfter(deadline: .now() + Self.frameWait) { [self] in
                // Late: draw at the last known point, if there is one. The action has long since gone.
                guard let ev = pending.removeValue(forKey: event.id) else { return }
                processLate(ev)
            }
        }
    }

    public func handsFrame(actionID: UInt64, frame: CGRect?) {
        queue.async { [self] in
            guard var ev = pending.removeValue(forKey: actionID) else { return }
            ev.frame = frame; ev.point = frame.map { CGPoint(x: $0.midX, y: $0.midY) }; ev.frameComing = false
            process(ev)
        }
    }

    // MARK: on the queue

    private func look(for session: String, _ e: CursorEnvironment) -> CursorLook {
        let a = host.agent(session)
        let name = a.name.count > Self.maxNameLength ? String(a.name.prefix(Self.maxNameLength - 1)) + "…" : a.name
        return CursorLook(name: name, status: a.status, identity: CursorPalette.identityColor(for: session), theme: e.settings.resolvedTheme)
    }

    private func current(_ t: Track, _ now: TimeInterval) -> GlideState? {
        if let plan = t.plan, now - t.planStart < plan.duration { return plan.state(at: now - t.planStart) }
        return t.rest.map { GlideState(position: $0) }
    }

    /// The frame didn't arrive in time: the effect happens where the cursor already stands, with no glide and no focus box.
    private func processLate(_ ev: HandsActionEvent) {
        guard let rest = tracks[ev.session]?.rest, tracks[ev.session]?.shown == true else { return }
        var late = ev
        late.frame = CGRect(origin: rest, size: .zero); late.point = rest; late.frameComing = false
        process(late)
    }

    private func process(_ ev: HandsActionEvent) {
        let env = environment()
        let agent = ev.session
        let decision = CursorVisibility.decide(enabled: env.settings.enabled, scope: ev.scope, windowWorkspace: ev.workspace, current: env.current,
                                               agent: env.agentWorkspace, frame: ev.frame, displays: env.displays)
        guard decision.shown, let frame = ev.frame else {
            hide(agent, forget: true)
            return
        }
        guard let effect = CursorEffect.of(kind: ev.kind, direction: ev.direction) else { return }
        let now = host.now()
        var t = tracks[agent] ?? Track()
        let look = look(for: agent, env)
        if t.look != look { surface.configure(agent, look: look); t.look = look }
        let target = CGPoint(x: frame.midX, y: frame.midY)
        let skip = env.settings.skipsGlide(reduceMotion: env.reduceMotion)
        let from = t.shown ? current(t, now) : t.rest.map { GlideState(position: $0) }
        if !t.shown {
            // It comes back where it stood, and glides from there.
            surface.appear(agent, at: skip ? target : (from?.position ?? target))
            t.shown = true
        }
        var delay = 0.0
        if let from, !skip {
            let plan = GlidePlan(from: from, target: target, spring: env.settings.spring)
            if plan.duration > 0 {
                surface.move(agent, motion: CursorMotion(plan: plan, start: now))
                t.plan = plan; t.planStart = now; delay = plan.arrival
            } else {
                if t.plan != nil { surface.jump(agent, to: target) }
                t.plan = nil
            }
        } else { surface.jump(agent, to: target); t.plan = nil }
        t.rest = target
        surface.act(agent, effect: effect, point: target, frame: frame, delay: delay)
        t.stamp += 1; t.scope = ev.scope; t.workspace = ev.workspace
        tracks[agent] = t
        // The window server round trip happens before the lock, so the hands' thread never waits behind it.
        let windowFrame = host.windowFrame(ev.window)
        lock.lock()
        marks[ev.window] = CursorMark(look: look, point: target, windowFrame: windowFrame, at: now)
        if marks.count > 64, let old = marks.min(by: { $0.value.at < $1.value.at })?.key { marks[old] = nil }
        lock.unlock()
        let stamp = t.stamp
        queue.asyncAfter(deadline: .now() + idleAfter) { [self] in
            guard tracks[agent]?.stamp == stamp else { return }
            hide(agent, forget: false)
            // A session that stays quiet is forgotten, so many sessions over weeks don't pile up layers.
            queue.asyncAfter(deadline: .now() + pruneAfter) { [self] in
                guard let t = tracks[agent], t.stamp == stamp, !t.shown else { return }
                tracks[agent] = nil
                surface.remove(agent)
            }
        }
    }

    /// `forget`: it left because you are not looking (or it was turned off), so where it stood is no use later.
    private func hide(_ agent: String, forget: Bool) {
        guard var t = tracks[agent] else { return }
        if t.shown { surface.hide(agent) }
        t.shown = false; t.plan = nil
        if forget { t.rest = nil }
        tracks[agent] = t
    }

    private func reconcile() {
        let env = environment()
        let now = host.now()
        // The displays changed: every cursor is made again from what the director knows (its look and where it stands),
        // whatever the overlay kept. A cursor that is on a display that is still there comes back at once.
        if env.displays != knownDisplays {
            knownDisplays = env.displays
            for (agent, var t) in tracks {
                let pos = t.shown ? (current(t, now)?.position ?? t.rest) : nil
                t.look = nil
                if t.shown {
                    t.shown = false; t.plan = nil
                    if let pos, env.displays.contains(where: { $0.contains(pos) }), CursorVisibility.wantsFrame(enabled: env.settings.enabled, scope: t.scope, windowWorkspace: t.workspace, current: env.current, agent: env.agentWorkspace) {
                        let l = look(for: agent, env)
                        surface.configure(agent, look: l)
                        surface.appear(agent, at: pos)
                        t.look = l; t.shown = true; t.rest = pos
                    } else { surface.hide(agent); t.rest = nil }
                } else if let r = t.rest, !env.displays.contains(where: { $0.contains(r) }) { t.rest = nil }
                tracks[agent] = t
            }
        }
        for (agent, t) in tracks {
            if !CursorVisibility.wantsFrame(enabled: env.settings.enabled, scope: t.scope, windowWorkspace: t.workspace, current: env.current, agent: env.agentWorkspace) {
                // Not watchable any more: hide it, and forget where it stood (idle ones too: the windows were parked).
                hide(agent, forget: true)
                continue
            }
            guard t.shown else { continue }
            let l = look(for: agent, env)
            if l != tracks[agent]?.look { surface.configure(agent, look: l); tracks[agent]?.look = l }
        }
    }
}
