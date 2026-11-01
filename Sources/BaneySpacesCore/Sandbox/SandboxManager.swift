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

/// The sandbox: a throwaway macOS VM, its warm replacement, and every rule that keeps it throwaway. One
/// manager owns the VMs on a Mac (an exclusive lock enforces it), and only the owner ever deletes VMs it did not
/// make itself. Every path that makes a VM deletes it again when anything after it fails.
///
/// - `up`: take the warm clean clone or, with none, clone the pinned image and boot cold; bind the task's
///   handoff files into that VM's own slot; run the isolation self-check in the guest; any failure stops and
///   deletes the VM. Then build the next warm clone in the background.
/// - `reset`: kill the working VM and release its files, promote or resume the warm clone in its place, build another.
/// - `down`: stop and delete the working VM, give the files back, move the warm clone to disk.
///
/// Threads: lifecycle operations hold `op` and may take minutes. Nothing on the main thread waits for `op`;
/// `shutdown` kills the processes first (under the short `state` lock) and cleans up on its own thread.
public final class SandboxManager {
    public enum Phase: String, Sendable { case stopped, starting, running, resetting, stopping, error }
    public enum WarmState: String, Sendable { case none, building, ready, failed }

    public struct Working {
        public var name: String
        public var proc: RunningProcess?
        public var task: String
        /// This VM's own share: where the task's files are while it is the working guest.
        public var slot: URL
        public var graphics: Bool
        public var startedAt: TimeInterval
        /// The hash of the Softnet rules this VM was started with: when the Mac's addresses change it goes stale.
        public var rulesHash: String
    }

    public struct Snapshot: Sendable {
        public var phase: Phase
        public var vm: String?
        public var task: String?
        public var slot: String?
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
        /// Task files still in a slot whose guest is gone or going (slot name -> task); retried until they are safe.
        public var pendingRestores: [String: String]
        /// Entries the last guest made that were not copied out (links, hard links, special files).
        public var skippedOnRelease: [String]
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
    let hostMemoryGB: Int
    /// How long `reset` waits for a warm clone that is still being built.
    public var warmWaitLimit: TimeInterval = 120
    public var bootLimit: TimeInterval = 300
    public var resumeLimit: TimeInterval = 90

    private let op = NSLock()          // one lifecycle operation at a time
    private let state = NSLock()       // guards the fields below; held only for field reads and writes
    private let ownerLock = NSLock()   // guards taking the Mac-wide lock and the startup cleanup
    private var phase: Phase = .stopped
    private var working: Working?
    // The warm clone. `warmName` is also the build's identity: a build that finds it changed (dropped, replaced,
    // shutdown) deletes its own VM and writes nothing.
    private var warmName: String?
    private var warmState: WarmState = .none
    private var warmProc: RunningProcess?
    private var warmLocation: WarmLocation = .disk
    private var warmGroup: DispatchGroup?
    private var shuttingDown = false
    private var selfcheckStamp: String?        // rules hash of the last passed check
    private var selfcheckAt: TimeInterval?
    private var selfcheckProblems: [String] = []
    private var lastReset: SandboxResetTiming?
    private var lastUp: UpTiming?
    private var verifying = false
    private var lastActivity: TimeInterval?
    private var resetSamples: [TimeInterval] = []
    private var acquiredFrom: WarmLocation = .disk
    /// Set while `reset` runs, so the steps inside `acquireClean` can report their time.
    private var acquireLap: ((String) -> Void)?
    private var lastError: String?
    private var pendingDeletes: Set<String> = []
    private var owned = false
    private var lockFD: Int32 = -1
    /// Every VM process spawned and not known dead, so quitting can kill one that is still booting.
    private var inflight: [RunningProcess] = []
    /// A check on a clone found the isolation broken: the working guest is stopped by the next `tick`.
    private var isolationAlarm: String?
    private var warmRulesHash: String?
    private var skippedOnRelease: [String] = []
    /// How much a guest may write into its handoff folder (bytes); `tick` stops a guest past it.
    var handoffLimit: () -> Int64 = { 2 << 30 }

    public init(tart: SandboxTart, facts: HostFactsReading, clock: SandboxClock = SystemClock(), paths: SandboxPaths = SandboxPaths(),
                settings: @escaping () -> SandboxSettings, makeID: @escaping () -> String = { String(UUID().uuidString.prefix(8)).lowercased() },
                memory: MemoryReading = SystemMemory(), hostMemoryGB: Int = Int(ProcessInfo.processInfo.physicalMemory >> 30)) {
        self.memory = memory; self.hostMemoryGB = hostMemoryGB
        self.tart = tart; self.facts = facts; self.clock = clock; self.paths = paths; self.settings = settings; self.makeID = makeID
        self.handoffLimit = { [settings] in Int64(settings().handoffGB) << 30 }
    }

    deinit { if lockFD >= 0 { close(lockFD) } }

    // MARK: ownership and startup cleanup

