import AppKit
import BaneySpacesCore

/// What the hands need from the rest of the app. Everything here runs on the main thread.
struct HandsHost {
    var agentWorkspace: () -> Int? = { nil }
    /// Every window BaneySpaces places, with its workspace, from its model (cheap: no scan).
    var windows: () -> [HandsWindow] = { [] }
    /// The same after a scan (at most twice a second): a window that opened a moment ago is in it.
    var freshWindows: () -> [HandsWindow] = { [] }
    /// One window, straight from the model, for the check right before an engine call.
    var live: (UInt32) -> HandsWindow? = { _ in nil }
    var titles: ([UInt32]) -> [UInt32: String] = { _ in [:] }
    /// What a window shows: its document (AXDocument), and whether it is an Open or Save panel.
    var inspect: (UInt32) -> (document: String?, panel: Bool) = { _ in (nil, false) }
    /// The processes BaneySpaces started for an agent.
    var agentOwned: () -> Set<Int32> = { [] }
    /// Asks Donovan, in a sheet, whether to lend an app; true only for a real click on "Lend".
    var askToLend: (_ app: String, _ minutes: Int, _ takeBack: Bool) -> Bool = { _, _, _ in false }
    /// The deck's `agent open <app> [files…]`.
    var open: ([String]) -> Wire.Reply = { _ in .init(ok: false, error: "not ready") }
}

/// Runs one agent command: checks scope, calls the engine, returns evidence. Lives in the app process,
/// which holds Accessibility; the CLI and the MCP server only send here.
final class HandsRouter {
    var host = HandsHost()
    private let lends = HandsLends.shared

    /// What a snapshot's refs belong to. A ref is good only for this snapshot's window and process.
    private struct Snap { var window: UInt32; var pid: Int32; var app: String; var at: Date; var identity: [String: RefIdentity] }
    /// Windows that must never be used: they showed a document from outside the handoff folder.
    private var refused: Set<UInt32> = []
    private var snaps: [String: Snap] = [:]
    private let lock = NSLock()

    /// Files an agent may hand to an app live here.
    static var handoffFolder: URL { HandsEngine.home.appendingPathComponent("handoff", isDirectory: true) }

    // MARK: wire

    /// The deck socket's entry: `text` holds a HandsRequest as JSON, the reply carries the envelope.
    func handleWire(_ r: Wire.Request) -> Wire.Reply {
        let env: HandsEnvelope
        if let data = r.text?.data(using: .utf8), let req = try? JSONDecoder().decode(HandsRequest.self, from: data) {
            env = handle(req)
        } else {
            env = .failure(HandsError(.badArguments, "the request wasn't an agent command", suggestion: "Use `baneyspaces agent <command>`.", retry: .never))
        }
        return Wire.Reply(ok: true, info: ["envelope": env.line])
    }

    func handle(_ req: HandsRequest) -> HandsEnvelope {
        lends.expire()
        if HandsTools.userOnly.contains(req.verb) { return .failure(HandsParse.askedForLend(req.string("app"))) }
        if req.verb != "windows", req.verb != "open", let problem = HandsEngine.shared.permissionProblem() { return .failure(problem) }
        switch req.verb {
        case "windows": return windows()
        case "snapshot": return snapshot(req)
        case "find": return find(req)
        case "get": return get(req)
        case "click": return act(req, .click, "click")
        case "type": return act(req, .typeText, "type", text: req.string("text"))
        case "set-value": return act(req, .setValue, "set-value", text: req.string("value"))
        case "press": return press(req)
        case "scroll": return scroll(req)
        case "select": return act(req, .select, "select", text: req.string("option"))
        case "toggle": return act(req, .toggle, "toggle")
        case "shot": return shot(req)
        case "open": return open(req)
        default: return .failure(HandsError(.badArguments, "unknown agent command \(req.verb)", suggestion: "Commands: " + HandsTools.all.map(\.verb).joined(separator: ", ")))
        }
    }

