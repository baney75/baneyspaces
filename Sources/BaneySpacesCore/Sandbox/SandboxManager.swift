import Foundation

/// How a reset got its clean guest.
public struct SandboxResetTiming: Sendable {
    public enum Route: String, Sendable { case swap, swapAfterWait = "swap_after_wait", cold }
    public var route: Route
    public var seconds: TimeInterval
    /// Where the time went, in order: `kill`, `room`, `resume` (spawn to agent), `share`, `check`.
    public var steps: [(String, TimeInterval)] = []
    /// Where the warm clone was: `memory` (promoted, nothing to restore) or `disk` (restored from its saved state).
    public var from: WarmLocation = .disk
    /// `swap` is the only route meant to meet the budget; a cold boot is the fallback and is flagged.
    public var withinBudget: Bool { seconds <= SandboxPin.resetBudget && route != .cold }
    public var ms: Int { Int((seconds * 1000).rounded()) }
    public var breakdown: String { steps.map { "\($0.0)=\(Int($0.1 * 1000))ms" }.joined(separator: " ") }
}

extension SandboxResetTiming: Equatable {
    public static func == (a: Self, b: Self) -> Bool { a.route == b.route && a.seconds == b.seconds && a.from == b.from }
}

/// Decides how a reset gets its clean guest, from what is ready.
public enum SandboxResetPlan {
    public enum Choice: Equatable, Sendable { case swap, waitForWarm, cold }
    public static func choose(warmReady: Bool, warmBuilding: Bool) -> Choice {
        if warmReady { return .swap }
        return warmBuilding ? .waitForWarm : .cold
    }
}

/// The sandbox: a throwaway macOS VM, its warm suspended replacement, and every rule that keeps it
/// throwaway. One manager owns the VMs on a Mac (an exclusive lock enforces it). Every path that makes a
/// VM deletes it again when anything after it fails.
///
/// - `up`: take the warm clean clone (resume it, a few seconds) or, with none, clone the pinned image and boot
///   cold; share the task's handoff folder; run the isolation self-check in the guest; any failure stops and
///   deletes the VM. Then build the next warm clone in the background.
/// - `reset`: kill and delete the working VM, resume the warm clone in its place (the swap), build another.
/// - `down`: stop and delete the working VM.
public final class SandboxManager {
    public enum Phase: String, Sendable { case stopped, starting, running, resetting, stopping, error }
    public enum WarmState: String, Sendable { case none, building, ready, failed }

    public struct Working {
        public var name: String
        public var proc: RunningProcess?
        public var task: String
        public var handoff: String
        public var graphics: Bool
        public var startedAt: TimeInterval
    }

    public struct Snapshot: Sendable {
        public var phase: Phase
        public var vm: String?
        public var task: String?
        public var graphics: Bool
        public var uptime: TimeInterval?
        public var warm: WarmState
        public var warmLocation: WarmLocation
        public var resetStats: SandboxResetStats
        public var selfcheck: String
        public var selfcheckProblems: [String]
        public var lastReset: SandboxResetTiming?
        public var lastError: String?
        public var rulesHash: String?
        public var pendingDeletes: [String]
        public var lastUp: UpTiming?
    }

    public struct UpTiming: Equatable, Sendable {
        public var route: String
        public var bootSeconds: TimeInterval
        public var selfcheckSeconds: TimeInterval
    }

    let tart: SandboxTart
    let facts: HostFactsReading
    let clock: SandboxClock
    let paths: SandboxPaths
    let settings: () -> SandboxSettings
    let makeID: () -> String
    let memory: MemoryReading
    /// How long `reset` waits for a warm clone that is still being built.
    public var warmWaitLimit: TimeInterval = 120
    public var bootLimit: TimeInterval = 300
    public var resumeLimit: TimeInterval = 90

