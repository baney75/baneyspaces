import XCTest
@testable import BaneySpacesCore

// The agent cursor (phase 1b): the glide planner, when it is drawn, the director that drives the overlay, the
// overlay's source rules, and the cost to an action.

final class GlidePlannerTests: XCTestCase {
    let spring = GlideSpring.baneyspaces

    func testAGlideStartsAtTheStartAndSettlesOnTheTarget() {
        let plan = GlidePlan(from: GlideState(position: CGPoint(x: 100, y: 100)), target: CGPoint(x: 700, y: 400), spring: spring)
        XCTAssertEqual(plan.state(at: 0).position, CGPoint(x: 100, y: 100))
        XCTAssertEqual(plan.state(at: plan.duration + 0.01).position, CGPoint(x: 700, y: 400))
        XCTAssertEqual(plan.state(at: plan.duration + 0.01).velocity, .zero)
    }

    func testItArrivesInAboutAHundredAndFiftyMilliseconds() {
        for distance in [60.0, 200, 600, 1500, 3000] {
            let plan = GlidePlan(from: GlideState(position: .zero), target: CGPoint(x: distance, y: 0), spring: spring)
            XCTAssertLessThanOrEqual(plan.arrival, 0.2, "arrives within 200 ms over \(distance) pt")
            XCTAssertGreaterThan(plan.arrival, 0.08, "not a teleport over \(distance) pt")
            XCTAssertLessThanOrEqual(plan.duration, 0.35, "settles quickly over \(distance) pt")
        }
    }

    func testItNeverOvershootsVisibly() {
        let plan = GlidePlan(from: GlideState(position: .zero), target: CGPoint(x: 800, y: 0), spring: spring)
        let peak = plan.samples().map(\.position.x).max()!
        XCTAssertLessThan(peak, 800 * 1.02, "under 2% past the target")
    }

    func testTheClosedFormMatchesItsOwnVelocityForEveryKindOfDamping() {
        for damping in [0.5, 0.85, 1.0, 1.6] {
            let plan = GlidePlan(from: GlideState(position: CGPoint(x: 10, y: 20), velocity: CGVector(dx: 300, dy: -120)),
                                 target: CGPoint(x: 500, y: 90), spring: GlideSpring(response: 0.2, damping: damping))
            for t in [0.01, 0.05, 0.1, 0.2] {
                let h = 1e-5
                let a = plan.state(at: t - h).position, b = plan.state(at: t + h).position
                let v = plan.state(at: t).velocity
                XCTAssertEqual(Double(v.dx), Double(b.x - a.x) / (2 * h), accuracy: 0.5, "dx at \(t) damping \(damping)")
                XCTAssertEqual(Double(v.dy), Double(b.y - a.y) / (2 * h), accuracy: 0.5, "dy at \(t) damping \(damping)")
            }
        }
    }

    func testANewTargetMidGlideKeepsPositionAndVelocity() {
        let first = GlidePlan(from: GlideState(position: CGPoint(x: 50, y: 50)), target: CGPoint(x: 900, y: 200), spring: spring)
        for t in [0.02, 0.05, 0.09] {
            let at = first.state(at: t)
            let next = first.retarget(at: t, to: CGPoint(x: 100, y: 700))
            XCTAssertEqual(next.state(at: 0).position, at.position, "no jump at \(t)")
            XCTAssertEqual(next.state(at: 0).velocity, at.velocity, "no restart at \(t)")
            // A moment later it is still where the old motion carried it, then bends: continuity, not a reset.
            let eps = 0.001
            let moved = next.state(at: eps).position
            XCTAssertEqual(Double(moved.x - at.position.x), Double(at.velocity.dx) * eps, accuracy: 3, "first millisecond follows the old velocity")
            XCTAssertEqual(Double(moved.y - at.position.y), Double(at.velocity.dy) * eps, accuracy: 3)
        }
    }

    func testRetargetingToTheSameTargetDoesNotSlowItDown() {
        let a = GlidePlan(from: GlideState(position: .zero), target: CGPoint(x: 800, y: 0), spring: spring)
        let b = a.retarget(at: 0.05, to: CGPoint(x: 800, y: 0))
        XCTAssertLessThanOrEqual(b.duration + 0.05, a.duration + 0.03, "the same spring, from the same state, settles at the same time")
    }

    func testSamplesRunFromZeroToTheSettleTimeAndEndOnTheTarget() {
        let plan = GlidePlan(from: GlideState(position: .zero), target: CGPoint(x: 500, y: 300), spring: spring)
        let s = plan.samples()
        XCTAssertEqual(s.first?.time, 0)
        XCTAssertEqual(s.last?.time ?? -1, plan.duration, accuracy: 1e-9)
        XCTAssertEqual(s.last?.position, CGPoint(x: 500, y: 300))
        XCTAssertTrue(zip(s, s.dropFirst()).allSatisfy { $0.time < $1.time })
        XCTAssertLessThanOrEqual(s.count, 120, "one short keyframe animation")
    }