    // MARK: scope

    private func onMain<T>(_ f: () -> T) -> T { Thread.isMainThread ? f() : DispatchQueue.main.sync(execute: f) }

    private func listWindows(fresh: Bool = false) -> (windows: [HandsWindow], agent: Int?) {
        onMain { (fresh ? host.freshWindows() : host.windows(), host.agentWorkspace()) }
    }

    private func decide(_ w: HandsWindow, _ agent: Int?) -> ScopeDecision {
        lock.lock(); let bad = refused.contains(w.id); lock.unlock()
        if bad { return .denied(HandsError(.needsSandbox, "window \(w.id) showed a document of Donovan's", suggestion: "Open your own file from the handoff folder.", retry: .never)) }
        return ScopeGuard.check(w, agentWorkspace: agent, lends: lends.current(), now: Date(), inUse: UserActivity.shared.inUse(w.pid))
    }

    /// The scope check an engine call runs on its queue at the moment it executes, plus, for a call on a ref,
    /// the check that the ref still means what the snapshot said (the engine's saved refs are a file the
    /// agent could edit).
    private func check(_ w: HandsWindow, ref: String? = nil) -> HandsEngine.Check {
        { [self] in gate(w) ?? ref.flatMap { refProblem($0) } }
    }

    private func refmapURL(_ sid: String) -> URL { HandsEngine.stateRoot.appendingPathComponent("snapshots/\(sid)/refmap.json") }

    private func refProblem(_ ref: String) -> HandsError? {
        guard let colon = ref.firstIndex(of: ":") else { return nil }
        let sid = String(ref[ref.index(after: ref.startIndex)..<colon])
        lock.lock(); let snap = snaps[sid]; lock.unlock()
        guard let snap, let data = try? Data(contentsOf: refmapURL(sid)),
              RefmapIdentity.intact(sealed: snap.identity, current: data, ref: ref) else {
            return HandsError(.staleRef, "the saved refs for \(ref) no longer match the snapshot", suggestion: "Take a new snapshot.", retry: .afterSnapshot)
        }
        return nil
    }

    /// The check right before an engine call: the window is still the same process's, and still in scope.
    /// A move to one of Donovan's workspaces or a revoked lend between resolving and dispatching stops the call.
    private func gate(_ w: HandsWindow) -> HandsError? {
        let (now, agent) = onMain { (host.live(w.id), host.agentWorkspace()) }
        guard let now else { return HandsError(.windowNotFound, "window \(w.id) is gone", suggestion: "Run `baneyspaces agent windows` and take a new snapshot.", retry: .afterSnapshot) }
        guard now.pid == w.pid else { return HandsError(.staleRef, "window \(w.id) belongs to a different process now", suggestion: "Take a new snapshot.", retry: .afterSnapshot) }
        if case .denied(let e) = decide(now, agent) { return e }
        return inspectProblem(now)
    }

    /// Windows of a process BaneySpaces started for an agent are used only while they show nothing of Donovan's:
    /// no document from outside the handoff folder (a restored one, or one opened through a panel), and never an
    /// Open or Save panel, which would browse his files. Checked on every use, so a late window is covered too.
    private func inspectProblem(_ w: HandsWindow) -> HandsError? {
        let (owned, seen) = onMain { (host.agentOwned(), host.inspect(w.id)) }
        guard owned.contains(w.pid) else { return nil }
        var why: String?
        if seen.panel { why = "window \(w.id) of \(w.app) is an Open or Save panel" }
        else if let doc = seen.document, !doc.isEmpty, !HandoffPath.contains(document: doc, in: Self.handoffFolder) { why = "window \(w.id) of \(w.app) shows a document from outside the handoff folder" }
        guard let why else { return nil }
        lock.lock(); refused.insert(w.id); lock.unlock()
        return HandsError(.needsSandbox, why, suggestion: "Agents work only on files from the handoff folder and never drive an Open or Save panel. Open the file with `baneyspaces agent open <app> <file>`.", retry: .never)
    }

