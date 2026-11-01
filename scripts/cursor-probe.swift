// The agent cursor's frame-timing probe (docs/agent-computer-use.md, phase 1b; spec/config.md, the animation bar).
//
//   swift run -c release cursor-probe              100 glides on an offscreen overlay
//   swift run -c release cursor-probe --onscreen   the same on the main display (the cursor is visible)
//   swift run -c release cursor-probe --glides 40  fewer glides
//
// It drives the real director and the real overlay (Core Animation layers in a click-through panel), the way the
// hands do, and records CADisplayLink frame times while 100 glides run (every fifth one is cut short by a new
// target). Passing means: at most 1 frame in 200 over 1.5x the display's frame interval and none over 2x; the
// real pointer never moved (CGEvent location sampled at 1 kHz, zero changes); the overlay never became key or
// main and the front app never changed. It also reports how far the drawn cursor strays from the planned glide.
//
// It runs only when Donovan has been idle 10 minutes (HIDIdleTime >= 600 s, the same number `ioreg -c IOHIDSystem`
// shows), and stops, reporting "not run" or "interrupted", the moment he is back. Exit 0 pass, 1 fail, 2 not run.
import AppKit
import BaneySpacesCore
import BaneySpacesCursor
import QuartzCore

/// Forwards to the real overlay and times each call, so the main-thread cost of an action is known.
final class TimedSurface: CursorSurface {
    let inner: OverlaySurface
    var applySeconds: [Double] = []
    var lastMotion: CursorMotion?
    private var pending = 0.0
    init(_ inner: OverlaySurface) { self.inner = inner }
    private func timed(_ f: () -> Void) {
        let t0 = CACurrentMediaTime(); f(); pending += CACurrentMediaTime() - t0
    }
    func configure(_ agent: String, look: CursorLook) { timed { inner.configure(agent, look: look) } }
    func appear(_ agent: String, at point: CGPoint) { timed { inner.appear(agent, at: point) } }
    func move(_ agent: String, motion: CursorMotion) { lastMotion = motion; timed { inner.move(agent, motion: motion) } }
    func jump(_ agent: String, to point: CGPoint) { timed { inner.jump(agent, to: point) } }
    func act(_ agent: String, effect: CursorEffect, point: CGPoint, frame: CGRect, delay: TimeInterval) {
        timed { inner.act(agent, effect: effect, point: point, frame: frame, delay: delay) }
        applySeconds.append(pending); pending = 0
    }
    func hide(_ agent: String) { timed { inner.hide(agent) } }
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
    var onscreen = false
    let agentID = "probe"
    var surface: TimedSurface!
    var director: CursorDirector!
    var link: AnyObject?
    var stamps: [Double] = []
    var intervals: [Double] = []
    var errors: [Double] = []
    var pointerStart = CGPoint.zero
    var pointerMoves = 0
    var interrupted = false
    var idleAtStart = 0.0
    var frontStart: pid_t = 0
    var frontChanges = 0
    var keyOrMain = 0
    var done = false
    var running = false

    func idle() -> Double {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }

    func pointer() -> CGPoint? { CGEvent(source: nil)?.location }

