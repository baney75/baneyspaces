import Foundation

public struct SandboxError: Error, CustomStringConvertible, Equatable {
    public var code: String
    public var message: String
    /// Whether the VM the failing step was working on is verifiably gone.
    public var vmDeleted: Bool
    /// `safe`, `after` (try again when a guest frees up) or `never`, as in the host's envelope.
    public var retry: String
    public init(_ code: String, _ message: String, vmDeleted: Bool = true, retry: String = "never") {
        self.code = code; self.message = message; self.vmDeleted = vmDeleted; self.retry = retry
    }
    public var description: String { "\(code): \(message)" }
}

/// How a VM is started.
public struct TartRunOptions: Equatable, Sendable {
    public var graphics: Bool
    public var rules: SandboxNetwork.Rules
    /// The one host folder shared into the guest, or nil for no share at all.
    public var handoff: String?
    public init(graphics: Bool = false, rules: SandboxNetwork.Rules, handoff: String? = nil) {
        self.graphics = graphics; self.rules = rules; self.handoff = handoff
    }
}

/// Tart, the way BaneyFleet's `TartLauncher` drives it: clone from the pinned image, size the clone, run it
/// on Softnet, reach the guest only through `tart exec`, and delete the VM whatever happened.
/// No ssh, no password: `tart exec` talks to the guest agent over a channel the host owns.
public final class SandboxTart {
    public let binary: String
    public let softnetDir: String
    let runner: ProcessRunning
    let clock: SandboxClock
    let logDir: String?

    public init(tart: String, softnetDir: String, runner: ProcessRunning, clock: SandboxClock, logDir: String? = nil) {
        self.binary = tart; self.softnetDir = softnetDir; self.runner = runner; self.clock = clock; self.logDir = logDir
    }

    /// Softnet is setuid root in a root-owned folder that comes first on the PATH Tart sees.
    var env: [String: String] {
        ["PATH": "\(softnetDir):/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
         "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8"]
    }

    @discardableResult
    func tart(_ args: [String], timeout: TimeInterval = 120, stdin: String? = nil, limit: Int = 1 << 20) -> ProcessResult {
        runner.run(binary, args, env: env, stdin: stdin, timeout: timeout, outputLimit: limit)
    }

    /// Apple Virtualization runs two macOS guests at most, whoever started them.
    public static let guestLimit = 2

