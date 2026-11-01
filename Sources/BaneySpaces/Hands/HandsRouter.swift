import AppKit
import BaneySpacesCore

/// What the hands need from the rest of the app. Everything here runs on the main thread.
struct HandsHost {
    var agentWorkspace: () -> Int? = { nil }
    /// Every window BaneySpaces tracks, with its workspace.
    var windows: () -> [HandsWindow] = { [] }
    /// The deck's `agent open <app> [targets…]`.
    var open: ([String]) -> Wire.Reply = { _ in .init(ok: false, error: "not ready") }
}

/// Runs one agent command: parses nothing, checks scope, calls the engine, returns evidence.
/// Lives in the app process, which holds Accessibility; the CLI and the MCP server only send here.
final class HandsRouter {
    var host = HandsHost()
    private let lends = HandsLends.shared

    /// What a snapshot's refs belong to, so an action on a ref knows its window without trusting the caller.
    private struct Snap { var window: UInt32; var pid: Int32; var app: String; var at: Date }
    private var snaps: [String: Snap] = [:]
    private let lock = NSLock()

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
        if let problem = HandsEngine.shared.permissionProblem(), req.verb != "windows", req.verb != "lend", req.verb != "return", req.verb != "open" {
            return .failure(problem)
        }
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
        case "lend": return lend(req)
        case "return": return giveBack(req)
        default: return .failure(HandsError(.badArguments, "unknown agent command \(req.verb)", suggestion: "Commands: " + HandsTools.all.map(\.verb).joined(separator: ", ")))
        }
    }

    // MARK: scope

    private func onMain<T>(_ f: () -> T) -> T { Thread.isMainThread ? f() : DispatchQueue.main.sync(execute: f) }

    private func allWindows() -> (windows: [HandsWindow], agent: Int?) {
        onMain { (host.windows(), host.agentWorkspace()) }
    }

    private func decide(_ w: HandsWindow, _ agent: Int?) -> ScopeDecision {
        ScopeGuard.check(w, agentWorkspace: agent, lends: lends.current(), now: Date())
    }

    private func windowJSON(_ w: HandsWindow, _ scope: ScopeDecision) -> JSONValue {
        .object(["id": .int(Int(w.id)), "pid": .int(Int(w.pid)), "app": .string(w.app), "title": .string(w.title),
                 "workspace": w.workspace.map(JSONValue.int) ?? .null, "scope": .string(scope.reason)])
    }

    private func windows() -> HandsEnvelope {
        let (all, agent) = allWindows()
        let usable = ScopeGuard.visible(all, agentWorkspace: agent, lends: lends.current(), now: Date())
        return .success(.object([
            "agent_workspace": agent.map(JSONValue.int) ?? .null,
            "windows": .array(usable.sorted { $0.window.id < $1.window.id }.map { windowJSON($0.window, $0.scope) }),
        ]))
    }

    private func matches(_ w: HandsWindow, _ name: String) -> Bool {
        w.app.caseInsensitiveCompare(name) == .orderedSame || w.bundle.caseInsensitiveCompare(name) == .orderedSame
    }

    /// The window a snapshot or find names, and that the scope guard allows.
    private func target(_ req: HandsRequest) -> Result<(HandsWindow, ScopeDecision, String?), HandsError> {
        let (all, agent) = allWindows()
        if let id = req.int("window") {
            guard let w = all.first(where: { Int($0.id) == id }) else {
                return .failure(HandsError(.windowNotFound, "no window \(id) that BaneySpaces tracks", suggestion: "Run `baneyspaces agent windows` for the ids you can use.", retry: .safe))
            }
            let d = decide(w, agent)
            if case .denied(let e) = d { return .failure(e) }
            return .success((w, d, nil))
        }
        let name = req.string("app") ?? ""
        let ofApp = all.filter { matches($0, name) }
        guard !ofApp.isEmpty else {
            let running = NSWorkspace.shared.runningApplications.contains { $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame || $0.bundleIdentifier == name }
            return .failure(HandsError(running ? .windowNotFound : .appNotFound,
                                       running ? "\(name) has no window BaneySpaces tracks" : "\(name) isn't running",
                                       suggestion: running ? "Open one with `baneyspaces agent open \(name)`." : "Start it on the agent workspace with `baneyspaces agent open \(name)`.", retry: .safe))
        }
        let allowed = ofApp.map { ($0, decide($0, agent)) }.filter { $0.1.allowed }
        guard !allowed.isEmpty else {
            if case .denied(let e) = decide(ofApp[0], agent) { return .failure(e) }
            return .failure(HandsError(.outsideAgentWorkspace, "\(name) isn't on the agent workspace", suggestion: "Open it with `baneyspaces agent open \(name)`.", retry: .never))
        }
        let pick = allowed.max { $0.0.id < $1.0.id }!
        let note = allowed.count > 1 ? "newest of \(allowed.count) windows; pass window to choose" : nil
        return .success((pick.0, pick.1, note))
    }

    // MARK: reading

    private func remember(_ data: JSONValue, _ w: HandsWindow) {
        guard let id = data["snapshot_id"]?.string else { return }
        lock.lock(); defer { lock.unlock() }
        snaps[id] = Snap(window: w.id, pid: w.pid, app: w.app, at: Date())
        if snaps.count > 64, let oldest = snaps.min(by: { $0.value.at < $1.value.at })?.key { snaps[oldest] = nil }
    }

    private func read(_ w: HandsWindow, interactive: Bool, compact: Bool, depth: UInt8 = 10) -> Result<JSONValue, HandsError> {
        switch HandsEngine.shared.snapshot(app: w.app, windowID: w.id, interactive: interactive, compact: compact, depth: depth) {
        case .failed(let e): return .failure(e)
        case .ok(let data):
            // The engine must have read the window we asked for, never its neighbor.
            if let got = data["window"]?["id"]?.string, got != "w-\(w.id)" {
                return .failure(HandsError(.windowNotFound, "the engine read \(got), not window \(w.id)", suggestion: "Run `baneyspaces agent windows` and try again.", retry: .safe))
            }
            remember(data, w)
            return .success(data)
        }
    }

    private func snapshot(_ req: HandsRequest) -> HandsEnvelope {
        switch target(req) {
        case .failure(let e): return .failure(e)
        case .success(let (w, scope, note)):
            switch read(w, interactive: req.bool("interactive"), compact: req.bool("compact"), depth: UInt8(clamping: req.int("depth") ?? 10)) {
            case .failure(let e): return .failure(e)
            case .success(var data):
                var o = data.object ?? [:]
                o["target"] = .object(["pid": .int(Int(w.pid)), "window": .int(Int(w.id)), "app": .string(w.app), "scope": .string(scope.reason)])
                if let note { o["note"] = .string(note) }
                data = .object(o)
                return .success(data)
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
                    if hit, o["ref"] != nil || o["ref_id"] != nil {
                        found.append(.object(o.filter { $0.key != "children" }))
                    }
                    for c in o["children"]?.array ?? [] { walk(c) }
                }
                if let tree = data["tree"] { walk(tree) }
                return .success(.object(["snapshot_id": data["snapshot_id"] ?? .null, "window": .int(Int(w.id)), "count": .int(found.count), "matches": .array(found)]))
            }
        }
    }

    // MARK: refs

    private func resolve(_ ref: String?) -> Result<(HandsWindow, ScopeDecision, Snap), HandsError> {
        guard let ref, ref.hasPrefix("@s"), let colon = ref.firstIndex(of: ":") else {
            return .failure(HandsError(.badArguments, "\(ref ?? "") isn't a ref", suggestion: "Refs look like @s8f3k2p9:e5 and come from `baneyspaces agent snapshot`.", retry: .safe))
        }
        let sid = String(ref[ref.index(after: ref.startIndex)..<colon])
        lock.lock(); let snap = snaps[sid]; lock.unlock()
        guard let snap else {
            return .failure(HandsError(.unknownRef, "BaneySpaces didn't print \(ref)", suggestion: "Take a snapshot of the window and use the refs it prints.", retry: .afterSnapshot))
        }
        let (all, agent) = allWindows()
        // Checked again now: the window may have moved to a workspace of the user's since the snapshot.
        guard let w = all.first(where: { $0.id == snap.window && $0.pid == snap.pid }) else {
            return .failure(HandsError(.windowNotFound, "window \(snap.window) is gone", suggestion: "Run `baneyspaces agent windows` and take a new snapshot.", retry: .afterSnapshot))
        }
        let d = decide(w, agent)
        if case .denied(let e) = d { return .failure(e) }
        return .success((w, d, snap))
    }

    private func get(_ req: HandsRequest) -> HandsEnvelope {
        switch resolve(req.string("ref")) {
        case .failure(let e): return .failure(e)
        case .success(let (w, scope, _)):
            let prop = req.string("property") ?? "value"
            switch HandsEngine.shared.get(ref: req.string("ref")!, property: prop) {
            case .failed(let e): return .failure(e)
            case .ok(var d):
                var o = d.object ?? [:]
                o["target"] = .object(["pid": .int(Int(w.pid)), "window": .int(Int(w.id)), "app": .string(w.app), "scope": .string(scope.reason)])
                d = .object(o)
                return .success(d)
            }
        }
    }

    // MARK: acting

    private func press(_ req: HandsRequest) -> HandsEnvelope {
        let parts = (req.string("key") ?? "").split(separator: "+").map(String.init)
        guard let key = parts.last, !key.isEmpty else { return .failure(HandsError(.badArguments, "key is empty", suggestion: "Name a key, like Return or cmd+a.", retry: .safe)) }
        var mods: [Int32] = []
        for m in parts.dropLast() {
            switch m.lowercased() {
            case "cmd", "command", "meta", "super": mods.append(0)
            case "ctrl", "control": mods.append(1)
            case "alt", "opt", "option": mods.append(2)
            case "shift": mods.append(3)
            default: return .failure(HandsError(.badArguments, "unknown modifier \(m)", suggestion: "Modifiers: cmd, ctrl, alt, shift.", retry: .safe))
            }
        }
        return act(req, .pressKey, "press", key: key, modifiers: mods)
    }

    private func scroll(_ req: HandsRequest) -> HandsEnvelope {
        let dirs = ["up": 0, "down": 1, "left": 2, "right": 3]
        guard let d = dirs[(req.string("direction") ?? "").lowercased()] else {
            return .failure(HandsError(.badArguments, "direction must be up, down, left or right", suggestion: "usage: baneyspaces agent scroll <ref> down", retry: .safe))
        }
        return act(req, .scroll, "scroll", direction: Int32(d), amount: UInt32(clamping: req.int("amount") ?? 3))
    }

    private func act(_ req: HandsRequest, _ kind: HandsEngine.Kind, _ name: String, text: String? = nil, direction: Int32 = 1,
                     amount: UInt32 = 3, key: String? = nil, modifiers: [Int32] = []) -> HandsEnvelope {
        let ref = req.string("ref")
        switch resolve(ref) {
        case .failure(let e): return .failure(e)
        case .success(let (w, scope, _)):
            let reads = kind == .typeText || kind == .setValue
            // Tree before the action, to show what it changed.
            let before: JSONValue? = (reads || kind == .toggle) ? nil : { if case .success(let d) = read(w, interactive: false, compact: true) { return d["tree"] }; return nil }()
            // The follow-focus logic must never treat an activation this action causes as the user's.
            AgentActivity.shared.mark(pid: w.pid)
            let reply = HandsEngine.shared.act(ref: ref!, kind: kind, text: text, direction: direction, amount: amount, key: key, modifiers: modifiers)
            AgentActivity.shared.mark(pid: w.pid)
            switch reply {
            case .failed(let e): return .failure(e)
            case .ok(let engine):
                var evidence: JSONValue
                var verified = engine["disposition"]?["delivery"]?.string == "delivered_verified"
                if reads {
                    if case .ok(let v) = HandsEngine.shared.get(ref: ref!, property: "value") {
                        let got = v["value"]?.string ?? ""
                        let matches = got.contains(text ?? "") && (kind == .typeText || got == text)
                        verified = verified || matches
                        evidence = .object(["kind": "value_readback", "value": .string(String(got.prefix(500))), "matches": .bool(matches)])
                    } else { evidence = .object(["kind": "value_readback", "error": "the value couldn't be read back"]) }
                } else if kind == .toggle {
                    if case .ok(let v) = HandsEngine.shared.get(ref: ref!, property: "states") {
                        evidence = .object(["kind": "state_readback", "states": v["value"] ?? .null])
                        verified = true
                    } else { evidence = .object(["kind": "state_readback", "error": "the state couldn't be read back"]) }
                } else if let before, case .success(let d) = read(w, interactive: false, compact: true), let after = d["tree"] {
                    let diff = AXDiff.between(before, after)
                    verified = verified || diff.changed
                    evidence = diff.json()
                } else { evidence = .object(["kind": "ax_diff", "error": "the window couldn't be read after the action"]) }
                AgentActivity.shared.mark(pid: w.pid)
                return .success(.object([
                    "action": .string(name), "ref": .string(ref!), "verified": .bool(verified), "evidence": evidence,
                    "engine": engine,
                    "target": .object(["pid": .int(Int(w.pid)), "window": .int(Int(w.id)), "app": .string(w.app), "scope": .string(scope.reason)]),
                ]))
            }
        }
    }

    private func shot(_ req: HandsRequest) -> HandsEnvelope {
        switch target(req) {
        case .failure(let e): return .failure(e)
        case .success(let (w, scope, _)):
            switch WindowShot.capture(window: w.id, to: req.string("out")) {
            case .failure(let e): return .failure(e)
            case .success(let r):
                return .success(.object([
                    "path": .string(r.path), "width": .int(r.width), "height": .int(r.height),
                    "evidence": .object(["kind": "capture_hash", "sha256": .string(r.sha256)]),
                    "target": .object(["pid": .int(Int(w.pid)), "window": .int(Int(w.id)), "app": .string(w.app), "scope": .string(scope.reason)]),
                ]))
            }
        }
    }

    // MARK: apps

    private func open(_ req: HandsRequest) -> HandsEnvelope {
        guard let app = req.string("app") else { return .failure(HandsError(.badArguments, "app is missing", suggestion: "usage: baneyspaces agent open <app>", retry: .safe)) }
        let targets = (req.string("targets") ?? "").split(separator: " ").map(String.init)
        let known = Set(allWindows().windows.map(\.id))
        let reply = onMain { host.open([app] + targets) }
        guard reply.ok else {
            let msg = reply.error ?? "couldn't open it"
            if msg.contains("agent workspace is off") { return .failure(HandsError(.agentWorkspaceOff, msg, suggestion: "Run `baneyspaces agent on` first.", retry: .never)) }
            if msg.hasPrefix("no app called") { return .failure(HandsError(.appNotFound, msg, suggestion: "Use the app's name as in /Applications, or its bundle id.", retry: .safe)) }
            return .failure(HandsError(.actionFailed, msg, suggestion: "Open it by hand once, or try a different app.", retry: .never))
        }
        // Its window arrives a moment later; wait for it so the caller gets the id.
        var window: HandsWindow?
        let deadline = Date().addingTimeInterval(5)
        while window == nil, Date() < deadline {
            let (all, agent) = allWindows()
            window = all.filter { matches($0, reply.info?["app"] ?? app) && !known.contains($0.id) && $0.workspace == agent }.max { $0.id < $1.id }
            if window == nil { Thread.sleep(forTimeInterval: 0.15) }
        }
        var data: [String: JSONValue] = (reply.info ?? [:]).mapValues(JSONValue.string)
        if let window { data["window"] = .int(Int(window.id)); data["pid"] = .int(Int(window.pid)) }
        else { data["note"] = .string("the window hasn't appeared yet; run `baneyspaces agent windows`") }
        return .success(.object(data))
    }

    private func runningApp(_ name: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && ($0.localizedName?.caseInsensitiveCompare(name) == .orderedSame || $0.bundleIdentifier?.caseInsensitiveCompare(name) == .orderedSame)
        }
    }

    private func lend(_ req: HandsRequest) -> HandsEnvelope {
        guard let name = req.string("app"), let app = runningApp(name) else {
            return .failure(HandsError(.appNotFound, "\(req.string("app") ?? "") isn't running", suggestion: "Open it first; lending is for an app the user already has open.", retry: .safe))
        }
        guard let seconds = LendBook.duration(req.string("for")) else {
            return .failure(HandsError(.badArguments, "couldn't read the time \(req.string("for") ?? "")", suggestion: "Use 10m, 2h or 90s.", retry: .safe))
        }
        let entry = lends.lend(app: app.localizedName ?? name, bundle: app.bundleIdentifier ?? "", session: req.string("session") ?? req.session ?? "", for: seconds)
        return .success(.object(["lent": .string(app.localizedName ?? name), "until": .int(Int((entry?.until ?? Date()).timeIntervalSince1970)),
                                 "note": "the user's windows of this app are now usable; give it back with `baneyspaces agent return`"]))
    }

    private func giveBack(_ req: HandsRequest) -> HandsEnvelope {
        if req.bool("all") {
            let gone = lends.giveBackAll(session: req.session)
            return .success(.object(["returned": .array(gone.map { .string($0.app) })]))
        }
        guard let name = req.string("app") else { return .failure(HandsError(.badArguments, "say which app, or --all", suggestion: "usage: baneyspaces agent return <app>", retry: .safe)) }
        guard lends.giveBack(name) else {
            return .failure(HandsError(.appNotFound, "\(name) wasn't lent", suggestion: "Nothing to give back.", retry: .never))
        }
        return .success(.object(["returned": .array([.string(name)])]))
    }
}