    private func windowJSON(_ w: HandsWindow, _ scope: ScopeDecision) -> JSONValue {
        .object(["id": .int(Int(w.id)), "pid": .int(Int(w.pid)), "app": .string(w.app), "title": .string(w.title),
                 "workspace": w.workspace.map(JSONValue.int) ?? .null, "scope": .string(scope.reason)])
    }

    private func targetJSON(_ w: HandsWindow, _ scope: ScopeDecision) -> JSONValue {
        .object(["pid": .int(Int(w.pid)), "window": .int(Int(w.id)), "app": .string(w.app), "scope": .string(scope.reason)])
    }

    private func windows() -> HandsEnvelope {
        let (all, agent) = listWindows(fresh: true)
        let usable = ScopeGuard.visible(all, agentWorkspace: agent, lends: lends.current(), now: Date(), inUse: { UserActivity.shared.inUse($0) })
            .filter { inspectProblem($0.window) == nil }
            .sorted { $0.window.id < $1.window.id }
        let titles = onMain { host.titles(usable.map(\.window.id)) }
        return .success(.object([
            "agent_workspace": agent.map(JSONValue.int) ?? .null,
            "windows": .array(usable.map { u in
                var w = u.window
                w.title = titles[w.id] ?? ""
                return windowJSON(w, u.scope)
            }),
        ]))
    }

    private func matches(_ w: HandsWindow, _ name: String) -> Bool {
        w.app.caseInsensitiveCompare(name) == .orderedSame || w.bundle.caseInsensitiveCompare(name) == .orderedSame
    }

    /// The window a snapshot or find names, and that the scope guard allows.
    private func target(_ req: HandsRequest) -> Result<(HandsWindow, ScopeDecision, String?), HandsError> {
        var (all, agent) = listWindows()
        if let id = req.int("window") {
            if !all.contains(where: { Int($0.id) == id }) { (all, agent) = listWindows(fresh: true) }
            guard let w = all.first(where: { Int($0.id) == id }) else {
                return .failure(HandsError(.windowNotFound, "no window \(id) that BaneySpaces tracks", suggestion: "Run `baneyspaces agent windows` for the ids you can use.", retry: .safe))
            }
            let d = decide(w, agent)
            if case .denied(let e) = d { return .failure(e) }
            return .success((w, d, nil))
        }
        let name = req.string("app") ?? ""
        var ofApp = all.filter { matches($0, name) }
        if ofApp.isEmpty { (all, agent) = listWindows(fresh: true); ofApp = all.filter { matches($0, name) } }
        guard !ofApp.isEmpty else {
            let running = NSWorkspace.shared.runningApplications.contains { $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame || $0.bundleIdentifier == name }
            return .failure(HandsError(running ? .windowNotFound : .appNotFound,
                                       running ? "\(name) has no window BaneySpaces tracks" : "\(name) isn't running",
                                       suggestion: running ? "Open one with `baneyspaces agent open \(name)`." : "Start it on the agent workspace with `baneyspaces agent open \(name)`.", retry: .safe))
        }
        let decided = ofApp.map { ($0, decide($0, agent)) }
        let allowed = decided.filter { $0.1.allowed }
        guard !allowed.isEmpty else {
            if case .denied(let e) = decided[0].1 { return .failure(e) }
            return .failure(HandsError(.outsideAgentWorkspace, "\(name) isn't on the agent workspace", suggestion: "Open it with `baneyspaces agent open \(name)`.", retry: .never))
        }
        let pids = Set(allowed.map(\.0.pid))
        guard pids.count == 1 else {
            return .failure(HandsError(.ambiguous, "\(name) has windows in \(pids.count) processes: " + allowed.map { "\($0.0.id) (pid \($0.0.pid))" }.joined(separator: ", "),
                                       suggestion: "Pass --window with one of those ids.", retry: .afterSnapshot))
        }
        let pick = allowed.max { $0.0.id < $1.0.id }!
        let note = allowed.count > 1 ? "newest of \(allowed.count) windows; pass window to choose" : nil
        return .success((pick.0, pick.1, note))
    }