    private let op = NSLock()          // one lifecycle operation at a time
    private let state = NSLock()       // guards the fields below
    private let ownerLock = NSLock()   // guards taking the Mac-wide lock and the startup cleanup
    private var phase: Phase = .stopped
    private var working: Working?
    private var warmName: String?
    private var warmState: WarmState = .none
    private var warmProc: RunningProcess?
    private var warmCancel = false
    private var warmThread: Thread?
    private var selfcheckStamp: String?        // rules hash of the last passed check
    private var selfcheckAt: TimeInterval?
    private var selfcheckProblems: [String] = []
    private var lastReset: SandboxResetTiming?
    private var lastUp: UpTiming?
    private var verifying = false
    private var warmLocation: WarmLocation = .disk
    private var warmHandoff: String?
    private var lastActivity: TimeInterval?
    private var resetSamples: [TimeInterval] = []
    private var acquiredFrom: WarmLocation = .disk
    /// Set while `reset` runs, so the steps inside `acquireClean` can report their time.
    private var acquireLap: ((String) -> Void)?
    private var lastError: String?
    private var pendingDeletes: Set<String> = []
    private var owned = false
    private var lockFD: Int32 = -1

    public init(tart: SandboxTart, facts: HostFactsReading, clock: SandboxClock = SystemClock(), paths: SandboxPaths = SandboxPaths(),
                settings: @escaping () -> SandboxSettings, makeID: @escaping () -> String = { String(UUID().uuidString.prefix(8)).lowercased() },
                memory: MemoryReading = SystemMemory()) {
        self.memory = memory
        self.tart = tart; self.facts = facts; self.clock = clock; self.paths = paths; self.settings = settings; self.makeID = makeID
    }

    deinit { if lockFD >= 0 { close(lockFD) } }

    // MARK: ownership and startup cleanup

    /// Takes the exclusive lock (one manager per Mac) and deletes every `bsx-*` VM a crash left behind.
    /// Runs once, before the first operation.
    func ensureOwner() throws {
        ownerLock.lock(); defer { ownerLock.unlock() }
        if owned { return }
        try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(paths.lock.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if fd >= 0 { close(fd) }
            throw SandboxError("not_owner", "another BaneySpaces process owns the sandbox: use `baneyspaces sandbox …` (no --local) while the app runs", vmDeleted: true)
        }
        lockFD = fd
        owned = true
        if !tart.deleteAllOurs() { fail("a leftover sandbox VM could not be deleted") }
    }

    /// Takes the Mac-wide lock and deletes every `bsx-*` VM a crash left behind. The app calls it once
    /// at launch when the sandbox is on.
    public func startupCleanup() throws { try ensureOwner() }

    // MARK: status

    public func snapshot() -> Snapshot {
        state.lock(); defer { state.unlock() }
        return Snapshot(phase: phase, vm: working?.name, task: working?.task, graphics: working?.graphics ?? false,
                        uptime: working.map { clock.now() - $0.startedAt }, warm: warmState, warmLocation: warmState == .ready ? warmLocation : .disk, resetStats: SandboxResetStats(samples: resetSamples),
                        selfcheck: verifying ? "verifying" : (selfcheckStamp == nil ? (selfcheckProblems.isEmpty ? "none" : "failed") : "passed"),
                        selfcheckProblems: selfcheckProblems, lastReset: lastReset, lastError: lastError,
                        rulesHash: selfcheckStamp, pendingDeletes: pendingDeletes.sorted(), lastUp: lastUp)
    }

    /// A sandbox command: keeps the warm clone in memory for the next 15 minutes.
    func touch() { state.lock(); lastActivity = clock.now(); state.unlock() }

    private func set(_ p: Phase) { state.lock(); phase = p; state.unlock() }
    private func fail(_ e: String?) { state.lock(); lastError = e; state.unlock() }

    // MARK: up

    @discardableResult
    public func up(task requested: String?) throws -> Snapshot {
        op.lock(); defer { op.unlock() }
        let cfg = settings()
        touch()
        guard cfg.enabled else { throw SandboxError("off", "the sandbox is off: Settings > Agents, or baneyspaces sandbox on") }
        let task = requested ?? SandboxHandoff.defaultTask()
        guard SandboxHandoff.valid(task) else { throw SandboxError("bad_task", "a task name is letters, digits, . - _ (up to 64): \(task)") }
        try ensureOwner()
        if let w = currentWorking() {
            guard w.task == task || requested == nil else {
                throw SandboxError("busy", "the sandbox is up for task \(w.task): baneyspaces sandbox down first")
            }
            return snapshot()
        }
        set(.starting); fail(nil)
        let folder = try SandboxHandoff.folder(for: task, paths: paths)
        do {
            try bringUp(task: task, handoff: folder.path, cfg: cfg)
        } catch let e as SandboxError {
            fail(e.description); set(e.code == "busy" ? .stopped : .error)
            throw e
        }
        set(.running)
        return snapshot()
    }