    /// Takes the exclusive lock (one manager per Mac), makes sure no `bsx-*` VM from an earlier run is left, and only
    /// then puts back the files of any slot that run left bound. If a leftover guest can't be verified deleted the
    /// lock is given up again and this throws `busy`: nothing is owned, and no slot is touched while its guest may
    /// still be writing to it. Nothing is ever deleted without the lock.
    func ensureOwner() throws {
        ownerLock.lock(); defer { ownerLock.unlock() }
        if owned { return }
        try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(paths.lock.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if fd >= 0 { close(fd) }
            throw SandboxError("not_owner", "another BaneySpaces process owns the sandbox: use `baneyspaces sandbox …` (no --local) while the app runs", vmDeleted: true)
        }
        guard tart.deleteAllOurs() else {
            flock(fd, LOCK_UN); close(fd)
            let e = SandboxError("busy", "a sandbox VM from an earlier run would not stop; its files stay where they are until it is gone. Try again shortly.", vmDeleted: false, retry: "after")
            fail(e.description)
            throw e
        }
        lockFD = fd
        owned = true
        recoverSlots()
    }

    private var isOwner: Bool { ownerLock.lock(); defer { ownerLock.unlock() }; return owned }

    /// Every slot the registry still lists has a dead guest by now (all `bsx-*` VMs are deleted): give the files back.
    private func recoverSlots() {
        for (name, _) in SandboxHandoff.pending(paths: paths) {
            let r = SandboxHandoff.release(slot: paths.slots.appendingPathComponent(name), paths: paths)
            if !r.skipped.isEmpty { state.lock(); skippedOnRelease = r.skipped; state.unlock() }
            if !r.complete { fail("could not give back the files in \(name): \(r.failure ?? "unknown")") }
        }
        // Slots that held no task's files are the guest's alone.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: paths.slots.path)) ?? [] {
            SandboxHandoff.removeUnboundSlot(paths.slots.appendingPathComponent(name), paths: paths)
        }
    }

    /// Takes the Mac-wide lock and cleans up after a crash. With `keepOwnership: false` (the sandbox is off) the lock
    /// is given up again, so nothing else (the probe) is kept out while the app merely runs.
    public func startupCleanup(keepOwnership: Bool = true) throws {
        try ensureOwner()
        if !keepOwnership { giveUpOwnership() }
    }

