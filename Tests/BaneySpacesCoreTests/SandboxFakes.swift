import Foundation
@testable import BaneySpacesCore

final class FakeClock: SandboxClock {
    private let lock = NSLock()
    private var t: TimeInterval = 1000
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return t }
    func sleep(_ s: TimeInterval) {
        lock.lock(); t += s; lock.unlock()
        Thread.sleep(forTimeInterval: 0.001) // let background threads (the warm build) run
    }
    func advance(_ s: TimeInterval) { lock.lock(); t += s; lock.unlock() }
}

final class FakeProc: RunningProcess {
    static var next: Int32 = 5000
    let pid: Int32
    private let lock = NSLock()
    private var running = true
    var onRelease: (() -> Void)?
    /// A process that ignores kill, like a guest that won't stop.
    var immortal = false
    init() { FakeProc.next += 1; pid = FakeProc.next }
    func release() { onRelease?() }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    func stop() { lock.lock(); running = false; lock.unlock() }
    func terminate() { if !immortal { stop() } }
    func kill() { if !immortal { stop() } }
    func waitForExit(timeout: TimeInterval) -> Bool { !isRunning }
}

/// A fake `tart`: VMs in memory, every verb recorded, failures injectable.
final class FakeTart: ProcessRunning {
    struct VM { var suspended = false; var proc: FakeProc? }
    let lock = NSLock()
    var vms: [String: VM] = [:]
    var imagePulled = false
    var calls: [[String]] = []
    var spawned: [(args: [String], proc: FakeProc)] = []
    var failClone = false
    var failDeleteOnce = 0          // deletes that silently do nothing
    var failResume = false
    var agentNeverAnswers = false
    var leaks: Set<String> = []     // IPs the guest can reach (a broken isolation)
    var noInternet = false
    var guestReply: String?
    var guestTruncated = false
    var stdinSeen: [String] = []
    var onSpawn: ((_ args: [String]) -> Void)?
    var order: [String] = []
    var v6Addresses = 0
    var spawnImmortal = false
    var v6Leak = false
    var firewallState = "Firewall is disabled. (State = 0)"
    var stubFail: ProcessResult?