    /// Gets a clean, checked guest and makes it the working VM. On any failure the VM it made is gone.
    private func bringUp(task: String, handoff: String, cfg: SandboxSettings) throws {
        let t0 = clock.now()
        let rules = SandboxNetwork.rules(hostAddresses: facts.read().ipv4)
        let bad = SandboxNetwork.problems(in: rules)
        guard bad.isEmpty else { throw SandboxError("rules_weak", bad.joined(separator: "; ")) }
        let (name, proc, viaWarm) = try acquireClean(handoff: handoff, rules: rules, cfg: cfg, allowWait: true)
        state.lock()
        working = Working(name: name, proc: proc, task: task, handoff: handoff, graphics: false, startedAt: clock.now())
        state.unlock()
        let booted = clock.now()
        let report = SandboxSelfcheck.run(vm: name, tart: tart, hostFacts: facts)
        let checked = clock.now()
        if report.passed {
            state.lock()
            selfcheckStamp = rules.hash; selfcheckAt = checked; selfcheckProblems = []
            lastUp = UpTiming(route: viaWarm ? "warm" : "cold", bootSeconds: booted - t0, selfcheckSeconds: checked - booted)
            state.unlock()
        } else {
            state.lock(); selfcheckStamp = nil; selfcheckProblems = report.problems; state.unlock()
            let gone = destroyWorking()
            invalidateWarm() // the warm clone shares the rules and the image: not trusted either
            throw SandboxError("selfcheck_failed", report.problems.joined(separator: "; "), vmDeleted: gone)
        }
        startWarmBuild(cfg: cfg)
    }

    /// The warm clone resumed, or a cold boot. A failed step deletes what it made before throwing.
    private func acquireClean(handoff: String, rules: SandboxNetwork.Rules, cfg: SandboxSettings,
                              allowWait: Bool) throws -> (String, RunningProcess, Bool) {
        var choice = SandboxResetPlan.choose(warmReady: warmSnapshot().state == .ready, warmBuilding: warmSnapshot().state == .building)
        if choice == .waitForWarm {
            if allowWait, waitForWarm(limit: warmWaitLimit) { choice = .swap } else { choice = .cold }
        }
        if choice == .swap, let (name, proc) = try? resumeWarm(handoff: handoff, rules: rules) { return (name, proc, true) }
        let (name, proc) = try coldBoot(handoff: handoff, rules: rules, cfg: cfg)
        return (name, proc, false)
    }

    private func warmSnapshot() -> (state: WarmState, name: String?) {
        state.lock(); defer { state.unlock() }
        return (warmState, warmName)
    }

    /// Waits until the warm clone is ready or its build has ended. True if it is ready.
    private func waitForWarm(limit: TimeInterval) -> Bool {
        let end = clock.now() + limit
        while clock.now() < end {
            let w = warmSnapshot()
            if w.state == .ready { return true }
            if w.state != .building { return false }
            clock.sleep(1)
        }
        return false
    }

    /// Resumes the warm clone as the working VM. It is spent either way: ready no more.
    private func resumeWarm(handoff: String, rules: SandboxNetwork.Rules) throws -> (String, RunningProcess) {
        // A warm clone already running for this task's folder is promoted: nothing to restore.
        state.lock()
        let inMemory = warmState == .ready && warmLocation == .memory
        let sameFolder = warmHandoff == handoff
        state.unlock()
        if inMemory && !sameFolder { saveWarmToDisk() }
        if inMemory && sameFolder { return try promoteWarm() }
        try makeRoom()
        acquireLap?("room")
        state.lock()
        guard warmState == .ready, let name = warmName else { state.unlock(); throw SandboxError("no_warm", "no warm clone") }
        warmState = .none; warmName = nil
        state.unlock()
        var proc: RunningProcess?
        do {
            let p = try tart.spawnRun(vm: name, options: TartRunOptions(rules: rules, handoff: handoff))
            proc = p
            try tart.waitForAgent(vm: name, proc: p, timeout: resumeLimit, poll: 0.1)
            acquireLap?("resume")
            try tart.waitForShare(vm: name, timeout: 30)
            acquireLap?("share")
            acquiredFrom = .disk
            return (name, p)
        } catch {
            _ = tart.deleteVerified(name, proc: proc, force: true)
            throw error
        }
    }