    // MARK: reading

    /// Records the snapshot and what each of its refs points at, read from the engine's file now, while it is
    /// fresh. False when the file can't be read or a ref points anywhere but this window and process.
    private func remember(_ data: JSONValue, _ w: HandsWindow) -> Bool {
        guard let id = data["snapshot_id"]?.string, let file = try? Data(contentsOf: refmapURL(id)),
              let table = RefmapIdentity.table(from: file), RefmapIdentity.allTarget(table, window: w.id, pid: w.pid) else { return false }
        lock.lock(); defer { lock.unlock() }
        snaps[id] = Snap(window: w.id, pid: w.pid, app: w.app, at: Date(), identity: table)
        if snaps.count > 256, let oldest = snaps.min(by: { $0.value.at < $1.value.at })?.key { snaps[oldest] = nil }
        return true
    }

    /// `register: false` for the snapshots taken as evidence: the agent never sees their refs, so they must not push its refs out.
    private func read(_ w: HandsWindow, interactive: Bool, compact: Bool, depth: UInt8 = 10, register: Bool = true) -> Result<JSONValue, HandsError> {
        switch HandsEngine.shared.snapshot(window: w, interactive: interactive, compact: compact, depth: depth, evidence: !register, check: check(w)) {
        case .failed(let e): return .failure(e)
        case .ok(let data):
            // The engine must have read the window we asked for, never its neighbor.
            if let got = data["window"]?["id"]?.string, got != "w-\(w.id)" {
                return .failure(HandsError(.windowNotFound, "the engine read \(got), not window \(w.id)", suggestion: "Run `baneyspaces agent windows` and try again.", retry: .safe))
            }
            if register, !remember(data, w) {
                return .failure(HandsError(.engineError, "the snapshot's saved refs couldn't be checked", suggestion: "Take a new snapshot.", retry: .safe))
            }
            return .success(data)
        }
    }

    private func snapshot(_ req: HandsRequest) -> HandsEnvelope {
        switch target(req) {
        case .failure(let e): return .failure(e)
        case .success(let (w, scope, note)):
            switch read(w, interactive: req.bool("interactive"), compact: req.bool("compact"), depth: UInt8(clamping: req.int("depth") ?? 10)) {
            case .failure(let e): return .failure(e)
            case .success(let data):
                var o = data.object ?? [:]
                o["target"] = targetJSON(w, scope)
                if let note { o["note"] = .string(note) }
                return .success(.object(o))
            }
        }
    }

    private func find(_ req: HandsRequest) -> HandsEnvelope {
        switch target(req) {
        case .failure(let e): return .failure(e)
        case .success(let (w, _, _)):
            switch read(w, interactive: false, compact: true) {
            case .failure(let e): return .failure(e)
            case .success(let data):
                let role = req.string("role")?.lowercased(), name = req.string("name")?.lowercased()
                let text = req.string("text")?.lowercased(), value = req.string("value")?.lowercased()
                let limit = req.int("limit") ?? 20
                var found: [JSONValue] = []
                func walk(_ n: JSONValue) {
                    guard case .object(let o) = n, found.count < limit else { return }
                    let r = (o["role"]?.string ?? "").lowercased(), nm = (o["name"]?.string ?? o["title"]?.string ?? "").lowercased()
                    let v = (o["value"]?.string ?? "").lowercased(), d = (o["description"]?.string ?? "").lowercased()
                    let hit = (role.map { r == $0 } ?? true) && (name.map { nm.contains($0) } ?? true)
                        && (value.map { v.contains($0) } ?? true) && (text.map { nm.contains($0) || v.contains($0) || d.contains($0) } ?? true)
                    if hit, o["ref_id"] != nil || o["ref"] != nil { found.append(.object(o.filter { $0.key != "children" })) }
                    for c in o["children"]?.array ?? [] { walk(c) }
                }
                if let tree = data["tree"] { walk(tree) }
                return .success(.object(["snapshot_id": data["snapshot_id"] ?? .null, "window": .int(Int(w.id)), "count": .int(found.count), "matches": .array(found)]))
            }
        }
    }

