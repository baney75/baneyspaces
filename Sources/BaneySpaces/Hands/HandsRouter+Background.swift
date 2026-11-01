import AppKit
import BaneySpacesCore

/// Routes shut for an app or process after it misbehaved, for as long as BaneySpaces runs.
final class BackgroundBreaker {
    static let shared = BackgroundBreaker()
    private let lock = NSLock()
    private var breaker = RouteBreaker()
    func block(bundle: String, pid: Int32, kind: InputKind) -> RouteBlock? { lock.lock(); defer { lock.unlock() }; return breaker.block(bundle: bundle, pid: pid, kind: kind) }
    func update(_ change: (inout RouteBreaker) -> Void) { lock.lock(); change(&breaker); lock.unlock() }
}

/// Phase 4: keys and a pointer, posted to one process that is not in front, with proof read back from the window.
///
/// The whole action is one transaction on the target process's queue: no other action on that process runs between
/// the readings before, the post and the readings after, so another action's change can never prove this one. Inside
/// it, in order: watch activations and the session; read the window; check scope and facts again and choose one route
/// (`BackgroundPlanner`); post once, through `EventRunner` (a stop posts nothing new and releases whatever is down);
/// read the same window back. No proof is `unverified`, retry never; a second route is never tried after a post.
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

    // MARK: the transaction

    private func frontPid() -> Int32? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    private func inlineValue(_ w: HandsWindow, _ ref: String) -> String? {
        if case .ok(let v) = HandsEngine.shared.getInline(window: w, ref: ref, property: "value") { return v["value"]?.string ?? "" }
        return nil
    }

    private func inlineTree(_ w: HandsWindow) -> JSONValue? {
        guard case .ok(let d) = HandsEngine.shared.snapshotInline(window: w, interactive: false, compact: true, depth: 10, evidence: true),
              d["window"]?["id"]?.string == "w-\(w.id)" else { return nil }
        return d["tree"]
    }

    /// What the stopped or finished span shows about the front app.
    private func frontError(_ change: FrontChange, _ w: HandsWindow, kind: InputKind) -> HandsError? {
        switch change {
        case .same: return nil
        case .targetCameForward:
            BackgroundBreaker.shared.update { $0.selfActivated(bundle: w.bundle, kind: kind) }
            return BackgroundRefusal.blocked(w.app, .selfActivates)
        case .other(let p): return BackgroundRefusal.frontChanged(w.app, to: p)
        case .unknown: return BackgroundRefusal.frontUnknown(w.app)
        }
    }

    private func background(_ w: HandsWindow, _ scope: ScopeDecision, name: String, kind: InputKind, ref: String?,
                            chords: [KeyChord], path: [CGPoint], drag: Bool) -> HandsEnvelope {
        // The mark covers the whole action: the queue wait, the readings, the post and the proof, and a short tail.
        let token = AgentActivity.shared.begin(pid: w.pid, window: w.id)
        defer { AgentActivity.shared.end(token) }
        let scopeCheck = check(w, ref: ref)
        if let e = scopeCheck() { return .failure(e) }
        guard BackgroundAX.serverWindow(w.id) != nil else {
            return .failure(HandsError(.windowNotFound, "the window server does not list window \(w.id)", suggestion: "Run `baneyspaces agent windows` and try again.", retry: .safe))
        }
        let reply = HandsEngine.shared.transaction(window: w, check: scopeCheck) { [self] cancelled in
            transact(w, scope, name: name, kind: kind, ref: ref, chords: chords, path: path, drag: drag, scopeCheck: scopeCheck, cancelled: cancelled)
        }
        switch reply {
        case .failed(let e): return .failure(e)
        case .ok(let data): return .success(data)
        }
    }

    /// Runs on the process queue. Everything it reads goes through the engine's inline calls.
    private func transact(_ w: HandsWindow, _ scope: ScopeDecision, name: String, kind: InputKind, ref: String?, chords: [KeyChord], path: [CGPoint], drag: Bool,
                          scopeCheck: @escaping HandsEngine.Check, cancelled: () -> Bool) -> HandsEngine.Reply {
        // From planning to the end of the proof: every activation, and every session event, is seen.
        let activations = ActivationWatch()
        let tap = SessionTap()
        defer { activations.stop(); _ = tap.stop() }
        guard let frontStart = frontPid() else { return .failed(BackgroundRefusal.frontUnknown(w.app)) }
        func spanFront() -> FrontChange {
            let seen = PostGuard.activations(activations.activated, target: w.pid)
            if seen != .same { return seen }
            return PostGuard.front(start: frontStart, now: frontPid(), target: w.pid) == .unknown ? .unknown : .same
        }

        // Readings before. The window's tree is read twice, a moment apart: what changes on its own is noise.
        func refReading() -> ElementReading? {
            guard let ref, let v = inlineValue(w, ref) else { return nil }
            return ElementReading.text(window: w.id, identity: ref, value: v)
        }
        func focusReading() -> ElementReading? { BackgroundAX.focus(pid: w.pid).element.map { BackgroundAX.reading(of: $0) } }
        func windowReading() -> WindowReading? {
            BackgroundAX.windows(pid: w.pid).mapped.first { $0.id == w.id }.map { BackgroundAX.windowReading($0.element) }
        }
        let refBefore = refReading(), focusBefore = focusReading(), windowBefore = windowReading()
        let tree1 = inlineTree(w)
        Thread.sleep(forTimeInterval: 0.15)
        let tree2 = inlineTree(w)
        let verifier: VerifierPlan = {
            switch (tree1 != nil && tree2 != nil, kind == .pointer && CGPreflightScreenCaptureAccess()) {
            case (true, true): return .axAndPixels
            case (true, false): return .ax
            case (false, true): return .pixels
            case (false, false): return .none
            }
        }()

        // Scope and facts again, at the moment of execution; one route or one refusal.
        guard let (facts, frame) = gatherFacts(w, kind: kind, verifier: verifier, path: path) else {
            return .failed(HandsError(.windowNotFound, "window \(w.id) is gone", suggestion: "Run `baneyspaces agent windows` and take a new snapshot.", retry: .afterSnapshot))
        }
        let permit: BackgroundPermit
        switch BackgroundPlanner.plan(facts) {
        case .failure(let e): return .failed(e)
        case .success(let p): permit = p
        }
        if let e = frontError(spanFront(), w, kind: kind) { return .failed(e) }

        // The agent cursor (phase 1b) learns where the hands are working.
        if HandsEvents.hasListener {
            HandsEvents.willAct(HandsActionEvent(kind: name, ref: ref ?? "", window: w.id, pid: w.pid, app: w.app, point: path.first.map { PointerPath.screenPoint(local: $0, frame: frame) }))
        }
        let pointerBefore = BackgroundPoster.pointerLocation()
        var stopError: HandsError?
        let stop: () -> HandsError? = {
            if cancelled() { return HandsError(.timeout, "the caller stopped waiting", suggestion: "Read the element back before trying again.", retry: .never) }
            return self.frontError(spanFront(), w, kind: kind)
        }
        var posted = 0, released = 0
        var aimed: [CGPoint] = []
        var shotBefore: WindowShot.Pixels?

        switch kind {
        case .keys:
            let report = BackgroundPoster.keys(chords, permit: permit, stop: stop)
            posted = report.posted.count; released = report.released; stopError = report.stopped
        case .pointer:
            let gesture = BackgroundPoster.newGesture()
            // Arrive first, then look: a hover that tints or outlines is in the picture the press is compared with.
            let hover = BackgroundPoster.pointer(InputScript.hover(at: path[0]), frame: frame, drag: drag, gesture: gesture, permit: permit, stop: stop)
            aimed += hover.screenPoints
            posted += hover.report.posted.count
            stopError = hover.report.stopped
            if stopError == nil {
                Thread.sleep(forTimeInterval: 0.2)
                shotBefore = verifier.hasPixels ? WindowShot.pixels(window: w.id, check: scopeCheck) : nil
                if verifier == .pixels, shotBefore == nil {
                    return .failed(BackgroundRefusal.noVerifier(w.app))     // nothing is pressed yet
                }
                let press = BackgroundPoster.pointer(drag ? InputScript.drag(path: path) : InputScript.click(at: path[0]), frame: frame, drag: drag,
                                                     gesture: gesture, permit: permit, stop: stop)
                aimed += press.screenPoints
                posted += press.report.posted.count; released = press.report.released; stopError = press.report.stopped
            }
        }
        if let stopError { return .failed(finish(stopError, w: w, kind: kind, activations: activations, spanFront: spanFront)) }

        // The proof: the same window read again, until it shows what the action predicts or the time is up.
        let deadline = Date().addingTimeInterval(kind == .keys ? 1.5 : 1.2)
        var verdict = DeliveryVerdict(verified: false, basis: "no_reading")
        var diff: AXDiff?
        var pixels: PixelChange?
        let minStroke: Int = {
            guard let s = shotBefore else { return DeliveryProof.minStrokePixels }
            return PointerPath.strokeMinimum(path: path, scale: s.scale)
        }()
        repeat {
            Thread.sleep(forTimeInterval: 0.15)
            if spanFront() != .same { break }
            let refAfter = refReading(), focusAfter = focusReading(), windowAfter = windowReading()
            var content: Bool?
            if let t1 = tree1, let t2 = tree2, let after = inlineTree(w) {
                content = ContentChange.changed(base1: t1, base2: t2, after: after)
                diff = AXDiff.between(t1, after)
            }
            if let b = shotBefore, let a = WindowShot.pixels(window: w.id, check: scopeCheck), a.width == b.width, a.height == b.height {
                let region = PointerPath.region(path: path, margin: 14, scale: b.scale, width: b.width, height: b.height)
                let hover = PointerPath.hoverExclusion(path: path, radius: 10, scale: b.scale, width: b.width, height: b.height)
                pixels = PixelDiff.compare(before: b.rgba, after: a.rgba, width: b.width, height: b.height, region: region, excluding: hover)
            }
            let r: ReadingPair = (refBefore, refAfter), f: ReadingPair = (focusBefore, focusAfter)
            verdict = kind == .keys
                ? DeliveryProof.keys(target: w.id, chords: chords, ref: r, focus: f, content: content, window: (windowBefore, windowAfter), pixels: nil)
                : DeliveryProof.pointer(target: w.id, ref: r, focus: f, content: content, pixels: pixels, minStroke: minStroke)
        } while !verdict.verified && Date() < deadline

        // The span is over: any activation in it fails the action, whatever the proof says.
        if let e = frontError(spanFront(), w, kind: kind) { return .failed(e) }
        let events = tap.stop()
        let pointerVerdict = PointerAudit.verdict(before: pointerBefore, after: BackgroundPoster.pointerLocation(), posted: aimed, tap: events, ownPid: Int64(getpid()))
        if let e = pointerVerdict.error { return .failed(e) }

        guard verdict.verified else {
            let certain = KeyPrediction.certainToShow(chords, focusIsText: focusBefore?.isText ?? false)
            BackgroundBreaker.shared.update { if kind == .keys, certain, verdict.basis == "no_change" { $0.dropped(pid: w.pid, kind: kind) } }
            return .failed(BackgroundRefusal.unverified(basis: verdict.basis))
        }
        BackgroundBreaker.shared.update { $0.proved(pid: w.pid, kind: kind) }
        var evidence: [String: JSONValue] = ["kind": "delivery_proof", "basis": .string(verdict.basis), "pointer": .string(pointerVerdict.label),
                                             "front": "unchanged", "released": .int(released)]
        if let diff { evidence["ax"] = diff.json(limit: 3) }
        if let p = pixels {
            evidence["pixels"] = .object(["inside_changed": .int(p.insideChanged), "inside_total": .int(p.insideTotal),
                                          "outside_changed": .int(p.outsideChanged), "outside_total": .int(p.outsideTotal)])
        }
        return .ok(.object([
            "action": .string(name), "verified": true, "route": .string(permit.route.rawValue),
            "transport": .string(permit.transport.rawValue), "events": .int(posted), "evidence": .object(evidence),
            "target": targetJSON(w, scope),
        ]))
    }

    /// A stop is reported as what it was; an activation seen by the watch outranks a bare "stopped".
    private func finish(_ stop: HandsError, w: HandsWindow, kind: InputKind, activations: ActivationWatch, spanFront: () -> FrontChange) -> HandsError {
        frontError(spanFront(), w, kind: kind) ?? stop
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
        let me = axWindows.mapped.first { $0.id == w.id }
        let hidden = NSRunningApplication(processIdentifier: w.pid)?.isHidden ?? false
        let condition: WindowCondition = hidden ? .appHidden : (me?.minimized == true ? .minimized : .normal)
        let focus = BackgroundAX.focus(pid: w.pid)
        let size = CGSize(width: server.frame.width, height: server.frame.height)
        let titleBar = me.map { BackgroundAX.titleBarHeight($0.element, windowTop: server.frame.minY) } ?? 0
        // Windows that cannot be mapped count against the keys: one of them could take the key.
        let siblings = axWindows.mapped.filter { $0.id != w.id && !$0.minimized }.count + axWindows.unmapped
        let facts = BackgroundFacts(
            kind: kind, app: w.app, pid: w.pid, window: w.id, scope: scope, pidIsAgentOwned: owned.contains(w.pid),
            windowOwnerPid: server.pid, axWindowResolved: me != nil, siblingWindows: siblings,
            condition: condition, hasSheetOrPanel: seen.panel, focusedWindow: focus.window, focusedElementWindow: focus.elementWindow,
            targetIsFront: frontPid() == w.pid, transports: BackgroundPoster.support,
            block: BackgroundBreaker.shared.block(bundle: w.bundle, pid: w.pid, kind: kind), verifier: verifier,
            pointInsideWindow: path.allSatisfy { PointerPath.inside($0, size: size) },
            pointInTitleBar: path.contains { $0.y < titleBar })
        return (facts, server.frame)
    }
}