    private func promoteWarm() throws -> (String, RunningProcess) {
        state.lock()
        guard let name = warmName, let p = warmProc else { state.unlock(); throw SandboxError("no_warm", "no warm clone") }
        warmState = .none; warmName = nil; warmProc = nil; warmLocation = .disk; warmHandoff = nil
        state.unlock()
        acquireLap?("room")
        do {
            guard p.isRunning else { throw SandboxError("vm_exited", "the warm clone had exited") }
            try tart.waitForAgent(vm: name, proc: p, timeout: 20, poll: 0.1)
            acquireLap?("resume")
            try tart.waitForShare(vm: name, timeout: 30)
            acquireLap?("share")
            acquiredFrom = .memory
            return (name, p)
        } catch {
            _ = tart.deleteVerified(name, proc: p, force: true)
            throw error
        }
    }

    private func coldBoot(handoff: String, rules: SandboxNetwork.Rules, cfg: SandboxSettings) throws -> (String, RunningProcess) {
        try makeRoom()
        let name = SandboxPin.vmPrefix + "w-" + makeID()
        var proc: RunningProcess?
        do {
            try tart.cloneAndSize(image: SandboxPin.image, vm: name, memoryGB: cfg.memoryGB, cpus: cfg.cpus)
            let p = try tart.spawnRun(vm: name, options: TartRunOptions(rules: rules, handoff: handoff))
            proc = p
            try tart.waitForAgent(vm: name, proc: p, timeout: bootLimit)
            try tart.waitForShare(vm: name, timeout: 60)
            acquiredFrom = .disk
            return (name, p)
        } catch let e as SandboxError {
            let gone = tart.deleteVerified(name, proc: proc, force: true)
            throw SandboxError(e.code, e.message, vmDeleted: gone)
        }
    }

    /// Apple allows two macOS guests at once, whoever started them. The warm clone being built is ours to
    /// give up; anything else running is not, and the request gets `busy` (try again later).
    private func makeRoom() throws {
        var running = try tart.runningGuests()
        if running >= SandboxTart.guestLimit, warmSnapshot().state == .building {
            cancelWarmBuild()
            running = try tart.runningGuests()
        }
        if running >= SandboxTart.guestLimit {
            throw SandboxError("busy", "\(running) macOS guests are already running (Apple's limit is \(SandboxTart.guestLimit)); try again when one stops", retry: "after")
        }
    }

    private func cancelWarmBuild() {
        state.lock(); warmCancel = true; let p = warmProc; state.unlock()
        p?.kill()
        waitUntilWarmEnds()
        state.lock(); warmCancel = false; state.unlock()
    }

    // MARK: down

    public func down() throws -> Snapshot {
        op.lock(); defer { op.unlock() }
        touch()
        set(.stopping)
        let gone = destroyWorking()
        saveWarmToDisk() // the task is over: give the memory back
        set(gone ? .stopped : .error)
        if !gone { throw SandboxError("not_deleted", "the sandbox VM could not be deleted", vmDeleted: false) }
        return snapshot()
    }

    /// Kills and deletes the working VM; true when it is verifiably gone (or there was none).
    @discardableResult
    private func destroyWorking() -> Bool {
        state.lock()
        let w = working
        working = nil
        state.unlock()
        guard let w else { return retryPendingDeletes() }
        if let p = w.proc, p.isRunning { p.kill(); _ = p.waitForExit(timeout: 5) }
        let ok = tart.deleteVerified(w.name, proc: w.proc, force: true)
        if !ok { state.lock(); pendingDeletes.insert(w.name); state.unlock() }
        return ok && retryPendingDeletes()
    }

    private func retryPendingDeletes() -> Bool {
        state.lock(); let list = pendingDeletes; state.unlock()
        var ok = true
        for vm in list {
            if tart.deleteVerified(vm, force: true) { state.lock(); pendingDeletes.remove(vm); state.unlock() } else { ok = false }
        }
        return ok
    }

    private func currentWorking() -> Working? {
        state.lock(); defer { state.unlock() }
        return working
    }

    // MARK: reset