    // MARK: refs

    /// A ref is good for the snapshot that printed it: that snapshot's window, in that process. Any other
    /// window, a window that changed process, or one that left the agent's scope fails here.
    private func resolve(_ ref: String?) -> Result<(HandsWindow, ScopeDecision), HandsError> {
        guard let ref, ref.hasPrefix("@s"), let colon = ref.firstIndex(of: ":") else {
            return .failure(HandsError(.badArguments, "\(ref ?? "") isn't a ref", suggestion: "Refs look like @s8f3k2p9:e5 and come from `baneyspaces agent snapshot`.", retry: .safe))
        }
        let sid = String(ref[ref.index(after: ref.startIndex)..<colon])
        lock.lock(); let snap = snaps[sid]; snaps[sid]?.at = Date(); lock.unlock()
        guard let snap else {
            return .failure(HandsError(.unknownRef, "BaneySpaces didn't print \(ref)", suggestion: "Take a snapshot of the window and use the refs it prints.", retry: .afterSnapshot))
        }
        let (all, agent) = listWindows()
        guard let w = all.first(where: { $0.id == snap.window }) else {
            return .failure(HandsError(.staleRef, "window \(snap.window) is gone", suggestion: "Run `baneyspaces agent windows` and take a new snapshot.", retry: .afterSnapshot))
        }
        guard w.pid == snap.pid else {
            return .failure(HandsError(.staleRef, "window \(snap.window) now belongs to a different process than the snapshot's", suggestion: "Take a new snapshot.", retry: .afterSnapshot))
        }
        let d = decide(w, agent)
        if case .denied(let e) = d { return .failure(e) }
        return .success((w, d))
    }

    private func get(_ req: HandsRequest) -> HandsEnvelope {
        switch resolve(req.string("ref")) {
        case .failure(let e): return .failure(e)
        case .success(let (w, scope)):
            let ref = req.string("ref")!
            switch HandsEngine.shared.get(window: w, ref: ref, property: req.string("property") ?? "value", check: check(w, ref: ref)) {
            case .failed(let e): return .failure(e)
            case .ok(let d):
                var o = d.object ?? [:]
                o["target"] = targetJSON(w, scope)
                return .success(.object(o))
            }
        }
    }

    // MARK: acting

    /// Keys need the app in front, and BaneySpaces never raises one for an agent. Until keys can be sent to
    /// one background process (a later phase) this answers without an engine call.
    private func press(_ req: HandsRequest) -> HandsEnvelope {
        switch resolve(req.string("ref")) {
        case .failure(let e): return .failure(e)
        case .success(let (w, _)):
            return .failure(HandsError(.notSupported, "keys reach only the app in front, and \(w.app) is not",
                                       suggestion: "BaneySpaces never raises an app for an agent. Use `type` or `set-value` on a text element, or `click` the control. Keys to a background app arrive in a later phase (docs/agent-computer-use.md).", retry: .never))
        }
    }

    private func scroll(_ req: HandsRequest) -> HandsEnvelope {
        let dirs = ["up": 0, "down": 1, "left": 2, "right": 3]
        guard let d = dirs[(req.string("direction") ?? "").lowercased()] else {
            return .failure(HandsError(.badArguments, "direction must be up, down, left or right", suggestion: "usage: baneyspaces agent scroll <ref> down", retry: .safe))
        }
        return act(req, .scroll, "scroll", direction: Int32(d), amount: UInt32(clamping: req.int("amount") ?? 3))
    }

    private func valueOf(_ w: HandsWindow, _ ref: String) -> String? {
        if case .ok(let v) = HandsEngine.shared.get(window: w, ref: ref, property: "value", check: check(w, ref: ref)) { return v["value"]?.string ?? "" }
        return nil
    }

