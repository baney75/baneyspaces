import AppKit
import BaneySpacesCore

/// Routes shut for an app after it misbehaved (came to the front by itself, or did nothing with background input
/// twice), for as long as BaneySpaces runs.
final class BackgroundBreaker {
    static let shared = BackgroundBreaker()
    private let lock = NSLock()
    private var breaker = RouteBreaker()
    func block(bundle: String, kind: InputKind) -> RouteBlock? { lock.lock(); defer { lock.unlock() }; return breaker.block(bundle: bundle, kind: kind) }
    func update(_ change: (inout RouteBreaker) -> Void) { lock.lock(); change(&breaker); lock.unlock() }
}

/// What the post on the process queue tells the caller waiting outside it.
private final class PostOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var _report: BackgroundPoster.Report?
    private var _front = FrontChange.same
    private var _pointer = PostGuard.PointerVerdict.unchecked
    func set(report: BackgroundPoster.Report, front: FrontChange, pointer: PostGuard.PointerVerdict) {
        lock.lock(); _report = report; _front = front; _pointer = pointer; lock.unlock()
    }
    var report: BackgroundPoster.Report? { lock.lock(); defer { lock.unlock() }; return _report }
    var front: FrontChange { lock.lock(); defer { lock.unlock() }; return _front }
    var pointer: PostGuard.PointerVerdict { lock.lock(); defer { lock.unlock() }; return _pointer }
}

/// Phase 4: keys and a pointer, posted to one process that is not in front, with proof read back from the window.
/// The order for every action: resolve the window, read it, then on the process's queue check scope and facts again,
/// choose one route (`BackgroundPlanner`), post once, and read the same window back. No proof is `unverified`,
/// retry never; a second route is never tried after a post.
extension HandsRouter {
    // MARK: verbs

    func press(_ req: HandsRequest) -> HandsEnvelope {
        let chords: [KeyChord]
        switch KeyParse.sequence(req.string("key") ?? "") {
        case .failure(let e): return .failure(e)
        case .success(let c): chords = c
        }
        switch resolve(req.string("ref")) {
        case .failure(let e): return .failure(e)
        case .success(let (w, scope)):
            return background(w, scope, name: "press", kind: .keys, ref: req.string("ref"), chords: chords, path: [], drag: false)
        }
    }

    func clickAt(_ req: HandsRequest) -> HandsEnvelope {
        guard let x = req.int("x"), let y = req.int("y") else { return .failure(pointArguments("click-at --window <id> --x <points> --y <points>")) }
        return pointer(req, path: [CGPoint(x: x, y: y)], drag: false, name: "click-at")
    }

    func drag(_ req: HandsRequest) -> HandsEnvelope {
        guard let x = req.int("x"), let y = req.int("y"), let x2 = req.int("x2"), let y2 = req.int("y2") else {
            return .failure(pointArguments("drag --window <id> --x <points> --y <points> --x2 <points> --y2 <points> [--steps N]"))
        }
        let path = PointerPath.line(from: CGPoint(x: x, y: y), to: CGPoint(x: x2, y: y2), steps: req.int("steps") ?? 12)
        return pointer(req, path: path, drag: true, name: "drag")
    }

    private func pointArguments(_ usage: String) -> HandsError {
        HandsError(.badArguments, "the point is missing", suggestion: "usage: baneyspaces agent " + usage, retry: .safe)
    }

    private func pointer(_ req: HandsRequest, path: [CGPoint], drag: Bool, name: String) -> HandsEnvelope {
        guard req.int("window") != nil else { return .failure(pointArguments("\(name) --window <id> ...")) }
        switch target(req) {
        case .failure(let e): return .failure(e)
        case .success(let (w, scope, _)):
            return background(w, scope, name: name, kind: .pointer, ref: nil, chords: [], path: path, drag: drag)
        }
    }

    // MARK: the pipeline