    func testAnInstantSpringOrAnAlreadyThereCursorHasNothingToAnimate() {
        XCTAssertEqual(GlidePlan(from: GlideState(position: .zero), target: CGPoint(x: 400, y: 0), spring: .instant).duration, 0)
        XCTAssertEqual(GlidePlan(from: GlideState(position: CGPoint(x: 5, y: 5)), target: CGPoint(x: 5, y: 5), spring: spring).duration, 0)
        XCTAssertEqual(GlidePlan(from: GlideState(position: .zero), target: CGPoint(x: 400, y: 0), spring: .instant).samples().count, 1)
    }

    func testNoGlideRunsLongerThanTheConfigLimit() {
        let slow = GlideSpring(response: 0.6, damping: 2.0)
        XCTAssertLessThanOrEqual(GlidePlan(from: GlideState(position: .zero), target: CGPoint(x: 3000, y: 0), spring: slow).duration, 1.0)
    }

    func testPresetsAndSpeedShapeTheSpring() {
        XCTAssertEqual(GlideSpring.preset("baneyspaces"), .baneyspaces)
        XCTAssertNil(GlideSpring.preset("nonsense"))
        var s = CursorSettings()
        XCTAssertEqual(s.spring, .baneyspaces, "the default is the baneyspaces preset")
        s.speed = 2
        XCTAssertEqual(s.spring.response, GlideSpring.baneyspaces.response / 2, accuracy: 1e-9)
        s.speed = 0
        XCTAssertTrue(s.spring.isInstant, "speed 0 is off")
        s = CursorSettings(); s.preset = "off"
        XCTAssertTrue(s.spring.isInstant)
        s = CursorSettings(); s.response = 0.3; s.damping = 1
        XCTAssertEqual(s.spring, GlideSpring(response: 0.3, damping: 1), "animation.cursor.glide overrides the preset")
        s.response = 99
        XCTAssertEqual(s.spring.response, GlideSpring.responseRange.upperBound, "clamped")
    }

    func testReduceMotionSkipsTheGlideUnlessTheyChoseOtherwise() {
        var s = CursorSettings()
        XCTAssertTrue(s.skipsGlide(reduceMotion: true))
        XCTAssertFalse(s.skipsGlide(reduceMotion: false))
        s.respectReduceMotion = false
        XCTAssertFalse(s.skipsGlide(reduceMotion: true))
    }
}

final class CursorVisibilityTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let frame = CGRect(x: 100, y: 100, width: 80, height: 24)

    func decide(enabled: Bool = true, scope: String, window: Int?, current: Int, agent: Int? = 9, frame: CGRect = CGRect(x: 100, y: 100, width: 80, height: 24)) -> CursorVisibility.Decision {
        CursorVisibility.decide(enabled: enabled, scope: scope, windowWorkspace: window, current: current, agent: agent,
                                frame: frame, displays: [screen])
    }

    func testItShowsOnTheAgentWorkspaceWhenYouLookAtIt() {
        XCTAssertEqual(decide(scope: "agent_workspace", window: 9, current: 9), .show)
    }

    func testItIsHiddenOffTheAgentWorkspace() {
        for current in 1...8 {
            XCTAssertEqual(decide(scope: "agent_workspace", window: 9, current: current), .hidden(.notWatching), "workspace \(current)")
        }
        XCTAssertEqual(decide(scope: "agent_workspace", window: 9, current: 9, agent: nil), .hidden(.notWatching), "no agent workspace")
        XCTAssertEqual(decide(scope: "agent_workspace", window: 4, current: 9), .hidden(.notWatching), "a window that is not on it")
    }

    func testItShowsOverALentWindowWhileItIsOnYourWorkspace() {
        XCTAssertEqual(decide(scope: "lent", window: 3, current: 3), .show)
        XCTAssertEqual(decide(scope: "lent", window: 3, current: 5), .hidden(.notWatching), "a lent window parked on another workspace")
        XCTAssertEqual(decide(scope: "lent", window: nil, current: 3), .hidden(.notWatching))
    }

    func testAnythingElseIsHidden() {
        XCTAssertEqual(decide(scope: "outside_agent_workspace", window: 9, current: 9), .hidden(.notWatching))
        XCTAssertEqual(decide(scope: "", window: 9, current: 9), .hidden(.notWatching))
    }

    func testTurnedOffIsHiddenEverywhere() {
        XCTAssertEqual(decide(enabled: false, scope: "agent_workspace", window: 9, current: 9), .hidden(.disabled))
        XCTAssertEqual(decide(enabled: false, scope: "lent", window: 3, current: 3), .hidden(.disabled))
    }

    func testAFrameThatIsMissingOrOffEveryDisplayIsHidden() {
        XCTAssertEqual(CursorVisibility.decide(enabled: true, scope: "agent_workspace", windowWorkspace: 9, current: 9, agent: 9, frame: nil, displays: [screen]), .hidden(.noFrame))
        XCTAssertEqual(decide(scope: "agent_workspace", window: 9, current: 9, frame: CGRect(x: 5000, y: 4000, width: 50, height: 20)), .hidden(.offscreen), "a parked window's frame")
    }

    func testTheHandsMeasureTheTargetOnlyWhenItWouldBeDrawn() {
        XCTAssertTrue(CursorVisibility.wantsFrame(enabled: true, scope: "agent_workspace", windowWorkspace: 9, current: 9, agent: 9))
        XCTAssertFalse(CursorVisibility.wantsFrame(enabled: true, scope: "agent_workspace", windowWorkspace: 9, current: 2, agent: 9), "no engine call while you are elsewhere")
        XCTAssertFalse(CursorVisibility.wantsFrame(enabled: false, scope: "agent_workspace", windowWorkspace: 9, current: 9, agent: 9))
    }
}