    private func act(_ req: HandsRequest, _ kind: HandsEngine.Kind, _ name: String, text: String? = nil, direction: Int32 = 1, amount: UInt32 = 3) -> HandsEnvelope {
        guard let ref = req.string("ref") else { return .failure(HandsError(.badArguments, "ref is missing", suggestion: "usage: baneyspaces agent \(name) <ref>", retry: .safe)) }
        switch resolve(ref) {
        case .failure(let e): return .failure(e)
        case .success(let (w, scope)):
            // The mark covers the whole action, queue wait and engine call included, and a short tail after it.
            let token = AgentActivity.shared.begin(pid: w.pid, window: w.id)
            defer { AgentActivity.shared.end(token) }
            let writes = kind == .typeText || kind == .setValue
            let beforeValue: String? = writes ? valueOf(w, ref) : nil
            // Tree before the action, to show what it changed.
            var before: JSONValue?
            if !writes, kind != .toggle, case .success(let d) = read(w, interactive: false, compact: true, register: false) { before = d["tree"] }
            // Scope again, at the moment of dispatch: the window may have moved since resolving.
            // Every action reports its target before dispatch; the point is measured only for a listener.
            var point: CGPoint?
            if HandsEvents.hasListener, case .ok(let b) = HandsEngine.shared.get(window: w, ref: ref, property: "bounds", check: check(w, ref: ref)) { point = HandsEvents.center(ofBounds: b["value"]) }
            HandsEvents.willAct(HandsActionEvent(kind: name, ref: ref, window: w.id, pid: w.pid, app: w.app, point: point))
            // The scope and ref checks run again on the process queue, at the moment the call executes.
            let reply = HandsEngine.shared.act(window: w, ref: ref, kind: kind, text: text, direction: direction, amount: amount, check: check(w, ref: ref))
            switch reply {
            case .failed(let e): return .failure(e)
            case .ok(let engine):
                var evidence: JSONValue
                var verified = engine["disposition"]?["delivery"]?.string == "delivered_verified"
                if writes {
                    if let after = valueOf(w, ref) {
                        let before = beforeValue ?? ""
                        let expected = text ?? ""
                        let result: (ok: Bool, changed: Bool) = kind == .typeText
                            ? (ValueCheck.typed(before: before, after: after, text: expected), after != before)
                            : { let s = ValueCheck.set(before: before, after: after, expected: expected); return (s.verified, s.changed) }()
                        let (ok, changed) = (result.ok, result.changed)
                        verified = ok
                        evidence = .object(["kind": "value_readback", "value": .string(String(after.prefix(500))), "matches": .bool(ok), "changed": .bool(changed),
                                            "before_length": .int(before.count), "after_length": .int(after.count)])
                    } else { verified = false; evidence = .object(["kind": "value_readback", "error": "the value couldn't be read back"]) }
                } else if kind == .toggle {
                    if case .ok(let v) = HandsEngine.shared.get(window: w, ref: ref, property: "value", check: check(w, ref: ref)) {
                        var o: [String: JSONValue] = ["kind": "state_readback", "value": v["value"] ?? .null]
                        if case .ok(let s) = HandsEngine.shared.get(window: w, ref: ref, property: "states", check: check(w, ref: ref)) { o["states"] = s["value"] ?? .null }
                        evidence = .object(o)
                    } else { evidence = .object(["kind": "state_readback", "error": "the state couldn't be read back"]) }
                } else if let before, case .success(let d) = read(w, interactive: false, compact: true, register: false), let after = d["tree"] {
                    let diff = AXDiff.between(before, after)
                    verified = verified || diff.changed
                    evidence = diff.json()
                } else { evidence = .object(["kind": "ax_diff", "error": "the window couldn't be read after the action"]) }
                return .success(.object([
                    "action": .string(name), "ref": .string(ref), "verified": .bool(verified), "evidence": evidence,
                    "engine": engine, "target": targetJSON(w, scope),
                ]))
            }
        }
    }

