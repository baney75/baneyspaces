import ApplicationServices
import BaneySpacesCore
import CAgentDesktop
import Foundation

/// The hands engine: agent-desktop's C library, linked into this app. It reads a window's
/// accessibility tree into snapshot-qualified refs and acts on a ref with strict re-identification.
///
/// Rules this file keeps (HandsSourceTests reads this source and fails if one breaks):
///  - Every action goes through `ad_execute_by_ref_timeout` with the strict Headless policy, a constant
///    no caller can change: `act` takes no policy. The engine gives one action, PressKey, a focus
///    permission of its own under Headless (its base policy), so `Kind` has no key case. Keys and
///    the pointer never go through the engine: `BackgroundPoster` posts them to one process, with a permit.
///  - Nothing here calls an engine function that focuses, raises, launches, closes or moves a
///    window, posts a mouse event, or sends a key to no particular app.
///  - No activate, SetFrontProcess or global CGEventPost, in this file or its neighbors.
/// Calls for one process run one at a time on that process's queue and have a time budget: a hung app
/// answers `timeout` and blocks nobody else. Every call carries a scope check that runs on the queue at the
/// moment the call executes, not when it was queued; a call whose caller already timed out is dropped
/// unrun; and the focus guard is held until the call has really finished, not until its caller gave up.
final class HandsEngine {
    static let shared = HandsEngine()
    private let initLock = NSLock()
    private var adapter: OpaquePointer?
    /// A second adapter, with a session of its own, for the snapshots taken as evidence: the engine
    /// keeps only so many saved snapshots per store, and evidence must never push out the refs an
    /// agent is holding. If it can't be made the engine isn't ready; there is no fallback to the shared one.
    private var evidenceAdapter: OpaquePointer?
    private var failure: HandsError?
    private var queues: [Int32: DispatchQueue] = [:]

    /// AD_POLICY_KIND_HEADLESS: no cursor, no focus. Never a parameter.
    static let headlessPolicy: Int32 = 0
    // AdResult values from agent_desktop.h (the type itself is ambiguous in Swift).
    static let surfaceWindow: Int32 = 0 // AD_SNAPSHOT_SURFACE_WINDOW
    static let resultOK: Int32 = 0
    static let resultPermDenied: Int32 = -1
    // AdActionKind values from agent_desktop.h. No key action: see the rules above.
    enum Kind: Int32 { case click = 0, setValue = 4, select = 8, toggle = 9, scroll = 12, typeText = 17 }

    /// Seconds each kind of call may take before the caller gets `timeout`.
    /// How long an action waits for its target to become actionable before it gives up.
    static let actionableWait: TimeInterval = 5
    enum Budget { static let snapshot: TimeInterval = 25, get: TimeInterval = 10, act: TimeInterval = 20, transaction: TimeInterval = 60, bounds: TimeInterval = 0.05 }

    /// BaneySpaces' own folder for agents (handoff files, shots), readable by this user only.
    static var home: URL { Wire.supportDir.appendingPathComponent("hands", isDirectory: true) }
    /// Where the engine keeps its refs: a folder of its own, new for each launch of BaneySpaces and named at random,
    /// so nothing else has a reason to write there and an old launch's refs can't be mistaken for these.
    static let stateRoot: URL = home.appendingPathComponent(UUID().uuidString, isDirectory: true)

    /// What a call to the engine returned: its JSON envelope, or why there is none.
    enum Reply {
        case ok(JSONValue)
        case failed(HandsError)
    }

    /// The scope check a call runs just before it touches the engine: nil to go ahead.
    typealias Check = () -> HandsError?

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var reply: Reply?
        private var cancelled = false
        func set(_ r: Reply) { lock.lock(); reply = r; lock.unlock() }
        func get() -> Reply? { lock.lock(); defer { lock.unlock() }; return reply }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    private static let queueKey = DispatchSpecificKey<Int32>()
    /// Whether the caller is running on this process's queue (inside `transaction`).
    func isOnQueue(of pid: Int32) -> Bool { DispatchQueue.getSpecific(key: Self.queueKey) == pid }