    /// A clean guest in place of the working one. Returns how it was done and how long it took.
    @discardableResult
    public func reset() throws -> SandboxResetTiming {
        op.lock(); defer { op.unlock() }
        let cfg = settings()
        touch()
        guard cfg.enabled else { throw SandboxError("off", "the sandbox is off") }
        try ensureOwner()
        guard let w = currentWorking() else { throw SandboxError("not_up", "the sandbox is not up: baneyspaces sandbox up") }
        set(.resetting); fail(nil)
        let t0 = clock.now()
        let rules = SandboxNetwork.rules(hostAddresses: facts.read().ipv4)
        let bad = SandboxNetwork.problems(in: rules)
        guard bad.isEmpty else { set(.error); throw SandboxError("rules_weak", bad.joined(separator: "; "), vmDeleted: false) }
        var route = SandboxResetTiming.Route.swap
        switch SandboxResetPlan.choose(warmReady: warmSnapshot().state == .ready, warmBuilding: warmSnapshot().state == .building) {
        case .swap: route = .swap
        case .waitForWarm: route = .swapAfterWait
        case .cold: route = .cold
        }
        // The old VM dies first: the new one gets the same handoff folder, and two guests must never share it.
        let old = w
        var steps: [(String, TimeInterval)] = []
        var mark = clock.now()
        func lap(_ name: String) { let n = clock.now(); steps.append((name, n - mark)); mark = n }
        mark = clock.now()
        state.lock(); working = nil; state.unlock()
        if let p = old.proc, p.isRunning { p.kill(); _ = p.waitForExit(timeout: 5) }
        lap("kill")
        acquireLap = { lap($0) }
        defer { acquireLap = nil }
        var timing = SandboxResetTiming(route: route, seconds: 0)
        var verifyLater: String?
        do {
            if route == .swapAfterWait, !waitForWarm(limit: warmWaitLimit) { route = .cold }
            let clean = try acquireClean(handoff: old.handoff, rules: rules, cfg: cfg, allowWait: false)
            if !clean.2 { route = .cold }
            state.lock()
            working = Working(name: clean.0, proc: clean.1, task: old.task, handoff: old.handoff, graphics: false, startedAt: clock.now())
            state.unlock()
            let skipped = try recheck(rules: rules, vm: clean.0)
            lap("check")
            verifyLater = skipped ? clean.0 : nil
            // The guest is clean and checked: that is what the budget measures. The old VM's deletion
            // comes after and is retried if it fails.
            timing = SandboxResetTiming(route: route, seconds: clock.now() - t0, steps: steps, from: clean.2 ? acquiredFrom : .disk)
        } catch let e as SandboxError {
            _ = tart.deleteVerified(old.name, proc: old.proc, force: true)
            let gone = destroyWorking()
            fail(e.description); set(.error)
            throw SandboxError(e.code, e.message, vmDeleted: gone && e.vmDeleted)
        }
        if !tart.deleteVerified(old.name, proc: old.proc, force: true) {
            state.lock(); pendingDeletes.insert(old.name); state.unlock()
        }
        startWarmBuild(cfg: cfg)
        state.lock(); lastReset = timing; resetSamples.append(timing.seconds); if resetSamples.count > 200 { resetSamples.removeFirst() }; state.unlock()
        set(.running)
        if let vm = verifyLater { verifyInBackground(vm) }
        return timing
    }

    /// A swapped-in guest is checked again right after the reset returns, because the full check takes
    /// longer than the reset budget: the host's Softnet rules are the same ones a full check passed with
    /// (the stamp), and this proves it from inside. If it fails the VM is deleted, as for `up`.
    private func verifyInBackground(_ vm: String) {
        state.lock(); verifying = true; state.unlock()
        let t = Thread { [weak self] in
            guard let self else { return }
            self.op.lock(); defer { self.op.unlock() }
            defer { self.state.lock(); self.verifying = false; self.state.unlock() }
            guard self.currentWorking()?.name == vm else { return }
            let report = SandboxSelfcheck.run(vm: vm, tart: self.tart, hostFacts: self.facts)
            self.state.lock()
            if report.passed { self.selfcheckAt = self.clock.now(); self.selfcheckProblems = [] }
            else { self.selfcheckStamp = nil; self.selfcheckProblems = report.problems }
            self.state.unlock()
            if !report.passed {
                self.fail("selfcheck_failed: " + report.problems.joined(separator: "; "))
                self.destroyWorking(); self.invalidateWarm(); self.set(.error)
            }
        }
        t.name = "sandbox.verify"
        t.start()
    }