final class CursorThemeTests: XCTestCase {
    func testTheFourThemesShip() {
        XCTAssertEqual(CursorTheme.names, ["default", "minimal", "classic", "omarchy"])
        XCTAssertEqual(CursorTheme.named("OMARCHY")?.name, "omarchy")
        XCTAssertNil(CursorTheme.named("lottie"))
    }

    func testMinimalIsASmallDotAndABadge() {
        let t = CursorTheme.minimal
        XCTAssertEqual(t.glyph, .dot)
        XCTAssertLessThanOrEqual(t.size, 12)
        XCTAssertLessThan(t.size, CursorTheme.standard.size / 2)
    }

    func testOmarchyIsBlockyWithASquareMonospaceBadgeAndFadesOnly() {
        let t = CursorTheme.omarchy
        XCTAssertEqual(t.badgeShape, .square)
        XCTAssertEqual(t.badgeRadius, 0)
        XCTAssertTrue(t.badgeMonospaced)
        XCTAssertEqual(t.focusRadius, 0, "square corners everywhere")
        XCTAssertTrue(t.rippleSquare)
        XCTAssertEqual(t.squish, 1, "no scaling")
        XCTAssertEqual(t.appearScale, 1, "fades only")
        XCTAssertEqual(t.shadowOpacity, 0, "no shadow")
    }

    func testClassicIsTheMacArrowInWhiteAndBlack() {
        XCTAssertEqual(CursorTheme.classic.glyph, .classic)
        XCTAssertEqual(CursorTheme.classic.fill, .light)
    }

    func testEveryThemeHasTheFeaturesTheCompetitionHas() {
        for t in CursorTheme.builtIn {
            XCTAssertGreaterThan(t.rippleDuration, 0, t.name)
            XCTAssertEqual(t.markCount, 3, "the last 3 marks stay: \(t.name)")
            XCTAssertGreaterThan(t.focusWidth, 0, "a focus box: \(t.name)")
            XCTAssertLessThanOrEqual(t.rippleDuration, 1.0, "animations stay under 1000 ms: \(t.name)")
        }
        XCTAssertLessThan(CursorTheme.standard.squish, 1, "a squish on press")
    }

    func testGlyphsPutTheirTipOnTheOrigin() {
        for g in [CursorTheme.Glyph.arrow, .classic, .block] {
            let b = CursorGlyphs.path(g, size: 26).boundingBoxOfPath
            XCTAssertEqual(b.minX, 0, accuracy: 1e-9, "\(g)")
            XCTAssertEqual(b.minY, 0, accuracy: 1e-9, "\(g)")
            XCTAssertLessThanOrEqual(b.height, 26 + 1e-6, "\(g)")
            XCTAssertGreaterThan(b.height, 26 * 0.9, "\(g)")
        }
        let dot = CursorGlyphs.path(.dot, size: 10).boundingBoxOfPath
        XCTAssertEqual(dot.midX, 0, accuracy: 1e-9)
        XCTAssertEqual(dot.midY, 0, accuracy: 1e-9)
    }

    func testTheCursorsColorsAreItsOwnAndStable() {
        XCTAssertEqual(CursorPalette.identityColor(for: "/dev/ttys004"), CursorPalette.identityColor(for: "/dev/ttys004"))
        let colors = Set([DockAgent.State.working, .asking, .failed, .done].map { CursorPalette.status($0) })
        XCTAssertEqual(colors.count, 4, "each status has its own color")
        let hues = Set((0..<40).map { CursorPalette.identityColor(for: "session-\($0)") })
        XCTAssertGreaterThan(hues.count, 4, "different agents land on different hues")
    }
}

final class CursorSettingsTests: XCTestCase {
    func testItIsOnByDefaultWithTheDefaultTheme() {
        let s = CursorSettings()
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(s.resolvedTheme, .standard)
    }

    func testSettingsRoundTripAndAnUnknownThemeFallsBack() throws {
        let d = UserDefaults(suiteName: "cursor-tests-\(UUID().uuidString)")!
        var s = CursorSettings(); s.enabled = false; s.theme = "omarchy"; s.speed = 1.5
        s.save(to: d)
        XCTAssertEqual(CursorSettings.load(from: d), s)
        s.theme = "gone"
        XCTAssertEqual(s.resolvedTheme, .standard)
        XCTAssertEqual(CursorSettings.load(from: UserDefaults(suiteName: "cursor-empty-\(UUID().uuidString)")!), CursorSettings())
    }