    /// A read lane per process for the cursor's bounds reads, beside the process queue, so an action never waits behind one.
    /// The pinned engine documents this: "Adapters are safe to call from multiple host threads. Native element handles are
    /// thread-affine ... Desktop mutations are serialized by the adapter's cross-process interaction lease"
    /// (agent-desktop 5261b52, crates/ffi/src/lib.rs "Thread safety"; the same words are in include/agent_desktop.h and
    /// crates/ffi/README.md "Thread Safety (macOS)"). `ad_get_ref` resolves and frees its element inside the one call on
    /// the lane's thread, and a read is no mutation. A hung app clogs only its own lane, and reads that can't start
    /// within their deadline are dropped.
    private var lanes: [Int32: DispatchQueue] = [:]
    private func lane(for pid: Int32) -> DispatchQueue {
        initLock.lock(); defer { initLock.unlock() }
        if let q = lanes[pid] { return q }
        let q = DispatchQueue(label: "baneyspaces.hands.bounds.\(pid)", qos: .userInitiated)
        lanes[pid] = q
        return q
    }

    private func queue(for pid: Int32) -> DispatchQueue {
        initLock.lock(); defer { initLock.unlock() }
        if let q = queues[pid] { return q }
        let q = DispatchQueue(label: "baneyspaces.hands.engine.\(pid)")
        q.setSpecific(key: Self.queueKey, value: pid)
        queues[pid] = q
        return q
    }

    /// Runs `work` on the window's process queue, waiting at most `budget`. The focus guard is held from here
    /// until the work has finished or been dropped; `check` runs on the queue right before `work`. A call
    /// that outlives its budget is told `timeout`, and if it hasn't started it never will.
    private func run(window w: HandsWindow, budget: TimeInterval, mutating: Bool, check: @escaping Check, _ work: @escaping (_ cancelled: () -> Bool) -> Reply) -> Reply {
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let token = AgentActivity.shared.begin(pid: w.pid, window: w.id)
        queue(for: w.pid).async {
            defer { AgentActivity.shared.end(token); done.signal() }
            if box.isCancelled { return }
            if let e = check() { return box.set(.failed(e)) }
            box.set(work { box.isCancelled })
        }
        if done.wait(timeout: .now() + budget) == .timedOut {
            box.cancel()
            return .failed(HandsError(.timeout, "the app didn't answer within \(Int(budget)) s",
                                      suggestion: mutating ? "It may still land: read the element back with `baneyspaces agent get` before trying again."
                                                           : "The app is busy or showing a dialog. Try again in a moment.",
                                      retry: mutating ? .never : .safe))
        }
        return box.get() ?? .failed(HandsError(.engineError, "the engine gave no answer", suggestion: "Try again.", retry: .never))
    }

