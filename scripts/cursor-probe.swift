// The agent cursor's frame-timing probe (docs/agent-computer-use.md, phase 1b; spec/config.md, the animation bar).
//
//   swift run -c release cursor-probe              100 glides on the main display, as if on the agent workspace
//   swift run -c release cursor-probe --glides 40  fewer glides
//
// It drives the real director (registered with HandsEvents, and fed the way the router feeds it: an action with
// `frameComing`, then the measured frame a few milliseconds later from another queue) and the real overlay (Core
// Animation layers in a click-through panel), and records CADisplayLink frame times while 100 glides run (every fifth
// is cut short by a new target). The overlay is ON the display, because a panel outside every display gets no display
// link and is never composited: the cursor is visible while it runs, which is why it needs Donovan away.
//
// Passing needs all of these:
//   - frame time: at most 1 frame in 200 over 1.5x the display's frame interval and none over 2x;
//   - something was drawn: one overlay update per action, and the cursor layer moved through at least one distinct
//     position per glide;
//   - the drawn path matches the plan: at every frame during a glide the cursor layer's presentation position is
//     within 3 pt + one frame of travel at the planned speed of where the plan says it is (the allowance is for the
//     frame the display link reports lagging the layer tree by up to one frame); at most 1 frame in 200 may be outside;
//     and after the last glide it stands on its target to 1.5 pt;
//   - the real pointer: sampled every millisecond throughout, at least 1000 samples, zero changes;
//   - the overlay never became key or main, and the front app never changed.
//
// It runs only when Donovan has been idle 10 minutes (HIDIdleTime >= 600 s, the number `ioreg -c IOHIDSystem`
// shows), and stops, reporting "not run", the moment he is back. Exit 0 pass, 1 fail, 2 not run.
import AppKit
import BaneySpacesCore
import BaneySpacesCursor
import QuartzCore

/// Forwards to the real overlay and times each call, so the main-thread cost of an action is known.
final class TimedSurface: CursorSurface {
    let inner: OverlaySurface
    var applySeconds: [Double] = []
    var lastMotion: CursorMotion?
    /// Counts the glides handed to the overlay, so each frame is compared with the right one.
    var motionIndex = 0
    private var pending = 0.0
    init(_ inner: OverlaySurface) { self.inner = inner }
    private func timed(_ f: () -> Void) {
        let t0 = CACurrentMediaTime(); f(); pending += CACurrentMediaTime() - t0
    }
    func configure(_ agent: String, look: CursorLook) { timed { inner.configure(agent, look: look) } }
    func appear(_ agent: String, at point: CGPoint) { timed { inner.appear(agent, at: point) } }
    func move(_ agent: String, motion: CursorMotion) { lastMotion = motion; motionIndex += 1; timed { inner.move(agent, motion: motion) } }
    func jump(_ agent: String, to point: CGPoint) { timed { inner.jump(agent, to: point) } }
    func act(_ agent: String, effect: CursorEffect, point: CGPoint, frame: CGRect, delay: TimeInterval) {
        timed { inner.act(agent, effect: effect, point: point, frame: frame, delay: delay) }
        applySeconds.append(pending); pending = 0
    }
    func hide(_ agent: String) { timed { inner.hide(agent) } }
    func remove(_ agent: String) { timed { inner.remove(agent) } }
}

/// What the pointer sampler (a background queue) and the main thread both touch.
final class SharedState {
    private let lock = NSLock()
    private var _samples = 0, _moves = 0, _interrupted = false
    func sampled(moved: Bool, interrupted: Bool) {
        lock.lock(); _samples += 1; if moved { _moves += 1 }; if interrupted { _interrupted = true }; lock.unlock()
    }
    var samples: Int { lock.lock(); defer { lock.unlock() }; return _samples }
    var moves: Int { lock.lock(); defer { lock.unlock() }; return _moves }
    var interrupted: Bool { lock.lock(); defer { lock.unlock() }; return _interrupted }
}

@main
final class CursorProbe: NSObject {
    static var probe: CursorProbe?
    static func main() {
        let p = CursorProbe()
        probe = p
        p.start()
        RunLoop.main.run()
    }

    let args = CommandLine.arguments
    var glides = 100
    let agentID = "probe"
    var surface: TimedSurface!
    var director: CursorDirector!
    var link: AnyObject?
    /// Kept for the whole run: a dispatch source nobody holds is cancelled, and the probe would sample nothing.
    var sampler: DispatchSourceTimer?
    let shared = SharedState()
    var stamps: [Double] = []
    var intervals: [Double] = []
    struct Position: Hashable { var x: Int, y: Int }
    /// Per glide: frames compared with the plan, frames outside the tolerance, distinct drawn positions.
    var perGlide: [Int: (compared: Int, bad: Int, positions: Set<Position>)] = [:]
    var errors: [Double] = []
    var pointerStart = CGPoint.zero
    var idleAtStart = 0.0
    var frontStart: pid_t = 0
    var frontChanges = 0
    var keyOrMain = 0
    var done = false
    var running = false
    var lastTarget = CGPoint.zero
    var lateFrames = 0