    func testTheConfigFileSetsTheCursorsKeys() {
        let f = CursorConfigFile.parse("""
        # comment
        [behavior.cursor]
        enabled = false   # off here
        theme = "minimal"

        [animation]
        preset = "snappy"
        speed = 1.25
        respect_reduce_motion = false

        [animation.cursor.glide]
        curve = "spring"
        response = 0.2
        damping = 0.9
        [other]
        enabled = true
        """)
        XCTAssertEqual(f.enabled, false)
        XCTAssertEqual(f.theme, "minimal")
        XCTAssertEqual(f.preset, "snappy")
        XCTAssertEqual(f.speed, 1.25)
        XCTAssertEqual(f.respectReduceMotion, false)
        XCTAssertEqual(f.response, 0.2)
        XCTAssertEqual(f.damping, 0.9)
        let s = CursorSettings().applying(f)
        XCTAssertFalse(s.enabled)
        XCTAssertEqual(s.theme, "minimal")
    }

    func testABadLineNeverSwitchesTheCursorOff() {
        let f = CursorConfigFile.parse("[behavior.cursor]\nenabled = maybe\ntheme = 7\nnonsense\n[behavior\nspeed = x\n")
        XCTAssertTrue(f.isEmpty)
        XCTAssertEqual(CursorSettings().applying(f), CursorSettings())
    }

    func testDottedKeysAndTheConfigPath() {
        XCTAssertEqual(CursorConfigFile.parse("behavior.cursor.enabled = false\n").enabled, false)
        XCTAssertEqual(CursorConfigFile.path(environment: ["XDG_CONFIG_HOME": "/x"], home: "/h"), "/x/baneyspaces/config.toml")
        XCTAssertEqual(CursorConfigFile.path(environment: [:], home: "/h"), "/h/.config/baneyspaces/config.toml")
    }

    func testEveryScrollDirectionAndActionKindHasAnEffect() {
        XCTAssertEqual(CursorEffect.of(kind: "click", direction: nil), .click)
        XCTAssertEqual(CursorEffect.of(kind: "toggle", direction: nil), .click)
        XCTAssertEqual(CursorEffect.of(kind: "type", direction: nil), .type)
        XCTAssertEqual(CursorEffect.of(kind: "set-value", direction: nil), .type)
        XCTAssertEqual(CursorEffect.of(kind: "scroll", direction: "up"), .scroll(dx: 0, dy: -1))
        XCTAssertEqual(CursorEffect.of(kind: "scroll", direction: "left"), .scroll(dx: -1, dy: 0))
        XCTAssertNil(CursorEffect.of(kind: "press", direction: nil))
    }
}

/// Records what the director asked the overlay to do.
final class FakeSurface: CursorSurface {
    enum Call: Equatable {
        case configure(String, String)
        case appear(String, CGPoint)
        case move(String, CGPoint)
        case jump(String, CGPoint)
        case act(String, CursorEffect, CGPoint, TimeInterval)
        case hide(String)
    }
    private let lock = NSLock()
    private var log: [Call] = []
    var motions: [CursorMotion] = []
    /// What each call costs, to prove the action doesn't wait for it.
    var cost: TimeInterval = 0
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return log }
    private func note(_ c: Call) { if cost > 0 { Thread.sleep(forTimeInterval: cost) }; lock.lock(); log.append(c); lock.unlock() }
    func configure(_ agent: String, look: CursorLook) { note(.configure(agent, look.name)) }
    func appear(_ agent: String, at point: CGPoint) { note(.appear(agent, point)) }
    func move(_ agent: String, motion: CursorMotion) { lock.lock(); motions.append(motion); lock.unlock(); note(.move(agent, motion.target)) }
    func jump(_ agent: String, to point: CGPoint) { note(.jump(agent, point)) }
    func act(_ agent: String, effect: CursorEffect, point: CGPoint, frame: CGRect, delay: TimeInterval) { note(.act(agent, effect, point, delay)) }
    func hide(_ agent: String) { note(.hide(agent)) }
}

final class CursorDirectorTests: XCTestCase {
    var clock = 100.0
    let queue = DispatchQueue(label: "cursor-tests")
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func make(surface: FakeSurface = FakeSurface(), idle: TimeInterval = 60) -> (CursorDirector, FakeSurface) {
        var host = CursorDirector.Host()
        host.now = { [unowned self] in self.clock }
        host.agent = { session in (session == "b" ? "Grok" : "Claude", .working) }
        let d = CursorDirector(surface: surface, queue: queue, host: host, idleAfter: idle)
        var env = CursorEnvironment()
        env.current = 9; env.agentWorkspace = 9; env.displays = [screen]
        d.setEnvironment(env)
        return (d, surface)
    }