    /// Gives the Mac-wide lock back while no guest runs or builds, so another manager (the probe) can own the
    /// sandbox; the next command here takes it again.
    private func giveUpOwnership() {
        ownerLock.lock(); defer { ownerLock.unlock() }
        state.lock(); let busy = working != nil || warmName != nil; state.unlock()
        if !busy, owned { owned = false; flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
    }

    /// Files whose guest is gone but not yet given back (slot name -> task), without any slot a live VM holds.
    private func pendingRestoresLocked() -> [String: String] {
        var all = SandboxHandoff.pending(paths: paths)
        if let w = working { all[w.slot.lastPathComponent] = nil }
        return all
    }

    // MARK: status

    public func snapshot() -> Snapshot {
        state.lock(); defer { state.unlock() }
        return Snapshot(phase: phase, vm: working?.name, task: working?.task, slot: working?.slot.path, graphics: working?.graphics ?? false,
                        uptime: working.map { clock.now() - $0.startedAt }, warm: warmState,
                        warmLocation: warmState == .ready ? warmLocation : .disk, resetStats: SandboxResetStats(samples: resetSamples),
                        selfcheck: verifying ? "verifying" : (selfcheckStamp == nil ? (selfcheckProblems.isEmpty ? "none" : "failed") : "passed"),
                        selfcheckProblems: selfcheckProblems, lastReset: lastReset, lastError: lastError,
                        rulesHash: selfcheckStamp, pendingDeletes: pendingDeletes.sorted(), lastUp: lastUp,
                        pendingRestores: pendingRestoresLocked(), skippedOnRelease: skippedOnRelease)
    }

    /// A sandbox command: keeps the warm clone in memory for the next 15 minutes.
    func touch() { state.lock(); lastActivity = clock.now(); state.unlock() }

    private func set(_ p: Phase) { state.lock(); phase = p; state.unlock() }
    private func fail(_ e: String?) { state.lock(); lastError = e; state.unlock() }
    private var isShuttingDown: Bool { state.lock(); defer { state.unlock() }; return shuttingDown }

    private func asSandboxError(_ error: Error) -> SandboxError {
        (error as? SandboxError) ?? SandboxError("error", "\(error)")
    }

    /// Starts a `tart run` and records the process the moment it exists, so quitting can kill a guest that is
    /// still booting. Refuses once shutdown has begun, and kills a process that began just as it did.
    private func spawn(_ vm: String, _ options: TartRunOptions, hold: Bool = false) throws -> RunningProcess {
        if isShuttingDown { throw SandboxError("shutting_down", "BaneySpaces is quitting") }
        let p = try tart.spawnRun(vm: vm, options: options, hold: hold)
        state.lock()
        inflight.removeAll { !$0.isRunning }
        inflight.append(p)
        let quitting = shuttingDown
        state.unlock()
        if quitting { p.kill(); throw SandboxError("shutting_down", "BaneySpaces is quitting") }
        return p
    }

    /// Checked by every wait loop.
    private var cancelled: () -> Bool { { [weak self] in self?.isShuttingDown ?? true } }

    /// Gives a dead guest's files back and says whether they are safe (and the slot gone). While the guest's process
    /// may still run, or on any failure, the slot and its registry entry stay and this returns false; `tick` retries.
    @discardableResult
    private func giveBack(_ slot: URL) -> Bool {
        let r = SandboxHandoff.release(slot: slot, paths: paths, limitBytes: max(handoffLimit(), 1 << 20) * 2)
        state.lock()
        if !r.skipped.isEmpty { skippedOnRelease = r.skipped }
        if !r.complete { lastError = "the task's files are still in \(slot.lastPathComponent): \(r.failure ?? "unknown"); they will be retried" }
        state.unlock()
        return r.complete
    }

    // MARK: up

    @discardableResult
    public func up(task requested: String?) throws -> Snapshot {
        op.lock(); defer { op.unlock() }
        let cfg = settings()
        touch()
        guard cfg.enabled else { throw SandboxError("off", "the sandbox is off: Settings > Agents, or baneyspaces sandbox on") }
        if let why = SandboxSettings.hostProblem(hostMemoryGB: hostMemoryGB) { throw SandboxError("host_too_small", why) }
        let task = requested ?? SandboxHandoff.defaultTask()
        guard SandboxHandoff.valid(task) else { throw SandboxError("bad_task", "a task name is letters, digits, . - _ (up to 64): \(task)") }
        if isShuttingDown { throw SandboxError("shutting_down", "BaneySpaces is quitting") }
        try ensureOwner()
        if let w = currentWorking() {
            guard w.task == task || requested == nil else {
                throw SandboxError("busy", "the sandbox is up for task \(w.task): baneyspaces sandbox down first", retry: "after")
            }
            return snapshot()
        }
        set(.starting); fail(nil)
        do {
            _ = try SandboxHandoff.folder(for: task, paths: paths)
            try bringUp(task: task, cfg: cfg)
        } catch {
            let e = asSandboxError(error)
            fail(e.description); set(e.code == "busy" ? .stopped : .error)
            throw e
        }
        set(.running)
        return snapshot()
    }

    /// Gets a clean, checked guest and makes it the working VM. On any failure the VM it made is gone.
    private func bringUp(task: String, cfg: SandboxSettings) throws {
        let t0 = clock.now()
        let rules = SandboxNetwork.rules(hostAddresses: facts.read().ipv4)
        let bad = SandboxNetwork.problems(in: rules)
        guard bad.isEmpty else { throw SandboxError("rules_weak", bad.joined(separator: "; ")) }
        let got = try acquireClean(task: task, rules: rules, cfg: cfg, allowWait: true)
        state.lock()
        working = Working(name: got.name, proc: got.proc, task: task, slot: got.slot, graphics: false, startedAt: clock.now(), rulesHash: got.rulesHash)
        isolationAlarm = nil
        state.unlock()
        let booted = clock.now()
        let report = SandboxSelfcheck.run(vm: got.name, tart: tart, hostFacts: facts)
        let checked = clock.now()
        if report.passed {
            state.lock()
            selfcheckStamp = rules.hash; selfcheckAt = checked; selfcheckProblems = []
            lastUp = UpTiming(route: got.viaWarm ? "warm" : "cold", bootSeconds: booted - t0, selfcheckSeconds: checked - booted)
            state.unlock()
        } else {
            state.lock(); selfcheckStamp = nil; selfcheckProblems = report.problems; state.unlock()
            let gone = destroyWorking()
            dropWarm() // the warm clone shares the rules and the image: not trusted either
            throw SandboxError("selfcheck_failed", report.problems.joined(separator: "; "), vmDeleted: gone)
        }
        startWarmBuild(cfg: cfg)
    }

    struct Acquired { var name: String; var proc: RunningProcess; var slot: URL; var viaWarm: Bool; var rulesHash: String }

    /// The warm clone taken over, or a cold boot. A failed step deletes what it made (and puts the task's
    /// files back) before throwing.
    private func acquireClean(task: String, rules: SandboxNetwork.Rules, cfg: SandboxSettings, allowWait: Bool) throws -> Acquired {
        var choice = SandboxResetPlan.choose(warmReady: warmSnapshot().state == .ready, warmBuilding: warmSnapshot().state == .building)
        if choice == .waitForWarm {
            if allowWait, waitForWarm(limit: warmWaitLimit) { choice = .swap } else { choice = .cold }
        }
        if isShuttingDown { throw SandboxError("shutting_down", "BaneySpaces is quitting") }
        if choice == .swap, let got = try? takeOverWarm(task: task, rules: rules) { return got }
        return try coldBoot(task: task, rules: rules, cfg: cfg)
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
            if w.state != .building || isShuttingDown { return false }
            clock.sleep(1)
        }
        return false
    }