    /// Blocks until the background check after a reset has finished. For the probe and tests.
    public func waitUntilVerified(limit: TimeInterval) -> Bool {
        let end = clock.now() + limit
        while clock.now() < end {
            state.lock(); let v = verifying; state.unlock()
            if !v { return true }
            clock.sleep(0.5)
        }
        return false
    }

    /// After a swap the isolation check is only skipped when the rules are the ones a full check
    /// passed with and the warm clone was checked when it was built; otherwise the full check runs.
    private func recheck(rules: SandboxNetwork.Rules, vm: String) throws -> Bool {
        state.lock(); let stamp = selfcheckStamp; state.unlock()
        if stamp == rules.hash { return true }
        let report = SandboxSelfcheck.run(vm: vm, tart: tart, hostFacts: facts)
        state.lock()
        if report.passed { selfcheckStamp = rules.hash; selfcheckAt = clock.now(); selfcheckProblems = [] }
        else { selfcheckStamp = nil; selfcheckProblems = report.problems }
        state.unlock()
        guard report.passed else {
            invalidateWarm()
            throw SandboxError("selfcheck_failed", report.problems.joined(separator: "; "))
        }
        return false
    }

    // MARK: the warm clone

    /// Builds the next warm clone in the background: clone, boot, check, clean, suspend.
    private func startWarmBuild(cfg: SandboxSettings) {
        // The working VM and the warm build are two guests: with another one running there's no room.
        guard let running = try? tart.runningGuests(), running < SandboxTart.guestLimit else { return }
        state.lock()
        guard warmState != .building, warmState != .ready, !warmCancel else { state.unlock(); return }
        warmState = .building
        let name = SandboxPin.vmPrefix + "s-" + makeID()
        warmName = name
        // In memory only while the sandbox is in use, with a working VM whose task folder it will take over.
        let keepInMemory = SandboxWarmPolicy.location(lastActivity: lastActivity, now: clock.now(), available: memory.availableBytes(), vmMemoryGB: cfg.memoryGB) == .memory
        let folder = keepInMemory ? working?.handoff : nil
        state.unlock()
        let t = Thread { [weak self] in self?.buildWarm(name: name, cfg: cfg, memoryFolder: folder) }
        t.name = "sandbox.warm"
        state.lock(); warmThread = t; state.unlock()
        t.start()
    }

    private func buildWarm(name: String, cfg: SandboxSettings, memoryFolder: String?) {
        var proc: RunningProcess?
        func cancelled() -> Bool { state.lock(); defer { state.unlock() }; return warmCancel }
        func abandon(_ why: String) {
            _ = tart.deleteVerified(name, proc: proc, force: true)
            state.lock()
            warmState = .failed; warmName = nil; warmProc = nil
            if !warmCancel { lastError = "warm clone: \(why)" }
            state.unlock()
        }
        do {
            let rules = SandboxNetwork.rules(hostAddresses: facts.read().ipv4)
            let placeholder = try SandboxHandoff.folder(for: SandboxHandoff.warmPlaceholder, paths: paths)
            try tart.cloneAndSize(image: SandboxPin.image, vm: name, memoryGB: cfg.memoryGB, cpus: cfg.cpus)
            if cancelled() { return abandon("cancelled") }
            let p = try tart.spawnRun(vm: name, options: TartRunOptions(rules: rules, handoff: memoryFolder ?? placeholder.path))
            proc = p
            state.lock(); warmProc = p; state.unlock()
            try tart.waitForAgent(vm: name, proc: p, timeout: bootLimit)
            if cancelled() { return abandon("cancelled") }
            let report = SandboxSelfcheck.run(vm: name, tart: tart, hostFacts: facts)
            guard report.passed else { return abandon("self-check failed: " + report.problems.joined(separator: "; ")) }
            _ = tart.guest(name, "rm -rf /tmp/bsx-* 2>/dev/null; sync", timeout: 30)
            if cancelled() { return abandon("cancelled") }
            // Decided again now: the build takes a minute, and the sandbox may have gone idle or the Mac tight.
            state.lock()
            let stay = memoryFolder != nil && SandboxWarmPolicy.location(lastActivity: lastActivity, now: clock.now(), available: memory.availableBytes(), vmMemoryGB: cfg.memoryGB, resident: true) == .memory
            if stay { warmState = .ready; warmLocation = .memory; warmHandoff = memoryFolder }
            state.unlock()
            if stay { return }
            try tart.suspend(vm: name)
            guard p.waitForExit(timeout: 60) else { return abandon("the VM did not exit after suspend") }
            Self.preread(SandboxPaths.tartHome.appendingPathComponent("vms/\(name)/state.vzvmsave"))
            state.lock()
            warmState = .ready; warmProc = nil; warmLocation = .disk; warmHandoff = nil
            state.unlock()
        } catch {
            abandon("\(error)")
        }
    }