    func event(_ kind: String = "click", at p: CGPoint, session: String = "a", scope: String = "agent_workspace", workspace: Int? = 9, window: UInt32 = 7) -> HandsActionEvent {
        HandsActionEvent(kind: kind, ref: "@s1:e1", window: window, pid: 1, app: "TextEdit", point: p,
                         frame: CGRect(x: p.x - 30, y: p.y - 10, width: 60, height: 20), session: session, scope: scope, workspace: workspace)
    }

    func drain() { queue.sync {} }

    func testTheFirstActionAppearsAtTheTargetThenGlidesFromThereToTheNext() {
        let (d, s) = make()
        d.handsWillAct(event(at: CGPoint(x: 200, y: 200))); drain()
        clock += 1
        d.handsWillAct(event(at: CGPoint(x: 900, y: 500))); drain()
        let c = s.calls
        XCTAssertEqual(c.first, .configure("a", "Claude"))
        XCTAssertTrue(c.contains(.appear("a", CGPoint(x: 200, y: 200))))
        XCTAssertTrue(c.contains(.move("a", CGPoint(x: 900, y: 500))))
        XCTAssertEqual(s.motions.last?.points.first, CGPoint(x: 200, y: 200), "the glide starts at the last spot")
        XCTAssertEqual(s.motions.last?.points.last, CGPoint(x: 900, y: 500))
    }

    func testANewTargetMidGlideStartsAtTheCurrentPositionAndVelocity() {
        let (d, s) = make()
        d.handsWillAct(event(at: CGPoint(x: 100, y: 100))); drain()
        clock += 1
        d.handsWillAct(event(at: CGPoint(x: 1000, y: 400))); drain()
        let first = GlidePlan(from: GlideState(position: CGPoint(x: 100, y: 100)), target: CGPoint(x: 1000, y: 400), spring: .baneyspaces)
        clock += 0.05
        let expected = first.state(at: 0.05)
        d.handsWillAct(event(at: CGPoint(x: 300, y: 800))); drain()
        let next = s.motions.last!
        XCTAssertEqual(next.points.first!.x, expected.position.x, accuracy: 1e-6, "no jump")
        XCTAssertEqual(next.points.first!.y, expected.position.y, accuracy: 1e-6)
        // The new glide is the old plan retargeted: same position and velocity at the hand-over, so no restart from rest.
        let retargeted = first.retarget(at: 0.05, to: CGPoint(x: 300, y: 800)).samples()
        XCTAssertEqual(next.points.count, retargeted.count)
        for (a, b) in zip(next.points, retargeted.map(\.position)) {
            XCTAssertEqual(a.x, b.x, accuracy: 1e-6); XCTAssertEqual(a.y, b.y, accuracy: 1e-6)
        }
        XCTAssertNotEqual(expected.velocity, .zero, "it was moving when the new target came")
    }

    func testTheRippleWaitsForTheCursorToArrive() {
        let (d, s) = make()
        d.handsWillAct(event(at: CGPoint(x: 100, y: 100))); drain()
        clock += 1
        d.handsWillAct(event(at: CGPoint(x: 1000, y: 400))); drain()
        guard case .act(_, .click, _, let delay)? = s.calls.last else { return XCTFail("no act") }
        XCTAssertEqual(delay, s.motions.last!.arrival, accuracy: 1e-9)
        XCTAssertGreaterThan(delay, 0.05)
    }

    func testReduceMotionJumpsInsteadOfGliding() {
        let (d, s) = make()
        var env = CursorEnvironment(); env.current = 9; env.agentWorkspace = 9; env.displays = [screen]; env.reduceMotion = true
        d.setEnvironment(env)
        d.handsWillAct(event(at: CGPoint(x: 100, y: 100))); drain()
        clock += 1
        d.handsWillAct(event(at: CGPoint(x: 1000, y: 400))); drain()
        XCTAssertTrue(s.motions.isEmpty)
        XCTAssertTrue(s.calls.contains(.jump("a", CGPoint(x: 1000, y: 400))))
        guard case .act(_, _, _, let delay)? = s.calls.last else { return XCTFail() }
        XCTAssertEqual(delay, 0)
    }

    func testNothingIsDrawnWhenYouAreNotOnTheAgentWorkspace() {
        let (d, s) = make()
        var env = CursorEnvironment(); env.current = 2; env.agentWorkspace = 9; env.displays = [screen]
        d.setEnvironment(env)
        XCTAssertFalse(d.handsWantsFrame(scope: "agent_workspace", workspace: 9), "the hands don't even measure the target")
        d.handsWillAct(event(at: CGPoint(x: 200, y: 200))); drain()
        XCTAssertTrue(s.calls.isEmpty, "no layers touched while you look elsewhere")
    }

    func testALentWindowShowsTheCursorOnYourWorkspace() {
        let (d, s) = make()
        var env = CursorEnvironment(); env.current = 3; env.agentWorkspace = 9; env.displays = [screen]
        d.setEnvironment(env)
        XCTAssertTrue(d.handsWantsFrame(scope: "lent", workspace: 3))
        d.handsWillAct(event(at: CGPoint(x: 300, y: 300), scope: "lent", workspace: 3)); drain()
        XCTAssertTrue(s.calls.contains(.appear("a", CGPoint(x: 300, y: 300))))
    }