    func start() {
        if let i = args.firstIndex(of: "--glides"), i + 1 < args.count, let n = Int(args[i + 1]), n > 0 { glides = n }
        onscreen = args.contains("--onscreen")
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
        let real = CursorDisplaySpec(globalFrame: CGRect(x: screen.frame.minX, y: top - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height),
                                     panelFrame: screen.frame, scale: screen.backingScaleFactor)
        // Offscreen: the same size, but the panel sits far to the right of every display.
        let far = NSScreen.screens.map(\.frame.maxX).max()! + 6000
        let off = CursorDisplaySpec(globalFrame: real.globalFrame, panelFrame: CGRect(x: far, y: 0, width: screen.frame.width, height: screen.frame.height), scale: screen.backingScaleFactor)
        let spec = onscreen ? real : off
        let overlay = OverlaySurface(displays: [spec])
        surface = TimedSurface(overlay)
        var host = CursorDirector.Host()
        host.agent = { _ in ("Probe", .working) }
        director = CursorDirector(surface: surface, queue: .main, host: host, idleAfter: 30)
        var env = CursorEnvironment()
        env.current = 9; env.agentWorkspace = 9; env.displays = [spec.globalFrame]
        director.setEnvironment(env)
        pointerStart = pointer() ?? .zero
        frontStart = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0

        // CADisplayLink on the display: one callback per frame.
        let dl = screen.displayLink(target: self, selector: #selector(tick(_:)))
        dl.add(to: .main, forMode: .common)
        link = dl
        // The real pointer, sampled every millisecond off the main thread, so a stall can't hide a move.
        let sampler = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "pointer", qos: .userInteractive))
        sampler.schedule(deadline: .now(), repeating: .milliseconds(1))
        sampler.setEventHandler { [weak self] in
            guard let self, self.running, let p = self.pointer() else { return }
            if p != self.pointerStart { self.pointerMoves += 1; self.pointerStart = p }
            if self.idle() < self.idleAtStart - 5 { self.interrupted = true }
        }
        sampler.resume()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.begin() }
    }

    var index = 0
    var rng = SystemRandomNumberGenerator()

    func begin() {
        running = true
        step()
    }

    /// One action: a new target at least 300 points away. Every fifth is sent 60 ms after the last, mid-glide.
    func step() {
        guard index < glides, !interrupted else { return finish() }
        let size = onscreen ? NSScreen.main!.frame.size : CGSize(width: 1440, height: 900)
        let kinds = ["click", "type", "scroll", "click"]
        let dirs = ["down", "up", "left", "right"]
        var p: CGPoint
        repeat { p = CGPoint(x: CGFloat.random(in: 80...(size.width - 80), using: &rng), y: CGFloat.random(in: 80...(size.height - 80), using: &rng)) }
        while let last = last, hypot(p.x - last.x, p.y - last.y) < 300
        last = p
        let kind = kinds[index % kinds.count]
        let e = HandsActionEvent(kind: kind, ref: "@s1:e\(index)", window: 1, pid: 1, app: "Probe", point: p,
                                 frame: CGRect(x: p.x - 40, y: p.y - 12, width: 80, height: 24), session: agentID, scope: "agent_workspace", workspace: 9,
                                 direction: kind == "scroll" ? dirs[(index / 4) % 4] : nil)
        HandsEvents.willAct(e)
        index += 1
        let cut = index % 5 == 0
        DispatchQueue.main.asyncAfter(deadline: .now() + (cut ? 0.06 : 0.42)) { self.step() }
    }
    var last: CGPoint?

    @available(macOS 14, *)
    @objc func tick(_ link: CADisplayLink) {
        guard running, !done else { return }
        stamps.append(link.timestamp)
        intervals.append(link.targetTimestamp - link.timestamp)
        if NSApp.keyWindow != nil || NSApp.mainWindow != nil || surface.inner.panels.contains(where: { $0.isKeyWindow || $0.isMainWindow || $0.canBecomeKey || $0.canBecomeMain }) { keyOrMain += 1 }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != frontStart { frontChanges += 1; frontStart = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0 }
        // How far the drawn cursor is from the planned glide right now.
        if let m = surface.lastMotion, let drawn = surface.inner.presentedPoint(agentID) {
            let t = CACurrentMediaTime() - (m.start + (CACurrentMediaTime() - ProcessInfo.processInfo.systemUptime)) // seconds into the glide
            if t >= 0, t <= m.duration {
                let i = min(m.points.count - 1, max(0, Int((t / m.step).rounded())))
                errors.append(hypot(drawn.x - m.points[i].x, drawn.y - m.points[i].y))
            }
        }
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
        let deltas = zip(stamps, stamps.dropFirst()).map { $1 - $0 }
        let nominal = percentile(intervals, 0.5)
        let over15 = deltas.filter { $0 > nominal * 1.5 }.count
        let over2 = deltas.filter { $0 > nominal * 2 }.count
        let frames = deltas.count
        let ms = { (x: Double) in String(format: "%.2f", x * 1000) }
        print("cursor-probe: \(index) glides on \(onscreen ? "the main display" : "an offscreen overlay"), \(frames) frames, display \(String(format: "%.0f", 1 / max(nominal, 1e-6))) Hz (interval \(ms(nominal)) ms)")
        print("  frame time: median \(ms(percentile(deltas, 0.5))) ms, p99 \(ms(percentile(deltas, 0.99))) ms, max \(ms(deltas.max() ?? 0)) ms")
        print("  frames over 1.5x the interval: \(over15) of \(frames) (limit 1 in 200 = \(frames / 200)); over 2x: \(over2) (limit 0)")
        let apply = surface.applySeconds
        print("  main thread, per action: median \(ms(percentile(apply, 0.5))) ms, max \(ms(apply.max() ?? 0)) ms (director + layers, off the hands' thread)")
        print("  drawn vs planned position: median \(String(format: "%.2f", percentile(errors, 0.5))) pt, p95 \(String(format: "%.2f", percentile(errors, 0.95))) pt, max \(String(format: "%.2f", errors.max() ?? 0)) pt over \(errors.count) frames")
        print("  real pointer: \(pointerMoves) changes (limit 0); overlay key/main frames: \(keyOrMain) (limit 0); front app changes: \(frontChanges) (limit 0)")
        if interrupted { print("cursor-probe: interrupted (input arrived; Donovan is back). Result discarded: not run"); exit(2) }
        let ok = over15 <= frames / 200 && over2 == 0 && pointerMoves == 0 && keyOrMain == 0 && frontChanges == 0 && frames >= 100
        print(ok ? "cursor-probe: pass" : "cursor-probe: FAIL")
        exit(ok ? 0 : 1)
    }
}