    /// How many local VMs are running right now (this code's and anyone else's).
    public func runningGuests() throws -> Int {
        let r = tart(["list", "--source", "local", "--format", "json"], timeout: 60)
        guard r.ok, let data = r.stdout.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw SandboxError("tart_list", "tart list failed (\(r.status)): \(r.tail)")
        }
        return list.filter { ($0["Running"] as? Bool) == true }.count
    }

    // MARK: arguments (pure: tested without a Mac)

    /// `tart run` arguments. Always on Softnet with both lists; refuses rules that fail
    /// `SandboxNetwork.problems`.
    public static func runArguments(vm: String, options o: TartRunOptions) throws -> [String] {
        let bad = SandboxNetwork.problems(in: o.rules)
        guard bad.isEmpty else { throw SandboxError("rules_weak", bad.joined(separator: "; ")) }
        var a = ["run"]
        if !o.graphics { a.append("--no-graphics") }
        a += ["--suspendable", "--no-clipboard", "--no-audio", "--no-usb-accessories"]
        a += ["--net-softnet", "--net-softnet-allow=\(o.rules.allow)", "--net-softnet-block=\(o.rules.block)"]
        if let h = o.handoff { a.append("--dir=\(SandboxPin.handoffName):\(h)") }
        a.append(vm)
        return a
    }

    public static func isOurs(_ vm: String) -> Bool { vm.hasPrefix(SandboxPin.vmPrefix) }

    // MARK: verbs

    public func localVMs() throws -> [String] {
        let r = tart(["list", "--source", "local", "--quiet"], timeout: 60)
        guard r.ok else { throw SandboxError("tart_list", "tart list failed (\(r.status)): \(r.tail)") }
        return r.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Clones the pinned image (pulling it if it isn't in Tart's store yet) and sizes the clone.
    public func cloneAndSize(image: String, vm: String, memoryGB: Int, cpus: Int) throws {
        guard SandboxPin.isPinnedByDigest(image) else { throw SandboxError("image_unpinned", "\(image) is not pinned by digest") }
        let c = tart(["clone", image, vm], timeout: 3600)
        guard c.ok else { throw SandboxError("clone_failed", "tart clone failed (\(c.status)): \(c.tail)") }
        let s = tart(["set", vm, "--memory", String(memoryGB * 1024), "--cpu", String(cpus)])
        guard s.ok else { throw SandboxError("set_failed", "tart set failed (\(s.status)): \(s.tail)") }
    }

    public func spawnRun(vm: String, options: TartRunOptions) throws -> RunningProcess {
        let args = try Self.runArguments(vm: vm, options: options)
        let log = logDir.map { "\($0)/vm-\(vm).log" }
        do { return try runner.spawn(binary, args, env: env, logPath: log) }
        catch { throw SandboxError("run_failed", "could not start tart run: \(error.localizedDescription)") }
    }

    /// Waits until the guest agent answers `tart exec`. Throws if `proc` exits first or time runs out.
    public func waitForAgent(vm: String, proc: RunningProcess, timeout: TimeInterval, poll: TimeInterval = 1) throws {
        let deadline = clock.now() + timeout
        while true {
            if !proc.isRunning { throw SandboxError("vm_exited", "the VM exited before its guest agent answered") }
            let r = tart(["exec", vm, "/usr/bin/true"], timeout: 30)
            if r.ok { return }
            if clock.now() > deadline { throw SandboxError("agent_timeout", "the guest agent did not answer in \(Int(timeout)) s") }
            clock.sleep(poll)
        }
    }

    /// Runs a shell command in the guest.
    /// Everything it prints is the guest's word, so output is capped (`limit`).
    public func guest(_ vm: String, _ command: String, stdin: String? = nil, timeout: TimeInterval = 60, limit: Int = 256 << 10) -> ProcessResult {
        let args = stdin != nil ? ["exec", "-i", vm, "/bin/bash", "-c", command] : ["exec", vm, "/bin/bash", "-c", command]
        return tart(args, timeout: timeout, stdin: stdin, limit: limit)
    }

    /// Waits until the guest has mounted the handoff share (after a resume the guest takes a moment).
    public func waitForShare(vm: String, timeout: TimeInterval) throws {
        let deadline = clock.now() + timeout
        while true {
            if guest(vm, "test -d '\(SandboxPin.guestHandoffPath)'", timeout: 20).ok { return }
            if clock.now() > deadline { throw SandboxError("share_timeout", "the guest did not mount the handoff folder in \(Int(timeout)) s") }
            clock.sleep(0.25)
        }
    }

    public func suspend(vm: String) throws {
        let r = tart(["suspend", vm], timeout: 120)
        guard r.ok else { throw SandboxError("suspend_failed", "tart suspend failed (\(r.status)): \(r.tail)") }
    }

    /// Stops and deletes `vm` and checks it's gone; three tries (a VM can take a moment to let go).
    /// True only when it is verifiably not in `tart list`.
    @discardableResult
    public func deleteVerified(_ vm: String, proc: RunningProcess? = nil, force: Bool = false) -> Bool {
        if let proc, proc.isRunning {
            if force { proc.kill() } else { proc.terminate() }
            if !proc.waitForExit(timeout: 5) { proc.kill(); _ = proc.waitForExit(timeout: 5) }
        }
        for _ in 0..<3 {
            tart(["stop", "--timeout", "5", vm], timeout: 60)
            tart(["delete", vm], timeout: 120)
            if let list = try? localVMs(), !list.contains(vm) { return true }
            clock.sleep(1)
        }
        return false
    }

    /// Every VM this code made and still has, tracked or left behind by a crash.
    public func leftovers() throws -> [String] { try localVMs().filter(Self.isOurs) }

    /// Deletes all leftovers; true when none remain.
    public func deleteAllOurs() -> Bool {
        guard let all = try? leftovers() else { return false }
        var ok = true
        for vm in all { ok = deleteVerified(vm, force: true) && ok }
        return ok
    }

    /// The pulled base image, if it is in Tart's store.
    public func imagePulled(_ image: String = SandboxPin.image) -> Bool {
        let r = tart(["list", "--source", "oci", "--quiet"], timeout: 60)
        guard r.ok else { return false }
        let digest = image.split(separator: "@").last.map(String.init) ?? image
        return r.stdout.contains(digest) || r.stdout.contains(image)
    }

    public func deleteImage(_ image: String = SandboxPin.image) -> Bool {
        guard imagePulled(image) else { return true }
        tart(["delete", image], timeout: 300)
        return !imagePulled(image)
    }
}