    func testLeavingTheAgentWorkspaceHidesTheCursorAtOnce() {
        let (d, s) = make()
        d.handsWillAct(event(at: CGPoint(x: 200, y: 200))); drain()
        var env = CursorEnvironment(); env.current = 4; env.agentWorkspace = 9; env.displays = [screen]
        d.setEnvironment(env); drain()
        XCTAssertEqual(s.calls.last, .hide("a"))
        // Coming back, an action appears at its target: where it stood before is no use, the windows were parked.
        env.current = 9
        d.setEnvironment(env)
        clock += 1
        d.handsWillAct(event(at: CGPoint(x: 700, y: 300))); drain()
        XCTAssertEqual(s.calls.last.map { if case .act = $0 { return true } else { return false } }, true)
        XCTAssertTrue(s.calls.contains(.appear("a", CGPoint(x: 700, y: 300))))
    }

    func testTurningItOffHidesItAndStopsMeasuring() {
        let (d, s) = make()
        d.handsWillAct(event(at: CGPoint(x: 200, y: 200))); drain()
        var env = CursorEnvironment(); env.current = 9; env.agentWorkspace = 9; env.displays = [screen]; env.settings.enabled = false
        d.setEnvironment(env); drain()
        XCTAssertEqual(s.calls.last, .hide("a"))
        XCTAssertFalse(d.handsWantsFrame(scope: "agent_workspace", workspace: 9))
    }

    func testTwoAgentsOnTheSameWorkspaceKeepTheirOwnCursorAndName() {
        let (d, s) = make()
        d.handsWillAct(event(at: CGPoint(x: 200, y: 200), session: "a")); drain()
        d.handsWillAct(event(at: CGPoint(x: 600, y: 300), session: "b")); drain()
        XCTAssertTrue(s.calls.contains(.configure("a", "Claude")))
        XCTAssertTrue(s.calls.contains(.configure("b", "Grok")))
        XCTAssertTrue(s.calls.contains(.appear("a", CGPoint(x: 200, y: 200))))
        XCTAssertTrue(s.calls.contains(.appear("b", CGPoint(x: 600, y: 300))))
    }

    func testAnIdleCursorFadesAndComesBackWhereItStood() {
        let (d, s) = make(idle: 0.05)
        d.handsWillAct(event(at: CGPoint(x: 200, y: 200))); drain()
        Thread.sleep(forTimeInterval: 0.2); drain()
        XCTAssertEqual(s.calls.last, .hide("a"))
        clock += 30
        d.handsWillAct(event(at: CGPoint(x: 800, y: 500))); drain()
        XCTAssertTrue(s.calls.contains(.appear("a", CGPoint(x: 200, y: 200))), "it reappears at its last spot")
        XCTAssertEqual(s.motions.last?.points.first, CGPoint(x: 200, y: 200), "and glides from there")
    }

    func testTheLastMarkIsKeptForShotCursor() {
        let (d, _) = make()
        d.handsWillAct(event(at: CGPoint(x: 250, y: 260), window: 42)); drain()
        XCTAssertEqual(d.lastMark(window: 42)?.point, CGPoint(x: 250, y: 260))
        XCTAssertNil(d.lastMark(window: 43))
        clock += 31
        XCTAssertNil(d.lastMark(window: 42), "only a recent action")
    }

    func testTheNameIsShortenedForTheBadge() {
        var host = CursorDirector.Host()
        host.agent = { _ in (String(repeating: "x", count: 60), .working) }
        let s = FakeSurface()
        let d = CursorDirector(surface: s, queue: queue, host: host)
        var env = CursorEnvironment(); env.current = 9; env.agentWorkspace = 9; env.displays = [screen]
        d.setEnvironment(env)
        d.handsWillAct(event(at: CGPoint(x: 200, y: 200))); drain()
        guard case .configure(_, let name)? = s.calls.first else { return XCTFail() }
        XCTAssertLessThanOrEqual(name.count, CursorDirector.maxNameLength)
    }

    // MARK: the action never waits

    func testTheActionDoesNotWaitForTheGlide() {
        let slow = FakeSurface()
        slow.cost = 0.25   // every draw call takes a quarter second
        let (d, _) = make(surface: slow)
        HandsEvents.setListener(d)
        defer { HandsEvents.setListener(nil) }
        let t0 = ProcessInfo.processInfo.systemUptime
        for i in 0..<5 {
            HandsEvents.willAct(event(at: CGPoint(x: 100 + Double(i) * 100, y: 300)))
        }
        let spent = ProcessInfo.processInfo.systemUptime - t0
        XCTAssertLessThan(spent, 0.05, "five actions reported while the overlay is slow: \(spent) s")
        XCTAssertTrue(slow.calls.count < 3, "the overlay has not caught up yet, and the actions are already on their way")
        drain()
        XCTAssertGreaterThan(slow.calls.count, 5)
    }
}