    private func shot(_ req: HandsRequest) -> HandsEnvelope {
        switch target(req) {
        case .failure(let e): return .failure(e)
        case .success(let (w, scope, _)):
            if let e = gate(w) { return .failure(e) }
            let token = AgentActivity.shared.begin(pid: w.pid, window: w.id)
            defer { AgentActivity.shared.end(token) }
            switch WindowShot.capture(window: w.id, named: req.string("out"), check: check(w)) {
            case .failure(let e): return .failure(e)
            case .success(let r):
                return .success(.object([
                    "path": .string(r.path), "width": .int(r.width), "height": .int(r.height),
                    "evidence": .object(["kind": "capture_hash", "sha256": .string(r.sha256)]),
                    "target": targetJSON(w, scope),
                ]))
            }
        }
    }

    // MARK: apps

    private func open(_ req: HandsRequest) -> HandsEnvelope {
        guard let app = req.string("app") else { return .failure(HandsError(.badArguments, "app is missing", suggestion: "usage: baneyspaces agent open <app>", retry: .safe)) }
        guard let url = DeckController.appURL(app) else {
            return .failure(HandsError(.appNotFound, "no app called \(app)", suggestion: "Use the app's name as in /Applications, or its bundle id.", retry: .safe))
        }
        let bundle = Bundle(url: url)?.bundleIdentifier ?? ""
        let display = url.deletingPathExtension().lastPathComponent
        try? FileManager.default.createDirectory(at: Self.handoffFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let files: [String]
        switch AgentOpenGate.check(app: display, bundle: bundle, targets: req.args["targets"]?.array?.compactMap(\.string) ?? [], handoff: Self.handoffFolder) {
        case .failure(let e): return .failure(e)
        case .success(let f): files = f
        }
        let pidsBefore = Set(NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundle }.map(\.processIdentifier))
        let known = Set(listWindows(fresh: true).windows.map(\.id))
        let reply = onMain { host.open([app] + files) }
        guard reply.ok else {
            let msg = reply.error ?? "couldn't open it"
            if msg.contains("agent workspace is off") { return .failure(HandsError(.agentWorkspaceOff, msg, suggestion: "Ask Donovan to run `baneyspaces agent on`.", retry: .never)) }
            if msg.hasPrefix("no app called") { return .failure(HandsError(.appNotFound, msg, suggestion: "Use the app's name as in /Applications, or its bundle id.", retry: .safe)) }
            return .failure(HandsError(.actionFailed, msg, suggestion: "Try a different app.", retry: .never))
        }
        // Its window arrives a moment later; wait for it so the caller gets the id. It must belong to a new
        // process: an app that ran the launch inside Donovan's copy is not an agent's window.
        let separate = AgentAppPolicy.needsSeparateInstance(bundle: bundle)
        var window: HandsWindow?
        let deadline = Date().addingTimeInterval(5)
        while window == nil, Date() < deadline {
            let (all, agent) = listWindows(fresh: true)
            window = all.filter { matches($0, reply.info?["app"] ?? display) && !known.contains($0.id) && $0.workspace == agent && (!separate || !pidsBefore.contains($0.pid)) }.max { $0.id < $1.id }
            if window == nil { Thread.sleep(forTimeInterval: 0.15) }
        }
        var data: [String: JSONValue] = (reply.info ?? [:]).mapValues(JSONValue.string)
        if let window {
            data["window"] = .int(Int(window.id)); data["pid"] = .int(Int(window.pid))
        } else if separate, !pidsBefore.isEmpty, noNewProcess(bundle: bundle, before: pidsBefore) {
            return .failure(HandsError(.needsSandbox, "\(display) didn't start a separate copy, so nothing of it is the agent's",
                                       suggestion: "Close nothing; ask Donovan to quit \(display), or work in the sandbox.", retry: .never))
        } else { data["note"] = .string("the window hasn't appeared yet; run `baneyspaces agent windows`") }
        return .success(.object(data))
    }