    func requestID(_ stdin: String?) -> String {
        guard let s = stdin, let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return "x" }
        return o["id"] as? String ?? "x"
    }

    func vmNames() -> [String] { lock.lock(); defer { lock.unlock() }; return vms.keys.sorted() }
    func ours() -> [String] { vmNames().filter { $0.hasPrefix(SandboxPin.vmPrefix) } }

    func run(_ exe: String, _ args: [String], env: [String: String], stdin: String?, timeout: TimeInterval, outputLimit: Int) -> ProcessResult {
        lock.lock(); defer { lock.unlock() }
        calls.append(args)
        if exe.hasSuffix("socketfilterfw") { return ProcessResult(status: 0, stdout: args.contains("--getglobalstate") ? firewallState : "") }
        if exe.hasSuffix("route") { return ProcessResult(status: 0, stdout: "   gateway: 192.168.1.1\n") }
        guard let verb = args.first else { return ProcessResult(status: 2) }
        switch verb {
        case "list":
            if args.contains("oci") { return ProcessResult(status: 0, stdout: imagePulled ? SandboxPin.image + "\n" : "") }
            if args.contains("json") {
                let items = vms.map { "{\"Name\":\"\($0.key)\",\"Running\":\($0.value.proc?.isRunning == true)}" }
                return ProcessResult(status: 0, stdout: "[" + items.joined(separator: ",") + "]")
            }
            return ProcessResult(status: 0, stdout: vms.keys.sorted().joined(separator: "\n"))
        case "clone":
            if failClone { return ProcessResult(status: 1, stderr: "no space left") }
            imagePulled = true
            vms[args[2]] = VM()
            return ProcessResult(status: 0)
        case "set": return ProcessResult(status: 0)
        case "stop": return ProcessResult(status: 0)
        case "delete":
            if failDeleteOnce > 0 { failDeleteOnce -= 1; return ProcessResult(status: 0) }
            vms[args[1]] = nil
            return ProcessResult(status: 0)
        case "suspend":
            guard vms[args[1]]?.proc?.isRunning == true else { return ProcessResult(status: 1, stderr: "not running") }
            vms[args[1]]?.suspended = true
            vms[args[1]]?.proc?.stop()
            return ProcessResult(status: 0)
        case "exec":
            let vm = args.first(where: { $0.hasPrefix(SandboxPin.vmPrefix) }) ?? args[1]
            guard let rec = vms[vm], rec.proc?.isRunning == true, !agentNeverAnswers else { return ProcessResult(status: 1, stderr: "no agent") }
            if args.last == "/usr/bin/true" { return ProcessResult(status: 0) }
            let script = args.last ?? ""
            if script.contains("GATEWAY") { return ProcessResult(status: 0, stdout: checkOutput(script)) }
            if script.contains("V6PROBE") {
                let n = script.components(separatedBy: "echo \"V6PROBE ").count - 1
                var out = "HAS6 2\n"
                for i in 0..<n { out += "V6PROBE \(i) " + (v6Leak && i == 0 ? "RC=0 succeeded!" : "RC=1 nc: connectx failed: Operation timed out") + "\n" }
                return ProcessResult(status: 0, stdout: out)
            }
            if script.contains("route -n get default | awk") { return ProcessResult(status: 0, stdout: "192.168.64.1\n") }
            if script.contains("IFS= read -r line") {
                stdinSeen.append(stdin ?? "")
                if let f = stubFail { return f }
                if let g = guestReply { return ProcessResult(status: 0, stdout: g, truncated: guestTruncated) }
                return ProcessResult(status: 0, stdout: "{\"v\":1,\"id\":\"\(requestID(stdin))\",\"ok\":true,\"data\":{\"daemon\":\"stub\",\"macos\":\"26.6\"}}\n")
            }
            if script.contains("ls /tmp/bsx-dirty-* ") { return ProcessResult(status: 0, stdout: "0\n") }
            return ProcessResult(status: 0)
        default: return ProcessResult(status: 2)
        }
    }

    /// What the guest's check script would print: everything blocked unless `leaks` says otherwise.
    func checkOutput(_ script: String) -> String {
        var out = "GATEWAY 192.168.64.1\nV6 \(v6Addresses)\nWEB \(noInternet ? 7 : 0)\nCONTROL RC=0 Connection to 1.1.1.1 port 443 [tcp/https] succeeded!\n"
        out += "GWPROBE RC=1 nc: connectx to 192.168.64.1 port 5 (tcp) failed: Operation timed out\n"
        var i = 0
        for line in script.split(separator: "\n") where line.hasPrefix("probe p") {
            let ip = line.split(separator: "'").dropFirst().first.map(String.init) ?? ""
            let hit = leaks.contains(ip)
            out += "PROBE \(i) " + (hit ? "RC=0 succeeded!" : "RC=1 nc: connectx to \(ip) port 1 (tcp) failed: Operation timed out") + "\n"
            i += 1
        }
        return out
    }

    func spawn(_ exe: String, _ args: [String], env: [String: String], logPath: String?, hold: Bool) throws -> RunningProcess {
        lock.lock(); defer { lock.unlock() }
        calls.append(args)
        let vm = args.last ?? ""
        guard vms[vm] != nil else { throw SandboxError("run_failed", "no such VM \(vm)") }
        if vms[vm]?.suspended == true && failResume { throw SandboxError("run_failed", "cannot restore state") }
        let p = FakeProc()
        p.immortal = spawnImmortal
        p.onRelease = { [unowned self] in self.lock.lock(); self.order.append("release"); self.lock.unlock() }
        vms[vm]?.proc = p
        vms[vm]?.suspended = false
        spawned.append((args, p))
        order.append("spawn " + (args.contains("--no-graphics") ? "headless" : "graphics") + (hold ? " held" : ""))
        onSpawn?(args)
        return p
    }
}