    /// Sets the engine's state folder. Called once on the main thread at launch, before any engine queue exists:
    /// setenv is not safe against another thread reading the environment.
    static func prepareEnvironment() {
        let fm = FileManager.default
        try? fm.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Refs of earlier launches (and the engine's old shared state folder) are of no use: remove them.
        for name in (try? fm.contentsOfDirectory(atPath: home.path)) ?? [] where name != "handoff" && name != "shots" {
            try? fm.removeItem(at: home.appendingPathComponent(name))
        }
        try? fm.createDirectory(at: stateRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        setenv("AGENT_DESKTOP_HOME", stateRoot.path, 1)
    }

    private func ready() -> HandsError? {
        initLock.lock(); defer { initLock.unlock() }
        if adapter != nil, evidenceAdapter != nil { return nil }
        if let failure { return failure }
        guard ad_init(UInt32(AD_ABI_VERSION_MAJOR)) == Self.resultOK else {
            failure = HandsError(.engineError, "the hands engine library doesn't match this build", suggestion: "Reinstall BaneySpaces (make install).", retry: .never)
            return failure
        }
        guard let a = ad_adapter_create() else {
            failure = HandsError(.engineError, "the hands engine didn't start: \(lastError().message)", suggestion: "Check `baneyspaces doctor`.", retry: .never)
            return failure
        }
        guard let e = "evidence".withCString({ ad_adapter_create_with_session($0) }) else {
            ad_adapter_destroy(a)
            failure = HandsError(.engineError, "the engine's evidence store didn't start: \(lastError().message)", suggestion: "Check `baneyspaces doctor`.", retry: .never)
            return failure
        }
        adapter = a
        evidenceAdapter = e
        return nil
    }

    private func lastError() -> (message: String, suggestion: String) {
        (ad_last_error_message().map { String(cString: $0) } ?? "", ad_last_error_suggestion().map { String(cString: $0) } ?? "")
    }

    /// Reads and frees the engine's output string, then turns its envelope into a reply.
    private func finish(_ code: Int32, _ out: UnsafeMutablePointer<CChar>?) -> Reply {
        var json: JSONValue?
        if let out {
            json = JSONValue.parse(String(cString: out))
            ad_free_string(out)
        }
        if let json, json["ok"]?.bool == true { return .ok(json["data"] ?? .object([:])) }
        if let err = json?["error"] { return .failed(Self.translate(err)) }
        let e = lastError()
        if code == Self.resultPermDenied || e.message.lowercased().contains("permission") {
            return .failed(HandsError(.permissionDenied, "Accessibility isn't allowed for BaneySpaces",
                                      suggestion: "Allow BaneySpaces in System Settings > Privacy & Security > Accessibility.", retry: .safe))
        }
        return .failed(HandsError(.engineError, e.message.isEmpty ? "the engine failed (\(code))" : e.message,
                                  suggestion: e.suggestion.isEmpty ? "Take a new snapshot and try again." : e.suggestion, retry: .never))
    }

    /// An engine error object as one of ours. Its own retry verdict decides `retry`; a ref that needs
    /// a new snapshot says so.
    static func translate(_ err: JSONValue) -> HandsError {
        let code = err["code"]?.string ?? ""
        let message = err["message"]?.string ?? "the engine refused"
        let suggestion = err["suggestion"]?.string ?? "Take a new snapshot and try again."
        let mapped: HandsErrorCode
        switch code {
        case "STALE_REF", "SNAPSHOT_NOT_FOUND", "ELEMENT_NOT_FOUND": mapped = .staleRef
        case "AMBIGUOUS_TARGET": mapped = .ambiguousTarget
        case "ACTION_NOT_SUPPORTED", "POLICY_DENIED", "PLATFORM_NOT_SUPPORTED": mapped = .notSupported
        case "ACTION_FAILED": mapped = .actionFailed
        case "TIMEOUT", "APP_UNRESPONSIVE": mapped = .timeout
        case "PERM_DENIED": mapped = .permissionDenied
        case "APP_NOT_FOUND": mapped = .appNotFound
        case "WINDOW_NOT_FOUND": mapped = .windowNotFound
        case "INVALID_ARGS": mapped = .badArguments
        default: mapped = .engineError
        }
        let retry = EngineVerdict.retry(for: mapped, verdict: err["disposition"]?["retry"]?.string)
        return HandsError(mapped, message, suggestion: suggestion, retry: retry)
    }

    /// One window's tree with refs. `windowID` is the engine's id for it ("w-4211"). `evidence` reads use
    /// their own store, so they never push the agent's refs out.
    func snapshot(window w: HandsWindow, interactive: Bool, compact: Bool, depth: UInt8, evidence: Bool = false, check: @escaping Check) -> Reply {
        run(window: w, budget: Budget.snapshot, mutating: false, check: check) { [self] _ in
            doSnapshot(windowID: w.id, interactive: interactive, compact: compact, depth: depth, evidence: evidence)
        }
    }

    /// The same read, directly, for a caller already on the process's queue (`transaction`). Never queues, so it cannot wait on itself.
    func snapshotInline(window w: HandsWindow, interactive: Bool, compact: Bool, depth: UInt8, evidence: Bool = false) -> Reply {
        precondition(isOnQueue(of: w.pid), "snapshotInline runs inside a transaction")
        return doSnapshot(windowID: w.id, interactive: interactive, compact: compact, depth: depth, evidence: evidence)
    }

    private func doSnapshot(windowID: UInt32, interactive: Bool, compact: Bool, depth: UInt8, evidence: Bool) -> Reply {
        if let e = ready() { return .failed(e) }
        guard let adapter = evidence ? evidenceAdapter : adapter else { return .failed(HandsError(.engineError, "the engine isn't ready", suggestion: "Check `baneyspaces doctor`.", retry: .never)) }
        var out: UnsafeMutablePointer<CChar>?
        let id = "w-\(windowID)"
        // The exact window id alone names the window. The app's name is not passed: two copies of an app share
        // it, and the engine would match by name first.
        let code = id.withCString { w in
            ad_snapshot_window(adapter, nil, w, Self.surfaceWindow, depth, interactive, compact, &out)
        }
        return finish(code, out)
    }

    /// One property of a ref, read from the live element.
    func get(window w: HandsWindow, ref: String, property: String, check: @escaping Check) -> Reply {
        run(window: w, budget: Budget.get, mutating: false, check: check) { [self] _ in doGet(ref: ref, property: property) }
    }

    /// The same read, directly, for a caller already on the process's queue (`transaction`).
    func getInline(window w: HandsWindow, ref: String, property: String) -> Reply {
        precondition(isOnQueue(of: w.pid), "getInline runs inside a transaction")
        return doGet(ref: ref, property: property)
    }

    private func doGet(ref: String, property: String) -> Reply {
        if let e = ready() { return .failed(e) }
        guard let adapter else { return .failed(HandsError(.engineError, "the engine isn't ready", suggestion: "Check `baneyspaces doctor`.", retry: .never)) }
        var out: UnsafeMutablePointer<CChar>?
        let code = ref.withCString { r in property.withCString { p in ad_get_ref(adapter, r, p, &out) } }
        return finish(code, out)
    }

    /// The target's bounds for the agent cursor, read on the process's read lane and handed to `completion`; nobody
    /// waits for it, and the action does not queue behind it. Nil when the read couldn't start within `within` seconds of now (the app is busy: the cursor settles
    /// for its last known point), when the scope check fails, or when the engine can't answer. The same scope check and
    /// focus-guard mark as every other call; it only reads.
    func measureBounds(window w: HandsWindow, ref: String, within: TimeInterval, check: @escaping Check, completion: @escaping (CGRect?) -> Void) {
        let queued = ProcessInfo.processInfo.systemUptime
        lane(for: w.pid).async { [self] in
            // The mark is held while the read runs, not while it waits in the lane.
            guard ProcessInfo.processInfo.systemUptime - queued <= within else { return completion(nil) }
            let token = AgentActivity.shared.begin(pid: w.pid, window: w.id)
            defer { AgentActivity.shared.end(token) }
            guard check() == nil, ready() == nil, let adapter else { return completion(nil) }
            var out: UnsafeMutablePointer<CChar>?
            let code = ref.withCString { r in "bounds".withCString { p in ad_get_ref(adapter, r, p, &out) } }
            if case .ok(let v) = finish(code, out) { completion(HandsEvents.frame(ofBounds: v["value"])) } else { completion(nil) }
        }
    }

    /// An action on a ref. Always the strict Headless policy; the auto-wait is the engine's default.
    func act(window w: HandsWindow, ref: String, kind: Kind, text: String? = nil, direction: Int32 = 1, amount: UInt32 = 3, check: @escaping Check) -> Reply {
        run(window: w, budget: Budget.act, mutating: true, check: check) { [self] cancelled in
            if let e = ready() { return .failed(e) }
            guard let adapter else { return .failed(HandsError(.engineError, "the engine isn't ready", suggestion: "Check `baneyspaces doctor`.", retry: .never)) }
            var out: UnsafeMutablePointer<CChar>?
            var action = AdAction()
            action.kind = kind.rawValue
            action.scroll.direction = direction
            action.scroll.amount = amount
            func dispatch(_ text: UnsafePointer<CChar>?) -> Int32 {
                action.text = text
                return ref.withCString { r in
                    ad_execute_by_ref_timeout(adapter, r, &action, Self.headlessPolicy, 0, &out)
                }
            }
            // The engine would wait up to 5 s inside one call for the target to become actionable, with no way to
            // look at the scope meanwhile. It is told not to (0 = single shot); the wait is here, and the scope is
            // checked again before every attempt.
            let result: Result<JSONValue, HandsError> = EngineRetry.run(
                attempt: {
                    out = nil
                    let code = text.map { $0.withCString { dispatch($0) } } ?? dispatch(nil)
                    switch finish(code, out) {
                    case .ok(let d): return .success(d)
                    case .failed(let e): return .failure(e)
                    }
                },
                stop: check, cancelled: cancelled,
                giveUp: Date().addingTimeInterval(Self.actionableWait),
                pause: { Thread.sleep(forTimeInterval: 0.1) })
            switch result {
            case .success(let d): return .ok(d)
            case .failure(let e): return .failed(e)
            }
        }
    }

    /// Runs a whole input transaction (readings before, the post, the proof) on the window's process queue, so no other
    /// action on that process can run in between and change what the proof reads. It is the same queue the engine's
    /// calls use, which is why the transaction reads through `getInline` and `snapshotInline`. The focus guard is
    /// held, and the scope check runs right before it starts. The events themselves are BackgroundPoster's; this
    /// file never makes one.
    func transaction(window w: HandsWindow, check: @escaping Check, _ work: @escaping (_ cancelled: () -> Bool) -> Reply) -> Reply {
        run(window: w, budget: Budget.transaction, mutating: true, check: check, work)
    }

    /// Whether the engine can read windows at all (Accessibility granted).
    func permissionProblem() -> HandsError? {
        AXIsProcessTrusted() ? nil
            : HandsError(.permissionDenied, "Accessibility isn't allowed for BaneySpaces",
                         suggestion: "Allow BaneySpaces in System Settings > Privacy & Security > Accessibility.", retry: .safe)
    }
}