    /// Whether every running copy of the app was already running before the launch.
    private func noNewProcess(bundle: String, before: Set<pid_t>) -> Bool {
        let now = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundle }.map(\.processIdentifier)
        return now.allSatisfy { before.contains($0) }
    }

    // MARK: lending (Donovan's, never an agent's: see HandsTools.userOnly and SocketPolicy)

    /// `agent lend <app|pid>` from the command line: not a grant. It checks the request, then asks Donovan in a
    /// sheet; only a real click on "Lend" in the app lends (`LendConsent`). Called on the main thread.
    func askToLend(target: String, duration: String?, session: String) -> HandsEnvelope {
        guard !target.isEmpty else { return .failure(HandsError(.badArguments, "say which app", suggestion: "usage: baneyspaces agent lend <app|pid> [--for 30m]", retry: .safe)) }
        let regular = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let found: [NSRunningApplication]
        if let pid = Int32(target) { found = regular.filter { $0.processIdentifier == pid } }
        else { found = regular.filter { $0.localizedName?.caseInsensitiveCompare(target) == .orderedSame || $0.bundleIdentifier?.caseInsensitiveCompare(target) == .orderedSame } }
        guard !found.isEmpty else { return .failure(HandsError(.appNotFound, "\(target) isn't running", suggestion: "Open it first.", retry: .safe)) }
        guard found.count == 1, let app = found.first else {
            return .failure(HandsError(.ambiguous, "\(target) is running \(found.count) times: pids " + found.map { String($0.processIdentifier) }.joined(separator: ", "),
                                       suggestion: "Lend by pid: `baneyspaces agent lend <pid>`.", retry: .safe))
        }
        let name = app.localizedName ?? "app"
        if lends.isLent(pid: app.processIdentifier) {
            // Already lent: the sheet offers to take it back.
            guard host.askToLend(name, 0, true) else { return .failure(HandsError(.permissionDenied, "not confirmed", suggestion: "Nothing changed.", retry: .never)) }
            lends.giveBack(name)
            return .success(.object(["returned": .array([.string(name)])]))
        }
        guard let seconds = LendBook.duration(duration) else {
            return .failure(HandsError(.badArguments, "couldn't read the time \(duration ?? "")", suggestion: "Use 10m, 2h or 90s.", retry: .safe))
        }
        // Checked before the sheet: the sheet itself takes the front, so afterwards every app looks just left.
        if UserActivity.shared.inUse(app.processIdentifier) {
            return .failure(HandsError(.inUse, "\(name) is in front or was used in the last 30 s", suggestion: "Switch away from it, wait 30 seconds, and lend again.", retry: .safe))
        }
        let ids = host.freshWindows().filter { $0.pid == app.processIdentifier }.map(\.id)
        guard !ids.isEmpty else {
            return .failure(HandsError(.windowNotFound, "\(name) has no window BaneySpaces tracks", suggestion: "Open a window in it first.", retry: .safe))
        }
        guard host.askToLend(name, Int(seconds / 60), false) else {
            return .failure(HandsError(.permissionDenied, "Donovan didn't lend \(name)", suggestion: "Nothing was lent. Work on the agent workspace with `baneyspaces agent open`.", retry: .never))
        }
        let entry = lends.lend(app: name, bundle: app.bundleIdentifier ?? "", pid: app.processIdentifier, windows: ids, session: session, for: seconds)
        let ending = session.isEmpty ? "" : " or session \(session) ends"
        let note = "agents may use these windows until the time runs out" + ending + "; they are refused while the app is in use"
        return .success(.object(["lent": .string(name), "pid": .int(Int(app.processIdentifier)), "windows": .array(ids.map { .int(Int($0)) }),
                                 "until": .int(Int((entry?.until ?? Date()).timeIntervalSince1970)),
                                 "note": .string(note)]))
    }
}