final class FakeHostFacts: HostFactsReading {
    var facts = HostFacts(addresses: [.init("this Mac's address on en0", "192.168.1.20", iface: "en0"), .init("this Mac's tailnet address", "100.101.102.103", iface: "utun4")],
                          router: "192.168.1.1", tailscaleInstalled: true,
                          bridge6: [.init("this Mac's IPv6 address on bridge100", "fe80::5c9b:a6ff:fe68:4164", iface: "bridge100"),
                                    .init("this Mac's IPv6 address on bridge100", "fdc5:5ced:8bd3:9a9f:1447:5955:8b2d:5e2d", iface: "bridge100")])
    final class L: ProbeListener { var port: UInt16 = 51000; var hits = 0; func accepted() -> Int { hits }; func close() {} }
    var listenerHits = 0
    func read() -> HostFacts { facts }
    func currentAddresses() -> [String] { facts.ipv4 }
    func listener6() -> ProbeListener? { let l = L(); l.hits = listenerHits; return l }
    func listener() -> ProbeListener? { let l = L(); l.hits = listenerHits; return l }
}

final class FakeWindowHost: SandboxWindowHost {
    var workspace: Int? = 9
    var current = 1
    var log: [String] = []
    var shown: [SandboxWindows.Window] = []
    var moves: [(UInt32, Int)] = []
    var onClaim: (() -> Void)?
    func agentWorkspace() -> Int? { workspace }
    var claimResult = true
    func claim(pid: Int32, workspace: Int) -> Bool { log.append("claim \(pid)->\(workspace)"); onClaim?(); return claimResult }
    var windowsDelay: TimeInterval = 0
    func windows(of pid: Int32) -> [SandboxWindows.Window] { if windowsDelay > 0 { Thread.sleep(forTimeInterval: windowsDelay) }; return shown.filter { $0.pid == pid } }
    func move(window: UInt32, to workspace: Int) { moves.append((window, workspace)); for i in shown.indices where shown[i].id == window { shown[i].workspace = workspace }; log.append("move \(window)->\(workspace)") }
}

final class FakeMemory: MemoryReading {
    var bytes: UInt64
    init(gb: UInt64) { bytes = gb << 30 }
    func availableBytes() -> UInt64 { bytes }
}

struct Rig {
    let tart: FakeTart, clock: FakeClock, facts: FakeHostFacts, manager: SandboxManager, st: SandboxTart, dir: URL, memory: FakeMemory
    /// `availableGB` is the free memory the fake Mac reports: 0 keeps the warm clone on disk (most tests),
    /// plenty lets it stay in memory.
    static func make(enabled: Bool = true, availableGB: UInt64 = 0, hostMemoryGB: Int = 32) -> Rig {
        let memory = FakeMemory(gb: availableGB)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bsx-test-\(UUID().uuidString)")
        let ft = FakeTart(), clock = FakeClock(), facts = FakeHostFacts()
        let st = SandboxTart(tart: "/fake/tart", softnetDir: "/fake/softnet", runner: ft, clock: clock)
        let counter = Counter()
        let m = SandboxManager(tart: st, facts: facts, clock: clock, paths: SandboxPaths(root: dir),
                               settings: { SandboxSettings(enabled: enabled) }, makeID: { counter.next() }, memory: memory, hostMemoryGB: hostMemoryGB)
        return Rig(tart: ft, clock: clock, facts: facts, manager: m, st: st, dir: dir, memory: memory)
    }
}

final class Counter {
    private let lock = NSLock()
    private var n = 0
    func next() -> String { lock.lock(); defer { lock.unlock() }; n += 1; return "id\(n)" }
}