/// A stand-in for the router's per-action path: some work to resolve and read, the target's bounds when the
/// cursor wants them, the report to the cursor, then the action.
private struct FakeHands {
    var resolve: TimeInterval = 0.004
    var boundsRead: TimeInterval = 0.002
    var act: TimeInterval = 0.012
    var readback: TimeInterval = 0.008

    func spin(_ t: TimeInterval) { let end = ProcessInfo.processInfo.systemUptime + t; while ProcessInfo.processInfo.systemUptime < end {} }

    func run(_ e: HandsActionEvent) {
        spin(resolve)
        var event = e
        if HandsEvents.wantsFrame(scope: e.scope, workspace: e.workspace) { spin(boundsRead) } else { event.frame = nil }
        HandsEvents.willAct(event)
        spin(act)
        spin(readback)
    }
}

final class CursorOverheadTests: XCTestCase {
    func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }

    func testTheCursorAddsUnderFiveMillisecondsToTheMedianAction() {
        let hands = FakeHands()
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let queue = DispatchQueue(label: "overhead")
        let director = CursorDirector(surface: FakeSurface(), queue: queue)
        var env = CursorEnvironment(); env.current = 9; env.agentWorkspace = 9; env.displays = [screen]
        director.setEnvironment(env)
        func timed(_ n: Int, listening: Bool) -> [Double] {
            HandsEvents.setListener(listening ? director : nil)
            defer { HandsEvents.setListener(nil) }
            return (0..<n).map { i in
                let p = CGPoint(x: 100 + Double(i % 20) * 50, y: 200 + Double(i % 7) * 60)
                let e = HandsActionEvent(kind: i % 3 == 0 ? "type" : "click", ref: "@s1:e1", window: 7, pid: 1, app: "TextEdit", point: p,
                                         frame: CGRect(x: p.x - 30, y: p.y - 10, width: 60, height: 20), session: "a", scope: "agent_workspace", workspace: 9)
                let t0 = ProcessInfo.processInfo.systemUptime
                hands.run(e)
                return (ProcessInfo.processInfo.systemUptime - t0) * 1000
            }
        }
        _ = timed(20, listening: true)   // warm up
        let without = median(timed(200, listening: false))
        let with = median(timed(200, listening: true))
        queue.sync {}
        print("CURSOR OVERHEAD (modelled hands: resolve 4 + bounds 2 + act 12 + readback 8 ms): median action without the cursor \(String(format: "%.2f", without)) ms, with it \(String(format: "%.2f", with)) ms, added \(String(format: "%.2f", with - without)) ms")
        XCTAssertLessThan(with - without, 5, "under 5 ms added to the median action")
        XCTAssertGreaterThan(with - without, 0, "and the measurement saw the bounds read")
    }

    func testWithTheCursorHiddenTheActionPaysNothing() {
        let hands = FakeHands()
        let director = CursorDirector(surface: FakeSurface(), queue: DispatchQueue(label: "hidden"))
        var env = CursorEnvironment(); env.current = 2; env.agentWorkspace = 9
        director.setEnvironment(env)
        HandsEvents.setListener(director)
        defer { HandsEvents.setListener(nil) }
        XCTAssertFalse(HandsEvents.wantsFrame(scope: "agent_workspace", workspace: 9))
        let e = HandsActionEvent(kind: "click", ref: "r", window: 1, pid: 1, app: "A", point: nil, session: "a", scope: "agent_workspace", workspace: 9)
        let t0 = ProcessInfo.processInfo.systemUptime
        for _ in 0..<100 { hands.run(e) }
        let each = (ProcessInfo.processInfo.systemUptime - t0) * 10
        XCTAssertLessThan(each, 24.5, "no bounds read: just the modelled \(hands.resolve * 1000 + hands.act * 1000 + hands.readback * 1000) ms")
    }
}