    /// Reads the saved state once so it sits in the page cache: a resume that has to fetch 1.6 GB from the
    /// SSD took twice as long as one that doesn't (measured 10 s against 5 s), and the reset budget is 10.
    static func preread(_ url: URL) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        while let chunk = try? h.read(upToCount: 8 << 20), !chunk.isEmpty {}
    }

    /// Suspends a warm clone that is running in memory and frees its RAM. The disk path is the fallback.
    func saveWarmToDisk() {
        state.lock()
        guard warmState == .ready, warmLocation == .memory, let name = warmName, let p = warmProc else { state.unlock(); return }
        state.unlock()
        do {
            try tart.suspend(vm: name)
            guard p.waitForExit(timeout: 60) else { return invalidateWarm() }
            Self.preread(SandboxPaths.tartHome.appendingPathComponent("vms/\(name)/state.vzvmsave"))
            state.lock(); warmProc = nil; warmLocation = .disk; warmHandoff = nil; state.unlock()
        } catch {
            invalidateWarm()
        }
    }

    private func invalidateWarm() {
        state.lock()
        let name = warmName
        let p = warmProc
        warmState = .none; warmName = nil; warmProc = nil; warmLocation = .disk; warmHandoff = nil
        state.unlock()
        if let name, !tart.deleteVerified(name, proc: p, force: true) {
            state.lock(); pendingDeletes.insert(name); state.unlock()
        }
    }

    /// Blocks until the warm clone is ready or its build ended; true if ready. For the probe and tests.
    public func waitUntilWarm(limit: TimeInterval) -> Bool { waitForWarm(limit: limit) }

    // MARK: health and shutdown

    /// Called every few seconds by whoever hosts the manager: a working VM whose process has gone
    /// (its window was closed, `tart run` crashed) is deleted, not left to rot.
    public func tick() {
        guard op.`try`() else { return }
        defer { op.unlock() }
        if let w = currentWorking(), let p = w.proc, !p.isRunning {
            fail("the sandbox VM exited on its own (its window closed?); it was deleted")
            destroyWorking()
            set(.stopped)
        }
        if !snapshot().pendingDeletes.isEmpty { _ = retryPendingDeletes() }
        // The warm clone stays in memory only while the sandbox is in use and the Mac has room for it.
        state.lock()
        let hold = warmState == .ready && warmLocation == .memory
        let last = lastActivity, running = warmProc?.isRunning ?? false
        state.unlock()
        if hold {
            if !running { invalidateWarm(); return }
            let gb = settings().memoryGB
            if SandboxWarmPolicy.location(lastActivity: last, now: clock.now(), available: memory.availableBytes(), vmMemoryGB: gb, resident: true) == .disk {
                saveWarmToDisk()
            }
        }
    }

    /// App quit: nothing of the sandbox outlives the app. Stops the warm build and deletes every VM.
    public func shutdown() {
        state.lock(); warmCancel = true; let p = warmProc; state.unlock()
        p?.kill()
        op.lock(); defer { op.unlock() }
        destroyWorking()
        invalidateWarm()
        _ = tart.deleteAllOurs()
        set(.stopped)
        state.lock(); warmCancel = false; state.unlock()
    }

    /// Settings > Agents > Delete images: the VMs and the pulled base image. Refuses while the sandbox is up.
    public func deleteImages() throws {
        op.lock(); defer { op.unlock() }
        if currentWorking() != nil { throw SandboxError("busy", "the sandbox is up: baneyspaces sandbox down first") }
        try ensureOwner()
        state.lock(); warmCancel = true; let p = warmProc; state.unlock()
        p?.kill()
        waitUntilWarmEnds()
        invalidateWarm()
        let vmsGone = tart.deleteAllOurs()
        let imageGone = tart.deleteImage()
        state.lock(); warmCancel = false; state.unlock()
        guard vmsGone && imageGone else { throw SandboxError("not_deleted", "some sandbox images could not be deleted", vmDeleted: vmsGone) }
    }

    private func waitUntilWarmEnds() {
        let end = clock.now() + 30
        while warmSnapshot().state == .building, clock.now() < end { clock.sleep(0.5) }
    }

    // MARK: view

    public struct ViewResult: Equatable, Sendable {
        public var workspace: Int
        public var windows: Int
    }

    /// Shows the VM's display on the agent workspace (or hides it again with `show: false`). The window
    /// belongs to the VM's own `tart run`, which can only open one when it starts, so the VM is suspended
    /// and resumed with a window; nothing in the guest is lost. The window is claimed for the agent workspace before
    /// it exists, and anything that still lands elsewhere is moved there. With no agent workspace this
    /// refuses and the VM is left as it was.
    public func view(show: Bool, host: SandboxWindowHost?) throws -> ViewResult? {
        op.lock(); defer { op.unlock() }
        touch()
        guard let w = currentWorking() else { throw SandboxError("not_up", "the sandbox is not up: baneyspaces sandbox up") }
        if !show {
            guard w.graphics else { return nil }
            try relaunch(w, graphics: false, host: nil)
            return nil
        }
        guard let host else { throw SandboxError("no_app", "the window opens in the BaneySpaces app: run this without --local") }
        let workspace: Int
        switch SandboxWindows.beforeLaunch(agentWorkspace: host.agentWorkspace()) {
        case .claim(let n): workspace = n
        case .refuse(let why): throw SandboxError("no_agent_workspace", why, vmDeleted: false)
        case .move: throw SandboxError("internal", "unexpected placement", vmDeleted: false)
        }
        if w.graphics { return try place(pid: w.proc?.pid ?? 0, workspace: workspace, host: host) }
        try relaunch(w, graphics: true, host: host, workspace: workspace)
        let pid = currentWorking()?.proc?.pid ?? 0
        return try place(pid: pid, workspace: workspace, host: host)
    }

    private func place(pid: Int32, workspace: Int, host: SandboxWindowHost) throws -> ViewResult {
        var windows = 0
        let end = clock.now() + 20
        repeat {
            let list = host.windows(of: pid)
            windows = list.count
            let moves = SandboxWindows.afterLaunch(windows: list, vmPid: pid, agentWorkspace: host.agentWorkspace())
            for case .move(let id, let n) in moves { host.move(window: id, to: n) }
            if !list.isEmpty && moves.isEmpty { break }
            clock.sleep(0.5)
        } while clock.now() < end
        return ViewResult(workspace: workspace, windows: windows)
    }

    /// Suspend the working VM and resume it with or without a window. If the resume fails, the VM is
    /// deleted rather than left in a state nobody can see.
    private func relaunch(_ w: Working, graphics: Bool, host: SandboxWindowHost?, workspace: Int? = nil) throws {
        let rules = SandboxNetwork.rules(hostAddresses: facts.read().ipv4)
        try tart.suspend(vm: w.name)
        _ = w.proc?.waitForExit(timeout: 60)
        do {
            // The claim comes first: the window is placed as it opens, not moved after you saw it.
            let p = try tart.spawnRun(vm: w.name, options: TartRunOptions(graphics: graphics, rules: rules, handoff: w.handoff))
            if graphics, let host, let workspace { host.claim(pid: p.pid, workspace: workspace) }
            state.lock(); working?.proc = p; working?.graphics = graphics; state.unlock()
            try tart.waitForAgent(vm: w.name, proc: p, timeout: resumeLimit, poll: 0.25)
        } catch {
            let gone = destroyWorking()
            set(.stopped)
            fail("the sandbox VM could not resume (\(error)); it was deleted")
            throw SandboxError("resume_failed", "\(error)", vmDeleted: gone)
        }
    }

    // MARK: guest

    /// A request to the guest hands daemon (the stub, for now).
    public func guestCall(_ request: GuestHands.Request, counts: Bool = true) -> GuestHands.Reply {
        if counts { touch() }
        guard let w = currentWorking() else {
            return GuestHands.failure(request.id, "not_up", "the sandbox is not up: baneyspaces sandbox up")
        }
        return GuestHands.call(request, vm: w.name, tart: tart)
    }
}