    /// Makes the warm clone the working VM: its own slot gets the task's files, then it is promoted (running in
    /// memory) or resumed (saved on disk). It is spent either way. The previous working guest is already dead.
    /// A running clone started under other Softnet rules than today's (the Mac's addresses changed) is saved to
    /// disk first and resumed with the current ones.
    private func takeOverWarm(task: String, rules: SandboxNetwork.Rules) throws -> Acquired {
        state.lock()
        let stale = warmState == .ready && warmLocation == .memory && warmRulesHash != rules.hash
        state.unlock()
        if stale { saveWarmToDisk() }
        state.lock()
        guard warmState == .ready, let name = warmName else { state.unlock(); throw SandboxError("no_warm", "no warm clone") }
        let inMemory = warmLocation == .memory
        let running = warmProc
        warmState = .none; warmName = nil; warmProc = nil; warmLocation = .disk; warmRulesHash = nil
        state.unlock()
        let slot = paths.slots.appendingPathComponent(name)
        var proc: RunningProcess? = inMemory ? running : nil
        var bound = false
        do {
            if !inMemory { try makeRoom() }
            acquireLap?("room")
            try SandboxHandoff.bind(task: task, slot: slot, paths: paths)
            bound = true
            if inMemory {
                guard let p = proc, p.isRunning else { throw SandboxError("vm_exited", "the warm clone had exited") }
                try tart.waitForAgent(vm: name, proc: p, timeout: 20, poll: 0.1, cancelled: cancelled)
            } else {
                let p = try spawn(name, TartRunOptions(rules: rules, handoff: slot.path))
                proc = p
                try tart.waitForAgent(vm: name, proc: p, timeout: resumeLimit, poll: 0.1, cancelled: cancelled)
            }
            acquireLap?("resume")
            try tart.waitForShare(vm: name, timeout: 30, cancelled: cancelled)
            acquireLap?("share")
            acquiredFrom = inMemory ? .memory : .disk
            return Acquired(name: name, proc: proc!, slot: slot, viaWarm: true, rulesHash: rules.hash)
        } catch {
            if let p = proc, p.isRunning { p.kill(); _ = p.waitForExit(timeout: 5) }
            let dead = proc?.isRunning != true
            let safe = !bound || (dead && giveBack(slot))   // the files go back before anything is deleted
            let gone = tart.deleteVerified(name, proc: proc, force: true)
            if bound && !safe && gone { giveBack(slot) }
            if !bound { SandboxHandoff.removeUnboundSlot(slot, paths: paths) }
            throw error
        }
    }

    private func coldBoot(task: String, rules: SandboxNetwork.Rules, cfg: SandboxSettings) throws -> Acquired {
        try makeRoom()
        let name = SandboxPin.vmPrefix + "w-" + makeID()
        var proc: RunningProcess?
        var slot: URL?
        var bound = false
        do {
            slot = try SandboxHandoff.makeSlot(vm: name, paths: paths)
            try tart.cloneAndSize(image: SandboxPin.image, vm: name, memoryGB: cfg.memoryGB, cpus: cfg.cpus)
            let p = try spawn(name, TartRunOptions(rules: rules, handoff: slot!.path))
            proc = p
            try tart.waitForAgent(vm: name, proc: p, timeout: bootLimit, cancelled: cancelled)
            SandboxSelfcheck.harden(vm: name, tart: tart)
            try SandboxHandoff.bind(task: task, slot: slot!, paths: paths)
            bound = true
            try tart.waitForShare(vm: name, timeout: 60, cancelled: cancelled)
            acquiredFrom = .disk
            return Acquired(name: name, proc: p, slot: slot!, viaWarm: false, rulesHash: rules.hash)
        } catch {
            if let p = proc, p.isRunning { p.kill(); _ = p.waitForExit(timeout: 5) }
            let dead = proc?.isRunning != true
            let safe = !bound || (dead && giveBack(slot!))
            let gone = tart.deleteVerified(name, proc: proc, force: true)
            if bound && !safe && gone, let slot { giveBack(slot) }
            if !bound, let slot { SandboxHandoff.removeUnboundSlot(slot, paths: paths) }
            let e = asSandboxError(error)
            throw SandboxError(e.code, e.message, vmDeleted: gone, retry: e.retry)
        }
    }

    /// Apple allows two macOS guests at once, whoever started them. The warm clone being built is ours to
    /// give up; anything else running is not, and the request gets `busy` (try again later).
    private func makeRoom() throws {
        var running = try tart.runningGuests()
        if running >= SandboxTart.guestLimit, warmSnapshot().state == .building {
            dropWarm()
            running = try tart.runningGuests()
        }
        if running >= SandboxTart.guestLimit {
            throw SandboxError("busy", "\(running) macOS guests are already running (Apple's limit is \(SandboxTart.guestLimit)); try again when one stops", retry: "after")
        }
    }

    // MARK: down

    public func down() throws -> Snapshot {
        op.lock(); defer { op.unlock() }
        touch()
        set(.stopping)
        let gone = destroyWorking()
        saveWarmToDisk() // the task is over: give the memory back
        set(gone ? .stopped : .error)
        if !gone { throw SandboxError("not_deleted", "the sandbox VM could not be deleted, or its files could not be given back yet; both are retried and nothing was discarded", vmDeleted: false, retry: "after") }
        return snapshot()
    }