final class CursorSourceTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static func code(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map { $0.components(separatedBy: "//")[0] }.joined(separator: "\n")
    }
    static let renderer = ["CursorPanel", "AgentCursor", "OverlaySurface", "ShotComposite"].map { "Sources/BaneySpacesCursor/\($0).swift" }

    func testTheOverlayCanNeverBecomeKeyOrMainAndIgnoresTheMouse() throws {
        let panel = try Self.code("Sources/BaneySpacesCursor/CursorPanel.swift")
        XCTAssertTrue(panel.contains("final class CursorPanel: NSPanel"))
        XCTAssertTrue(panel.contains("override var canBecomeKey: Bool { false }"))
        XCTAssertTrue(panel.contains("override var canBecomeMain: Bool { false }"))
        XCTAssertTrue(panel.contains("ignoresMouseEvents = true"))
        XCTAssertTrue(panel.contains(".nonactivatingPanel"))
        XCTAssertFalse(panel.contains("ignoresMouseEvents = false"))
        XCTAssertTrue(panel.contains("orderFrontRegardless()"), "shown without activating")
        XCTAssertTrue(panel.contains("sharingType = .none"), "out of captures unless `agent shot --cursor`")
    }

    func testTheRendererNeverActivatesRaisesPostsInputOrMovesThePointer() throws {
        let banned = ["makeKey", "makeMain", "NSApp.activate", ".activate(", "activate(ignoringOtherApps", "orderFront(", "makeKeyAndOrderFront", "CGEventPost", "CGEvent(",
                      "CGWarpMouseCursorPosition", "CGDisplayMoveCursorToPoint", "SLEventPost", "postToPid", "AXUIElement", "NSEvent.addGlobalMonitor", "NSEvent.addLocalMonitor",
                      "isKeyWindow", "SetFrontProcess", "NSHostingView", "import SwiftUI"]
        for file in Self.renderer + ["Sources/BaneySpaces/Cursor/CursorController.swift", "Sources/BaneySpacesCore/Cursor/CursorDirector.swift"] {
            let text = try Self.code(file)
            for b in banned { XCTAssertFalse(text.contains(b), "\(file) must not contain \(b)") }
        }
    }

    func testTheOverlayIsDrawnWithCoreAnimationLayersAndNoPerFrameWork() throws {
        for file in Self.renderer {
            let text = try Self.code(file)
            for b in ["CADisplayLink", "CVDisplayLink", "Timer.scheduled", "draw(_ dirtyRect", "needsDisplay", "layoutSubtreeIfNeeded", "NSHostingController"] {
                XCTAssertFalse(text.contains(b), "\(file) must not contain \(b)")
            }
        }
        let layers = try Self.code("Sources/BaneySpacesCursor/AgentCursor.swift")
        XCTAssertTrue(layers.contains("CAShapeLayer()"))
        XCTAssertTrue(layers.contains("CATextLayer()"))
        XCTAssertTrue(layers.contains("CAKeyframeAnimation(keyPath: \"position\")"), "a glide is one keyframe animation for the compositor")
        XCTAssertTrue(layers.contains("shadowPath"), "shadows have a path, so no off-screen pass per frame")
        XCTAssertTrue(layers.contains("markOrder"), "the last few marks are kept")
    }

    func testOnlyTheHandsListenerFeedsTheCursorAndItQueuesInsteadOfWaiting() throws {
        let director = try Self.code("Sources/BaneySpacesCore/Cursor/CursorDirector.swift")
        let will = try XCTUnwrap(HandsSourceTests.block(after: "public func handsWillAct(", in: director))
        XCTAssertTrue(will.contains("queue.async"))
        XCTAssertFalse(will.contains("queue.sync"))
        XCTAssertFalse(will.contains("semaphore"))
    }

    func testTheRouterPassesTheTargetFrameAtDispatchAndMeasuresOnlyOnRequest() throws {
        let router = try Self.code("Sources/BaneySpaces/Hands/HandsRouter.swift")
        let wants = try XCTUnwrap(router.range(of: "HandsEvents.wantsFrame("))
        let will = try XCTUnwrap(router.range(of: "HandsEvents.willAct("))
        let act = try XCTUnwrap(router.range(of: "HandsEngine.shared.act("))
        XCTAssertTrue(wants.lowerBound < will.lowerBound && will.lowerBound < act.lowerBound)
        XCTAssertTrue(router.contains("frame: frame"))
        XCTAssertTrue(router.contains("scope: scope.reason"))
        XCTAssertTrue(router.contains("budget: HandsEngine.Budget.bounds"), "a hung app can't hold the cursor's measurement for long")
    }

    func testAShotLeavesTheCursorOutUnlessAskedAndTheOverlayIsOutOfCaptures() throws {
        let router = try Self.code("Sources/BaneySpaces/Hands/HandsRouter.swift")
        XCTAssertTrue(router.contains("req.bool(\"cursor\") ? host.cursorMark(w.id) : nil"), "default is out")
        let shot = HandsTools.tool(verb: "shot")
        XCTAssertNotNil(shot?.params.first { $0.name == "cursor" && $0.kind == .boolean })
        XCTAssertFalse(shot?.params.first { $0.name == "cursor" }?.required ?? true)
    }

    func testTheCursorHasASwitchInSettingsAndTheCommandLine() throws {
        let deck = try Self.code("Sources/BaneySpaces/Deck/DeckController.swift")
        XCTAssertTrue(deck.contains("case \"cursor\":"))
        XCTAssertTrue(deck.contains("CursorController.shared.command(args)"))
        let setup = try Self.code("Sources/BaneySpaces/Setup.swift")
        XCTAssertTrue(setup.contains("Show each agent's cursor"))
        let controller = try Self.code("Sources/BaneySpaces/Cursor/CursorController.swift")
        XCTAssertTrue(controller.contains("case \"on\":") && controller.contains("case \"off\":") && controller.contains("case \"theme\":"))
    }

    func testTheCursorHidesTheMomentYouLeaveTheAgentWorkspace() throws {
        let app = try Self.code("Sources/BaneySpaces/AppDelegate.swift")
        let hook = try XCTUnwrap(HandsSourceTests.block(after: "spaces.onChange = ", in: app))
        XCTAssertTrue(hook.contains("CursorController.shared.environmentChanged()"))
    }
}