    func idle() -> Double {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }

    func pointer() -> CGPoint? { CGEvent(source: nil)?.location }

    func start() {
        if let i = args.firstIndex(of: "--glides"), i + 1 < args.count, let n = Int(args[i + 1]), n > 0 { glides = n }
        idleAtStart = idle()
        guard idleAtStart >= 600 else {
            print("cursor-probe: not run (Donovan has been idle \(Int(idleAtStart)) s; the probe needs 600 s)")
            exit(2)
        }
        guard #available(macOS 14, *), let screen = NSScreen.main else {
            print("cursor-probe: not run (needs macOS 14 and a display)")
            exit(2)
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        let primary = NSScreen.screens[0]
        let top = primary.frame.maxY
        let spec = CursorDisplaySpec(globalFrame: CGRect(x: screen.frame.minX, y: top - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height),
                                     panelFrame: screen.frame, scale: screen.backingScaleFactor)
        let overlay = OverlaySurface(displays: [spec])
        surface = TimedSurface(overlay)
        var host = CursorDirector.Host()
        host.agent = { _ in ("Probe", .working) }
        director = CursorDirector(surface: surface, queue: .main, host: host, idleAfter: 30)
        var env = CursorEnvironment()
        env.shownWorkspaces = [9]; env.agentWorkspace = 9; env.displays = [spec.globalFrame]
        director.setEnvironment(env)
        // The hands report through HandsEvents; without this nothing would ever reach the director.
        HandsEvents.setListener(director)
        pointerStart = pointer() ?? .zero
        frontStart = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0

        // CADisplayLink on the display: one callback per frame.
        let dl = screen.displayLink(target: self, selector: #selector(tick(_:)))
        dl.add(to: .main, forMode: .common)
        link = dl
        // The real pointer, sampled every millisecond off the main thread, so a stall can't hide a move.
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "pointer", qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .milliseconds(1))
        var last = pointerStart
        let startIdle = idleAtStart
        let shared = self.shared
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let p = self.pointer() ?? last
            let moved = p != last
            last = p
            shared.sampled(moved: moved, interrupted: self.idle() < startIdle - 5)
        }
        sampler = timer
        timer.resume()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.begin() }
    }

    var index = 0
    var rng = SystemRandomNumberGenerator()

    func begin() {
        running = true
        step()
    }

    /// One action, fed as the router does: announced with `frameComing`, its measured frame a few milliseconds later
    /// from another queue. A new target at least 300 points away; every fifth is sent 60 ms after the last, mid-glide.
    func step() {
        guard index < glides, !shared.interrupted else { return finish() }
        let size = NSScreen.main!.frame.size
        let kinds = ["click", "type", "scroll", "click"]
        let dirs = ["down", "up", "left", "right"]
        var p: CGPoint
        repeat {
            p = CGPoint(x: CGFloat.random(in: 80...(size.width - 80), using: &rng), y: CGFloat.random(in: 80...(size.height - 80), using: &rng))
        } while far(p) == false
        last = p
        lastTarget = p
        let kind = kinds[index % kinds.count]
        let id = HandsEvents.newActionID()
        let frame = CGRect(x: p.x - 40, y: p.y - 12, width: 80, height: 24)
        HandsEvents.willAct(HandsActionEvent(kind: kind, ref: "@s1:e\(index)", window: 1, pid: 1, app: "Probe", point: nil, frame: nil, session: agentID,
                                             scope: "agent_workspace", workspace: 9, direction: kind == "scroll" ? dirs[(index / 4) % 4] : nil,
                                             id: id, frameComing: true))
        let delay = Double.random(in: 0.002...0.030, using: &rng)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { HandsEvents.frameMeasured(actionID: id, frame: frame) }
        index += 1
        let cut = index % 5 == 0
        DispatchQueue.main.asyncAfter(deadline: .now() + (cut ? 0.06 : 0.42)) { self.step() }
    }
    var last: CGPoint?
    func far(_ p: CGPoint) -> Bool { last.map { hypot(p.x - $0.x, p.y - $0.y) >= 300 } ?? true }

    /// Where the plan puts the cursor `t` seconds into a glide, and how fast it is going (points per second).
    func planned(_ m: CursorMotion, at t: Double) -> (point: CGPoint, speed: Double) {
        let f = max(0, t) / m.step
        let i = min(m.points.count - 1, Int(f))
        let j = min(m.points.count - 1, i + 1)
        let frac = CGFloat(min(1, f - Double(i)))
        let a = m.points[i], b = m.points[j]
        return (CGPoint(x: a.x + (b.x - a.x) * frac, y: a.y + (b.y - a.y) * frac), Double(hypot(b.x - a.x, b.y - a.y)) / m.step)
    }

    @available(macOS 14, *)
    @objc func tick(_ link: CADisplayLink) {
        guard running, !done else { return }
        stamps.append(link.timestamp)
        let interval = link.targetTimestamp - link.timestamp
        intervals.append(interval)
        if NSApp.keyWindow != nil || NSApp.mainWindow != nil || surface.inner.panels.contains(where: { $0.isKeyWindow || $0.isMainWindow || $0.canBecomeKey || $0.canBecomeMain }) { keyOrMain += 1 }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != frontStart { frontChanges += 1; frontStart = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0 }
        // How far the drawn cursor is from the planned glide right now, glide by glide.
        guard let m = surface.lastMotion, let drawn = surface.inner.presentedPoint(agentID) else { return }
        let t = ProcessInfo.processInfo.systemUptime - m.start
        var g = perGlide[surface.motionIndex] ?? (0, 0, [])
        g.positions.insert(Position(x: Int(drawn.x.rounded()), y: Int(drawn.y.rounded())))
        if t >= 0, t <= m.duration {
            let (want, speed) = planned(m, at: t)
            let err = Double(hypot(drawn.x - want.x, drawn.y - want.y))
            errors.append(err)
            g.compared += 1
            if err > 3 + speed * interval { g.bad += 1 }
        }
        perGlide[surface.motionIndex] = g
    }

    func finish() {
        // Let the last glide settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.report() }
    }

    func percentile(_ xs: [Double], _ p: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted(); return s[min(s.count - 1, Int(Double(s.count) * p))]
    }

    func report() {
        running = false; done = true
        sampler?.cancel()
        sampler = nil
        let deltas = zip(stamps, stamps.dropFirst()).map { $1 - $0 }
        let nominal = percentile(intervals, 0.5)
        let over15 = deltas.filter { $0 > nominal * 1.5 }.count
        let over2 = deltas.filter { $0 > nominal * 2 }.count
        let frames = deltas.count
        let ms = { (x: Double) in String(format: "%.2f", x * 1000) }
        print("cursor-probe: \(index) glides on the main display, \(frames) frames, display \(String(format: "%.0f", 1 / max(nominal, 1e-6))) Hz (interval \(ms(nominal)) ms)")
        print("  frame time: median \(ms(percentile(deltas, 0.5))) ms, p99 \(ms(percentile(deltas, 0.99))) ms, max \(ms(deltas.max() ?? 0)) ms")
        print("  frames over 1.5x the interval: \(over15) of \(frames) (limit 1 in 200 = \(frames / 200)); over 2x: \(over2) (limit 0)")
        let apply = surface.applySeconds
        print("  main thread, per action: median \(ms(percentile(apply, 0.5))) ms, max \(ms(apply.max() ?? 0)) ms (director + layers, off the hands' thread)")
        let compared = perGlide.values.map(\.compared).reduce(0, +)
        let bad = perGlide.values.map(\.bad).reduce(0, +)
        let withFrames = perGlide.values.filter { $0.compared >= 1 }.count
        let moving = perGlide.values.filter { $0.positions.count >= 2 }.count
        print("  drawn vs planned (tolerance 3 pt + one frame of travel): median \(String(format: "%.2f", percentile(errors, 0.5))) pt, p95 \(String(format: "%.2f", percentile(errors, 0.95))) pt, max \(String(format: "%.2f", errors.max() ?? 0)) pt; \(bad) of \(compared) frames outside (limit 1 in 200)")
        print("  drawn: \(perGlide.count) glides seen, \(withFrames) compared with the plan, \(moving) moved the cursor layer; \(apply.count) overlay updates for \(index) actions")
        var endError = Double.infinity
        if let end = surface.inner.presentedPoint(agentID) { endError = Double(hypot(end.x - lastTarget.x, end.y - lastTarget.y)) }
        print("  after the last glide the cursor stands \(String(format: "%.2f", endError)) pt from its target (limit 1.5)")
        print("  real pointer: \(shared.moves) changes in \(shared.samples) samples (limit 0 changes; at least 1000 samples); overlay key/main frames: \(keyOrMain) (limit 0); front app changes: \(frontChanges) (limit 0)")
        if shared.interrupted { print("cursor-probe: interrupted (input arrived; Donovan is back). Result discarded: not run"); exit(2) }
        // A run that drew nothing, or sampled nothing, cannot pass.
        let drew = apply.count == index && perGlide.count >= index * 8 / 10 && withFrames >= perGlide.count * 9 / 10 && moving >= perGlide.count * 9 / 10
        let sampled = shared.samples >= 1000
        let onPlan = compared > 0 && bad <= compared / 200 && endError <= 1.5
        if !drew { print("  FAIL: not enough was drawn: expected \(index) overlay updates and a moving, compared glide for nearly every action") }
        if !sampled { print("  FAIL: the pointer was sampled \(shared.samples) times; at least 1000 are needed to say it did not move") }
        if !onPlan { print("  FAIL: the drawn path left the plan, or the cursor did not end on its target") }
        let ok = drew && sampled && onPlan && over15 <= frames / 200 && over2 == 0 && shared.moves == 0 && keyOrMain == 0 && frontChanges == 0 && frames >= 100
        print(ok ? "cursor-probe: pass" : "cursor-probe: FAIL")
        exit(ok ? 0 : 1)
    }
}