    private func frontPid() -> Int32? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    private func background(_ w: HandsWindow, _ scope: ScopeDecision, name: String, kind: InputKind, ref: String?,
                            chords: [KeyChord], path: [CGPoint], drag: Bool) -> HandsEnvelope {
        // The mark covers the whole action: the readings, the queue wait, the post and the proof, and a short tail.
        let token = AgentActivity.shared.begin(pid: w.pid, window: w.id)
        defer { AgentActivity.shared.end(token) }
        let scopeCheck = check(w, ref: ref)
        if let e = scopeCheck() { return .failure(e) }
        guard let server = BackgroundAX.serverWindow(w.id) else {
            return .failure(HandsError(.windowNotFound, "the window server does not list window \(w.id)", suggestion: "Run `baneyspaces agent windows` and try again.", retry: .safe))
        }

        // Readings before, outside the process queue (the engine's calls use it).
        func refReading() -> ElementReading? {
            guard let ref, let v = valueOf(w, ref) else { return nil }
            return ElementReading.text(window: w.id, identity: ref, value: v)
        }
        func focusReading() -> ElementReading? { BackgroundAX.focus(pid: w.pid).element.map { BackgroundAX.reading(of: $0) } }
        func tree() -> JSONValue? {
            if case .success(let d) = read(w, interactive: false, compact: true, register: false) { return d["tree"] }
            return nil
        }
        func capture() -> WindowShot.Pixels? { kind == .pointer ? WindowShot.pixels(window: w.id, check: scopeCheck) : nil }

        let refBefore = refReading(), focusBefore = focusReading(), treeBefore = tree(), shotBefore = capture()
        let verifier: VerifierPlan = {
            switch (treeBefore != nil, shotBefore != nil) {
            case (true, true): return .axAndPixels
            case (true, false): return .ax
            case (false, true): return .pixels
            case (false, false): return .none
            }
        }()

        // The agent cursor (phase 1b) learns where the hands are working.
        if HandsEvents.hasListener {
            let at = path.first.map { PointerPath.screenPoint(local: $0, frame: server.frame) }
            HandsEvents.willAct(HandsActionEvent(kind: name, ref: ref ?? "", window: w.id, pid: w.pid, app: w.app, point: at))
        }

        // On the process's queue, at the moment of execution: scope again (the check), the facts again, one route.
        let outcome = PostOutcome()
        let reply = HandsEngine.shared.perform(window: w, check: scopeCheck) { [self] cancelled in
            guard let (facts, frame) = gatherFacts(w, kind: kind, verifier: verifier, path: path) else {
                return .failed(HandsError(.windowNotFound, "window \(w.id) is gone", suggestion: "Run `baneyspaces agent windows` and take a new snapshot.", retry: .afterSnapshot))
            }
            let permit: BackgroundPermit
            switch BackgroundPlanner.plan(facts) {
            case .failure(let e): return .failed(e)
            case .success(let p): permit = p
            }
            let frontStart = frontPid()
            let pointerBefore = BackgroundPoster.pointerLocation()
            let between: () -> HandsError? = { [self] in
                if cancelled() { return HandsError(.timeout, "the caller stopped waiting", suggestion: "Read the element back before trying again.", retry: .never) }
                switch PostGuard.front(start: frontStart, now: frontPid(), target: w.pid) {
                case .same: return nil
                case .targetCameForward: return BackgroundRefusal.blocked(w.app, .selfActivates)
                case .other(let p): return BackgroundRefusal.frontChanged(w.app, to: p)
                }
            }
            let report = kind == .keys
                ? BackgroundPoster.keys(chords, permit: permit, between: between)
                : BackgroundPoster.pointer(path: path, frame: frame, drag: drag, permit: permit, between: between)
            outcome.set(report: report, front: PostGuard.front(start: frontStart, now: frontPid(), target: w.pid),
                        pointer: PostGuard.pointer(before: pointerBefore, after: BackgroundPoster.pointerLocation()))
            return .ok(.object(["posted": .int(report.events)]))
        }
        switch reply {
        case .failed(let e): return .failure(e)
        case .ok: break
        }
        guard let report = outcome.report else {
            return .failure(HandsError(.engineError, "the post left no record", suggestion: "Read the element back before trying again.", retry: .never))
        }

        // What the post itself showed. An app that came forward by itself is shut out for the run.
        if outcome.front == .targetCameForward {
            BackgroundBreaker.shared.update { $0.selfActivated(bundle: w.bundle, kind: kind) }
            return .failure(BackgroundRefusal.blocked(w.app, .selfActivates))
        }
        if let stopped = report.stopped { return .failure(stopped) }
        if case .other(let p) = outcome.front { return .failure(BackgroundRefusal.frontChanged(w.app, to: p)) }
        if let moved = outcome.pointer.error { return .failure(moved) }

        // The proof: the same window read again, until it shows a change or the time is up.
        let deadline = Date().addingTimeInterval(kind == .keys ? 1.5 : 1.2)
        var verdict = DeliveryVerdict(verified: false, basis: "no_reading")
        var diff: AXDiff?
        var pixels: PixelChange?
        repeat {
            Thread.sleep(forTimeInterval: 0.15)
            let refAfter = refReading(), focusAfter = focusReading()
            if let b = treeBefore, let a = tree() { diff = AXDiff.between(b, a) }
            if let b = shotBefore, let a = capture(), a.width == b.width, a.height == b.height {
                let region = PointerPath.region(path: path, margin: 14, scale: b.scale, width: b.width, height: b.height)
                pixels = PixelDiff.compare(before: b.rgba, after: a.rgba, width: b.width, height: b.height, region: region)
            }
            let ref = (before: refBefore, after: refAfter), focus = (before: focusBefore, after: focusAfter)
            verdict = kind == .keys
                ? DeliveryProof.keys(target: w.id, ref: ref, focus: focus, treeChanged: diff?.changed, pixels: pixels)
                : DeliveryProof.pointer(target: w.id, ref: ref, focus: focus, treeChanged: diff?.changed, pixels: pixels)
        } while !verdict.verified && Date() < deadline

        guard verdict.verified else {
            BackgroundBreaker.shared.update { $0.noEffect(bundle: w.bundle, kind: kind) }
            return .failure(BackgroundRefusal.unverified(basis: verdict.basis))
        }
        BackgroundBreaker.shared.update { $0.proved(bundle: w.bundle, kind: kind) }
        var evidence: [String: JSONValue] = ["kind": "delivery_proof", "basis": .string(verdict.basis),
                                             "pointer": .string(outcome.pointer.label), "front": "unchanged"]
        if let diff { evidence["ax"] = diff.json(limit: 3) }
        if let p = pixels {
            evidence["pixels"] = .object(["inside_changed": .int(p.insideChanged), "inside_total": .int(p.insideTotal),
                                          "outside_changed": .int(p.outsideChanged), "outside_total": .int(p.outsideTotal)])
        }
        return .success(.object([
            "action": .string(name), "verified": true, "route": .string(kind == .keys ? BackgroundRoute.pidKeys.rawValue : BackgroundRoute.windowPointer.rawValue),
            "transport": .string(report.transport.rawValue), "events": .int(report.events), "evidence": .object(evidence),
            "target": targetJSON(w, scope),
        ]))
    }