    /// Kills and deletes the working VM and gives the task's files back; true when it is verifiably gone and the files
    /// are safe (or there was none). The files move only once the process is dead, and the slot is only ever removed by
    /// a release that copied everything: a VM that won't die, or a release that fails, leaves both in place for `tick`.
    @discardableResult
    private func destroyWorking() -> Bool {
        state.lock()
        let w = working
        working = nil
        state.unlock()
        guard let w else { return retryPending() }
        if let p = w.proc, p.isRunning { p.kill(); _ = p.waitForExit(timeout: 5) }
        var restored = false
        if w.proc?.isRunning != true { restored = giveBack(w.slot) }
        let gone = tart.deleteVerified(w.name, proc: w.proc, force: true)
        if gone && !restored { restored = giveBack(w.slot) } // it is certainly dead now
        if !gone { state.lock(); pendingDeletes.insert(w.name); state.unlock() }
        return gone && restored && retryPending()
    }

    /// Retries deletes that didn't take and files not yet given back. A slot is released only when its VM is verified
    /// absent from Tart, so a guest that may still run never has its folder touched.
    private func retryPending() -> Bool {
        state.lock(); let list = pendingDeletes; state.unlock()
        var ok = true
        for vm in list {
            if tart.deleteVerified(vm, force: true) { state.lock(); pendingDeletes.remove(vm); state.unlock() } else { ok = false }
        }
        guard let present = try? tart.localVMs() else { return false }
        for (slotName, _) in SandboxHandoff.pending(paths: paths) where !present.contains(slotName) {
            state.lock(); let live = working?.name == slotName; state.unlock()
            if live { continue }
            if !giveBack(paths.slots.appendingPathComponent(slotName)) { ok = false }
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
        if isShuttingDown { throw SandboxError("shutting_down", "BaneySpaces is quitting") }
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
        // The old VM dies first and its files come back, so the next guest is the only one that has them.
        let old = w
        var steps: [(String, TimeInterval)] = []
        var mark = clock.now()
        func lap(_ name: String) { let n = clock.now(); steps.append((name, n - mark)); mark = n }
        state.lock(); working = nil; state.unlock()
        if let p = old.proc, p.isRunning { p.kill(); _ = p.waitForExit(timeout: 5) }
        let oldDead = old.proc?.isRunning != true
        let oldSafe = oldDead && giveBack(old.slot)
        lap("kill")
        acquireLap = { lap($0) }
        defer { acquireLap = nil }
        var timing = SandboxResetTiming(route: route, seconds: 0)
        var verifyLater: String?
        do {
            guard oldDead else { throw SandboxError("not_stopped", "the old sandbox VM would not stop; its files stay where they are", vmDeleted: false, retry: "after") }
            guard oldSafe else { throw SandboxError("handoff_pending", "the task's files could not be given back yet, so the next guest does not get them: \(snapshot().lastError ?? "")", vmDeleted: false, retry: "after") }
            if route == .swapAfterWait, !waitForWarm(limit: warmWaitLimit) { route = .cold }
            let got = try acquireClean(task: old.task, rules: rules, cfg: cfg, allowWait: false)
            if !got.viaWarm { route = .cold }
            state.lock()
            working = Working(name: got.name, proc: got.proc, task: old.task, slot: got.slot, graphics: false, startedAt: clock.now(), rulesHash: got.rulesHash)
            state.unlock()
            let skipped = try recheck(rules: rules, vm: got.name)
            lap("check")
            verifyLater = skipped ? got.name : nil
            // The guest is clean and checked: that is what the budget measures. The old VM's deletion
            // comes after and is retried if it fails.
            timing = SandboxResetTiming(route: route, seconds: clock.now() - t0, steps: steps, from: got.viaWarm ? acquiredFrom : .disk)
        } catch {
            let e = asSandboxError(error)
            let gone0 = tart.deleteVerified(old.name, proc: old.proc, force: true)
            if gone0 { giveBack(old.slot) }   // idempotent: nothing is removed unless every file is safe
            let gone = destroyWorking()
            fail(e.description); set(.error)
            throw SandboxError(e.code, e.message, vmDeleted: gone && e.vmDeleted, retry: e.retry)
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
    /// longer than the reset budget: the host's Softnet rules are the same ones a full check already passed
    /// with (the stamp), and this proves it from inside. If it fails the VM is deleted, as for `up`.
    private func verifyInBackground(_ vm: String) {
        state.lock(); verifying = true; state.unlock()
        let t = Thread { [weak self] in
            guard let self else { return }
            self.op.lock(); defer { self.op.unlock() }
            defer { self.state.lock(); self.verifying = false; self.state.unlock() }
            guard !self.isShuttingDown, self.currentWorking()?.name == vm else { return }
            let report = SandboxSelfcheck.run(vm: vm, tart: self.tart, hostFacts: self.facts)
            self.state.lock()
            if report.passed { self.selfcheckAt = self.clock.now(); self.selfcheckProblems = [] }
            else { self.selfcheckStamp = nil; self.selfcheckProblems = report.problems }
            self.state.unlock()
            if !report.passed {
                self.fail("selfcheck_failed: " + report.problems.joined(separator: "; "))
                self.destroyWorking(); self.dropWarm(); self.set(.error)
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

    /// After a swap the isolation check is only skipped when the rules are the ones a full check passed
    /// with and the warm clone was checked when it was built; otherwise the full check runs.
    private func recheck(rules: SandboxNetwork.Rules, vm: String) throws -> Bool {
        state.lock(); let stamp = selfcheckStamp; state.unlock()
        if stamp == rules.hash { return true }
        let report = SandboxSelfcheck.run(vm: vm, tart: tart, hostFacts: facts)
        state.lock()
        if report.passed { selfcheckStamp = rules.hash; selfcheckAt = clock.now(); selfcheckProblems = [] }
        else { selfcheckStamp = nil; selfcheckProblems = report.problems }
        state.unlock()
        guard report.passed else {
            dropWarm()
            throw SandboxError("selfcheck_failed", report.problems.joined(separator: "; "))
        }
        return false
    }

    // MARK: the warm clone

    /// Builds the next warm clone in the background: clone, boot with a slot of its own (empty, private), check,
    /// clean, then keep it running (in use, memory to spare) or suspend it. It is bound to no task until a
    /// reset or `up` takes it over.
    private func startWarmBuild(cfg: SandboxSettings) {
        // The working VM and the warm build are two guests: with another one running there's no room.
        guard let running = try? tart.runningGuests(), running < SandboxTart.guestLimit else { return }
        state.lock()
        guard warmState != .building, warmState != .ready, !shuttingDown else { state.unlock(); return }
        warmState = .building
        let name = SandboxPin.vmPrefix + "s-" + makeID()
        warmName = name
        let group = DispatchGroup()
        group.enter()
        warmGroup = group
        state.unlock()
        let t = Thread { [weak self] in
            self?.buildWarm(name: name, cfg: cfg)
            group.leave()
        }
        t.name = "sandbox.warm"
        t.start()
    }

    private func buildWarm(name: String, cfg: SandboxSettings) {
        var proc: RunningProcess?
        var slot: URL?
        /// This build is still the one the manager wants.
        func current() -> Bool { state.lock(); defer { state.unlock() }; return warmName == name && !shuttingDown }
        func abandon(_ why: String) {
            let wasCurrent: Bool
            state.lock()
            wasCurrent = warmName == name
            if wasCurrent { warmState = .failed; warmName = nil; warmProc = nil; warmLocation = .disk; lastError = "warm clone: \(why)" }
            state.unlock()
            _ = tart.deleteVerified(name, proc: proc, force: true)
            if let slot { SandboxHandoff.removeUnboundSlot(slot, paths: paths) }
        }
        do {
            let rules = SandboxNetwork.rules(hostAddresses: facts.read().ipv4)
            slot = try SandboxHandoff.makeSlot(vm: name, paths: paths)
            try tart.cloneAndSize(image: SandboxPin.image, vm: name, memoryGB: cfg.memoryGB, cpus: cfg.cpus)
            guard current() else { return abandon("cancelled") }
            let p = try spawn(name, TartRunOptions(rules: rules, handoff: slot!.path))
            proc = p
            state.lock()
            if warmName == name { warmProc = p; warmRulesHash = rules.hash }
            state.unlock()
            guard current() else { p.kill(); return abandon("cancelled") }
            try tart.waitForAgent(vm: name, proc: p, timeout: bootLimit, cancelled: cancelled)
            guard current() else { return abandon("cancelled") }
            SandboxSelfcheck.harden(vm: name, tart: tart)
            let report = SandboxSelfcheck.run(vm: name, tart: tart, hostFacts: facts)
            guard report.passed else {
                // A clone that can reach what it must not says the isolation is broken for the working guest too (same
                // image, same Softnet): the stamp goes and `tick` stops that guest. A plain "no internet" does not.
                if report.breach {
                    state.lock()
                    selfcheckStamp = nil; selfcheckProblems = report.problems
                    isolationAlarm = "a new clone's self-check found the isolation broken: " + report.problems.joined(separator: "; ")
                    state.unlock()
                }
                return abandon("self-check failed: " + report.problems.joined(separator: "; "))
            }
            _ = tart.guest(name, "rm -rf /tmp/bsx-* 2>/dev/null; sync", timeout: 30)
            guard current() else { return abandon("cancelled") }
            // Decided now: the build takes a minute, and the sandbox may have gone idle or the Mac tight.
            state.lock()
            let stay = warmName == name && SandboxWarmPolicy.location(lastActivity: lastActivity, now: clock.now(), available: memory.availableBytes(),
                                                                       vmMemoryGB: cfg.memoryGB, resident: true) == .memory
            if stay { warmState = .ready; warmLocation = .memory }
            state.unlock()
            if stay { return }
            try tart.suspend(vm: name)
            guard p.waitForExit(timeout: 60) else { return abandon("the VM did not exit after suspend") }
            Self.preread(SandboxPaths.tartHome.appendingPathComponent("vms/\(name)/state.vzvmsave"))
            state.lock()
            let ok = warmName == name && !shuttingDown
            if ok { warmState = .ready; warmProc = nil; warmLocation = .disk }
            state.unlock()
            if !ok { abandon("cancelled") }
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
            guard p.waitForExit(timeout: 60) else { return dropWarm() }
            Self.preread(SandboxPaths.tartHome.appendingPathComponent("vms/\(name)/state.vzvmsave"))
            state.lock()
            if warmName == name { warmProc = nil; warmLocation = .disk }
            state.unlock()
        } catch {
            dropWarm()
        }
    }

    /// Forgets the warm clone, stops whatever builds or runs it, waits for the build thread to end, and deletes
    /// the VM and its slot. A build that finds itself dropped deletes its own VM and writes nothing.
    private func dropWarm() {
        state.lock()
        let name = warmName
        let p = warmProc
        let group = warmGroup
        warmState = .none; warmName = nil; warmProc = nil; warmLocation = .disk; warmGroup = nil
        state.unlock()
        p?.kill()
        if let group, group.wait(timeout: .now() + 60) == .timedOut { fail("the warm build did not stop in 60 s") }
        guard let name else { return }
        if tart.deleteVerified(name, proc: p, force: true) {
            SandboxHandoff.removeUnboundSlot(paths.slots.appendingPathComponent(name), paths: paths)
        } else {
            state.lock(); pendingDeletes.insert(name); state.unlock()
        }
    }

    /// Blocks until the warm clone is ready or its build ended; true if ready. For the probe and tests.
    public func waitUntilWarm(limit: TimeInterval) -> Bool { waitForWarm(limit: limit) }

    // MARK: health and shutdown

    /// Called every few seconds by whoever hosts the manager: a working VM whose process has gone (its window
    /// was closed, `tart run` crashed) is deleted; the warm clone is moved to disk when it should not hold memory.
    public func tick() {
        guard op.`try`() else { return }
        defer { op.unlock() }
        if isShuttingDown { return }
        if let w = currentWorking(), let p = w.proc, !p.isRunning {
            fail("the sandbox VM exited on its own (its window closed?); it was deleted")
            destroyWorking()
            set(.stopped)
        }
        // A new clone's check found the isolation broken: the guest in use runs on the same image and rules.
        state.lock(); let alarm = isolationAlarm; isolationAlarm = nil; state.unlock()
        if let alarm, currentWorking() != nil {
            destroyWorking(); fail(alarm); set(.error)
        }
        // The Mac's addresses changed (a new network, a VPN): the guest's block list is out of date, so it is stopped.
        if let w = currentWorking() {
            let now = SandboxNetwork.rules(hostAddresses: facts.currentAddresses()).hash
            if now != w.rulesHash {
                destroyWorking()
                fail("the Mac's network addresses changed, so the sandbox's block list was out of date; the sandbox was stopped and its files are in the task folder. Run `baneyspaces sandbox up` again.")
                set(.stopped)
            }
        }
        // A guest that fills its handoff folder fills the host's disk: past the cap it is stopped.
        var overQuota = false
        if let w = currentWorking() {
            let limit = handoffLimit()
            let used = SandboxHandoff.size(of: w.slot, stopAfter: limit)
            if (used ?? .max) > limit {
                overQuota = true
                destroyWorking()
                fail(used == nil
                     ? "handoff_full: the guest's handoff folder could not be measured (nested too deep, too many entries, or unreadable); the sandbox was stopped"
                     : "handoff_full: the guest wrote more than \(limit >> 20) MB into its handoff folder; the sandbox was stopped and what fits is in the task folder")
                set(.error)
            }
        }
        // Without the lock another manager may be giving back its own slots: only the owner retries. A guest just
        // stopped for its quota was retried by `destroyWorking`; retrying again would replace the reason it stopped.
        if isOwner, !overQuota, !snapshot().pendingDeletes.isEmpty || !pendingRestoresLocked().isEmpty { _ = retryPending() }
        state.lock()
        let hold = warmState == .ready && warmLocation == .memory
        let last = lastActivity, running = warmProc?.isRunning ?? false
        state.unlock()
        guard hold else { return }
        if !running { dropWarm(); return }
        let gb = settings().memoryGB
        // Another tool's VM needs the second guest slot the warm clone is holding: give it back (documented:
        // up to one tick, 5 s).
        let foreign = ((try? tart.localVMs()) ?? []).contains { !SandboxTart.isOurs($0) }
        if foreign || SandboxWarmPolicy.location(lastActivity: last, now: clock.now(), available: memory.availableBytes(), vmMemoryGB: gb, resident: true) == .disk {
            saveWarmToDisk()
        }
    }

    /// App quit. Never blocks the main thread on a lifecycle operation: every VM process, including one still booting
    /// (they are all recorded the moment they exist), is killed at once under the state lock, nothing can be spawned
    /// after, and the deletes and the files going back run on their own thread; this waits at most `deadline`
    /// seconds for them. What is left is cleaned up at the next launch. A manager that never took the owner lock
    /// deletes nothing.
    public func shutdown(deadline: TimeInterval = 5) {
        state.lock()
        shuttingDown = true
        let procs = inflight + [working?.proc, warmProc].compactMap { $0 }
        state.unlock()
        for p in procs { p.kill() }
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread { [self] in
            defer { done.signal() }
            guard op.lock(before: Date().addingTimeInterval(deadline)) else { return }
            defer { op.unlock() }
            teardown()
        }
        _ = done.wait(timeout: .now() + deadline)
    }

    /// Settings turned the sandbox off: everything of it goes (VMs, warm clone), files back in their folders. Once
    /// every VM is verified gone the lock is given back, so the probe isn't kept out while the app merely runs.
    public func stopAll() {
        op.lock(); defer { op.unlock() }
        if teardown() { giveUpOwnership() }
    }

    /// True when this manager owned the sandbox and every one of its VMs is verified gone.
    @discardableResult
    private func teardown() -> Bool {
        destroyWorking()
        dropWarm()
        let gone = isOwner && tart.deleteAllOurs()
        if gone { state.lock(); pendingDeletes = []; state.unlock(); recoverSlots() } // every `bsx-*` VM is verified gone
        set(.stopped)
        return gone
    }

    /// Settings > Agents > Delete images: the VMs and the pulled base image. Refuses while the sandbox is up.
    public func deleteImages() throws {
        op.lock(); defer { op.unlock() }
        if currentWorking() != nil { throw SandboxError("busy", "the sandbox is up: baneyspaces sandbox down first") }
        try ensureOwner()
        dropWarm()
        let vmsGone = tart.deleteAllOurs()
        if vmsGone { recoverSlots() }
        let imageGone = tart.deleteImage()
        guard vmsGone && imageGone else { throw SandboxError("not_deleted", "some sandbox images could not be deleted", vmDeleted: vmsGone) }
    }

    // MARK: view

    public struct ViewResult: Equatable, Sendable {
        public var workspace: Int
        public var windows: Int
    }

    /// Shows the VM's display on the agent workspace (or hides it again with `show: false`). The window
    /// belongs to the VM's own `tart run`, which can only open one when it starts, so the VM is suspended
    /// and resumed with a window; nothing in the guest is lost. The new process is held at a barrier until
    /// its window claim is registered, so the window opens on the agent workspace from its first frame, and
    /// anything that still lands elsewhere is moved there. With no agent workspace this refuses and the VM is left as it was.
    public func view(show: Bool, host: SandboxWindowHost?) throws -> ViewResult? {
        op.lock(); defer { op.unlock() }
        touch()
        if isShuttingDown { throw SandboxError("shutting_down", "BaneySpaces is quitting") }
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
            if isShuttingDown { throw SandboxError("shutting_down", "BaneySpaces is quitting", vmDeleted: false) }
            let list = host.windows(of: pid)
            windows = list.count
            let moves = SandboxWindows.afterLaunch(windows: list, vmPid: pid, agentWorkspace: host.agentWorkspace())
            for case .move(let id, let n) in moves { host.move(window: id, to: n) }
            if !list.isEmpty && moves.isEmpty { break }
            clock.sleep(0.5)
        } while clock.now() < end
        return ViewResult(workspace: workspace, windows: windows)
    }

    /// Suspend the working VM and resume it with or without a window, on the same slot. If the resume fails,
    /// the VM is deleted rather than left in a state nobody can see.
    private func relaunch(_ w: Working, graphics: Bool, host: SandboxWindowHost?, workspace: Int? = nil) throws {
        let rules = SandboxNetwork.rules(hostAddresses: facts.read().ipv4)
        try tart.suspend(vm: w.name)
        _ = w.proc?.waitForExit(timeout: 60)
        do {
            // Held at a barrier: the claim is in place before the program runs a single instruction, so its
            // window can't open anywhere else first.
            let p = try spawn(w.name, TartRunOptions(graphics: graphics, rules: rules, handoff: w.slot.path), hold: graphics)
            if graphics, let host, let workspace, !host.claim(pid: p.pid, workspace: workspace) {
                // Nothing of the program has run: it never showed a window. Back to headless, and say so.
                p.kill(); _ = p.waitForExit(timeout: 5)
                let back = try spawn(w.name, TartRunOptions(graphics: false, rules: rules, handoff: w.slot.path))
                state.lock(); working?.proc = back; working?.graphics = false; state.unlock()
                try tart.waitForAgent(vm: w.name, proc: back, timeout: resumeLimit, poll: 0.25, cancelled: cancelled)
                throw SandboxError("claim_failed", "could not reserve the agent workspace for the window in time; the sandbox is still headless", vmDeleted: false)
            }
            p.release()
            state.lock(); working?.proc = p; working?.graphics = graphics; working?.rulesHash = rules.hash; state.unlock()
            try tart.waitForAgent(vm: w.name, proc: p, timeout: resumeLimit, poll: 0.25, cancelled: cancelled)
        } catch let e as SandboxError where e.code == "claim_failed" {
            throw e
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