    /// The facts the planner decides on, read now, on the process queue. nil when the window is gone.
    private func gatherFacts(_ w: HandsWindow, kind: InputKind, verifier: VerifierPlan, path: [CGPoint]) -> (BackgroundFacts, CGRect)? {
        let (live, agent, owned, seen) = onMain { (host.live(w.id), host.agentWorkspace(), host.agentOwned(), host.inspect(w.id)) }
        guard let live, live.pid == w.pid, let server = BackgroundAX.serverWindow(w.id) else { return nil }
        let scope: ScopeKind
        switch decide(live, agent) {
        case .onAgentWorkspace: scope = .agentWorkspace
        case .lent: scope = .lent
        case .denied: scope = .outside
        }
        let axWindows = BackgroundAX.windows(pid: w.pid)
        let me = axWindows.first { $0.id == w.id }
        let hidden = NSRunningApplication(processIdentifier: w.pid)?.isHidden ?? false
        let condition: WindowCondition = hidden ? .appHidden : (me?.minimized == true ? .minimized : .normal)
        let focus = BackgroundAX.focus(pid: w.pid)
        let size = CGSize(width: server.frame.width, height: server.frame.height)
        let facts = BackgroundFacts(
            kind: kind, app: w.app, pid: w.pid, window: w.id, scope: scope, pidIsAgentOwned: owned.contains(w.pid),
            windowOwnerPid: server.pid, axWindowResolved: me != nil, siblingWindows: axWindows.filter { $0.id != w.id && !$0.minimized }.count,
            condition: condition, hasSheetOrPanel: seen.panel, focusedWindow: focus.window, focusedElementWindow: focus.elementWindow,
            targetIsFront: frontPid() == w.pid, transports: BackgroundPoster.support,
            block: BackgroundBreaker.shared.block(bundle: w.bundle, kind: kind), verifier: verifier,
            pointInsideWindow: path.allSatisfy { PointerPath.inside($0, size: size) })
        return (facts, server.frame)
    }
}
