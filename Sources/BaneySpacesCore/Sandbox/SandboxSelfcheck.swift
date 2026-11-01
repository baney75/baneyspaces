import Foundation

/// What the guest must not be able to reach, read from this Mac.
public struct HostFacts: Equatable, Sendable {
    public struct Address: Equatable, Sendable {
        public var label: String
        public var ip: String
        /// The interface it is on ("en0", "bridge100"), or "".
        public var iface: String
        public init(_ label: String, _ ip: String, iface: String = "") { self.label = label; self.ip = ip; self.iface = iface }
    }
    public var addresses: [Address]
    /// IPv6 addresses of the vmnet bridge (link-local and unique-local): the Mac's side of the guest's link.
    public var bridge6: [Address] = []
    public var router: String?
    public var tailscaleInstalled: Bool
    /// Set when the Application Firewall could be dropping the probe, which would look like a block.
    public var firewallProblem: String?
    public init(addresses: [Address] = [], router: String? = nil,
                tailscaleInstalled: Bool = false, firewallProblem: String? = nil, bridge6: [Address] = []) {
        self.bridge6 = bridge6
        self.addresses = addresses; self.router = router
        self.tailscaleInstalled = tailscaleInstalled; self.firewallProblem = firewallProblem
    }
    /// IPv4 addresses for the block list. The vmnet bridge exists only while a VM runs, and it is the
    /// gateway the `out @host` rule already covers, so it stays out: the rules (and their stamp) are the
    /// same whether or not a guest is up.
    public var ipv4: [String] { addresses.filter { !($0.iface.hasPrefix("bridge") || $0.iface.hasPrefix("vmenet") || $0.iface.hasPrefix("vmnet")) }.map(\.ip) }
}

/// A throwaway TCP listener on every host interface: a port certainly open on this Mac. If the guest
/// reaches it, the connection is queued and counted.
public protocol ProbeListener: AnyObject {
    var port: UInt16 { get }
    func accepted() -> Int
    func close()
}

public protocol HostFactsReading: AnyObject {
    func read() -> HostFacts
    func listener() -> ProbeListener?
    func listener6() -> ProbeListener?
    /// Just the IPv4 addresses that go into the block list (no subprocesses): cheap enough to read every few seconds.
    func currentAddresses() -> [String]
}

/// What one guest probe saw.
public enum ProbeOutcome: Equatable, Sendable {
    case blocked(String), reachable(String), inconclusive(String)
}

/// The fail-closed isolation check that runs inside the guest after `up` (ported from BaneyFleet's
/// `vm_selfcheck`): the internet must work, and the LAN router, the tailnet and every address of this Mac
/// must not answer. Only a positively observed timeout or "unreachable" counts as blocked; an error, an
/// empty answer or anything unrecognized is a failure, and so is a missing positive control.
public enum SandboxSelfcheck {
    public struct Probe: Equatable, Sendable {
        public var label: String
        public var ip: String
        public var port: UInt16
    }

    /// Fixed outside targets: the control that proves `nc` and the internet work, and a tailnet address
    /// only a tailnet node could reach (Tailscale's own resolver).
    public static let controlHost = "1.1.1.1", controlPort: UInt16 = 443
    public static let webCheck = "https://www.cloudflare.com/cdn-cgi/trace"
    public static let tailnetProbe = Probe(label: "the tailnet (100.100.100.100)", ip: "100.100.100.100", port: 80)

    public static func probes(facts: HostFacts, gateway: String?, listenerPort: UInt16) -> [Probe] {
        var out = facts.addresses.map { Probe(label: $0.label, ip: $0.ip, port: listenerPort) }
        if let gateway, !out.contains(where: { $0.ip == gateway }) {
            out.append(Probe(label: "the vmnet gateway \(gateway) (this Mac)", ip: gateway, port: listenerPort))
        }
        if let r = facts.router { out.append(Probe(label: "the LAN router", ip: r, port: 80)) }
        out.append(tailnetProbe)
        return out
    }

    /// One script for the whole check: every probe runs at once, so the guest answers in about one
    /// timeout, not one per address. Prints `GATEWAY <ip>`, `WEB <rc>`, `CONTROL <rc> <text>` and
    /// `PROBE <n> RC=<rc> <text>` lines. `gatewayProbePort` is probed on the guest's own gateway.
    public static func guestScript(probes: [Probe], gatewayPort: UInt16, wait: Int = 4) -> String {
        var s = """
        export PATH=/usr/bin:/bin:/usr/sbin:/sbin
        d=$(mktemp -d /tmp/bsx-check.XXXXXX)
        # After a resume the guest's network takes several seconds to come back. A probe sent before it
        # is up would "time out" for the wrong reason, so the internet check goes first and waits.
        web=1
        for i in 1 2 3 4 5 6 7 8 9 10; do
          curl -fsS -m 5 -o /dev/null \(webCheck) >/dev/null 2>&1 && { web=0; break; }
          sleep 2
        done
        echo "WEB $web" > "$d/web"
        gw=$(route -n get default 2>/dev/null | awk '/gateway:/ {print $2; exit}')
        echo "GATEWAY $gw"
        probe() { # name ip port
          six=""; case "$2" in *:*) six="-6";; esac
          out=$(/usr/bin/nc $six -vz -G \(wait) -w \(wait + 1) "$2" "$3" 2>&1); rc=$?
          printf 'RC=%s %s\\n' "$rc" "$(printf %s "$out" | tr '\\n' ' ')" > "$d/$1"
        }
        probe control \(controlHost) \(controlPort) &
        if [ -n "$gw" ]; then probe gateway "$gw" \(gatewayPort) & fi

        """
        for (i, p) in probes.enumerated() {
            s += "probe p\(i) '\(p.ip.replacingOccurrences(of: "'", with: ""))' \(p.port) &\n"
        }
        s += """
        wait
        # IPv6 is switched off in the guest (Softnet's rules are IPv4): an address on a network interface, or a default route out of one, is a failure.
        # (lo0 and the system's utun tunnels keep link-local addresses that lead nowhere off the machine.)
        v6a=$(ifconfig 2>/dev/null | awk '/^[a-z0-9]+:/ {i=$1} /inet6 / && i ~ /^(en|bridge|vmenet)/ {n++} END {print n+0}')
        v6r=$(netstat -rn -f inet6 2>/dev/null | awk '$1 == "default" && $NF ~ /^(en|bridge)/ {n++} END {print n+0}')
        echo "V6 $((v6a + v6r))"
        cat "$d/web" 2>/dev/null || echo "WEB 99"
        echo "CONTROL $(cat "$d/control" 2>/dev/null)"
        if [ -n "$gw" ]; then echo "GWPROBE $(cat "$d/gateway" 2>/dev/null)"; fi

        """
        for i in probes.indices { s += "echo \"PROBE \(i) $(cat \"$d/p\(i)\" 2>/dev/null)\"\n" }
        s += "rm -rf \"$d\"\n"
        return s
    }

    /// Classifies the text after `RC=<n>`: blocked only on a positively observed timeout or unreachable.
    public static func classify(_ line: String) -> ProbeOutcome {
        guard let m = line.range(of: #"RC=(\d+)"#, options: .regularExpression) else { return .inconclusive("no result from nc") }
        let rc = Int(line[m].dropFirst(3)) ?? -1
        let tail = GuestHands.sanitize(String(line.suffix(120)))
        if rc == 0 || line.range(of: "succeeded|refused|reset by peer", options: [.regularExpression, .caseInsensitive]) != nil {
            return .reachable(tail)
        }
        if line.range(of: "timed out|timeout|no route to host|network is unreachable",
                      options: [.regularExpression, .caseInsensitive]) != nil {
            return .blocked(tail)
        }
        return .inconclusive("unrecognized nc output: \(tail)")
    }

    public struct Report: Equatable, Sendable {
        public var problems: [String]
        public var gateway: String?
        public var passed: Bool { problems.isEmpty }
        /// True when the guest could reach something it must not, or the check could not prove it can't (not a
        /// plain "no internet"). Such a result from ANY guest puts the isolation of the working guest in doubt too.
        public var breach: Bool {
            problems.contains { $0.contains("can reach") || $0.contains("not proven") || $0.contains("listener saw") || $0.contains("IPv6 addresses") }
        }
    }

    /// Reads the guest script's output against the probes that were sent. Pure: tested with canned text.
    public static func evaluate(facts: HostFacts, probes: [Probe], output: String, hostHits: Int, exitStatus: Int32) -> Report {
        var problems: [String] = []
        if let f = facts.firewallProblem { problems.append(f) }
        if facts.addresses.isEmpty { problems.append("no address of this Mac was found to test isolation against") }
        if facts.tailscaleInstalled && !facts.addresses.contains(where: { Remote.isTailnet($0.ip) }) {
            problems.append("Tailscale is installed but this Mac's tailnet address was not found: start it and rerun")
        }
        guard exitStatus == 0 else {
            problems.append("the check could not run in the guest (tart exec failed \(exitStatus))")
            return Report(problems: problems, gateway: nil)
        }
        var gateway: String?
        var web: Int?, control: String?, gwprobe: String?, v6: Int?
        var results: [Int: String] = [:]
        for raw in output.split(separator: "\n") {
            let line = String(raw)
            if line.hasPrefix("GATEWAY ") { let g = line.dropFirst(8).trimmingCharacters(in: .whitespaces); gateway = g.isEmpty ? nil : g }
            else if line.hasPrefix("V6 ") { v6 = Int(line.dropFirst(3).trimmingCharacters(in: .whitespaces)) }
            else if line.hasPrefix("WEB ") { web = Int(line.dropFirst(4).trimmingCharacters(in: .whitespaces)) }
            else if line.hasPrefix("CONTROL ") { control = String(line.dropFirst(8)) }
            else if line.hasPrefix("GWPROBE ") { gwprobe = String(line.dropFirst(8)) }
            else if line.hasPrefix("PROBE ") {
                let rest = line.dropFirst(6)
                if let sp = rest.firstIndex(of: " "), let n = Int(rest[rest.startIndex..<sp]) { results[n] = String(rest[sp...]) }
                else if let n = Int(rest) { results[n] = "" }
            }
        }
        if v6 != 0 {
            problems.append("the guest has IPv6 addresses (\(v6.map(String.init) ?? "unread")): IPv6 is switched off in the sandbox because Softnet's rules are IPv4")
        }
        if web != 0 { problems.append("the guest has no internet (\(webCheck)): its DNS or egress is broken") }
        if case .reachable = classify(control ?? "") {} else {
            problems.append("positive control failed: nc could not connect to \(controlHost):\(controlPort) (\(control.map { GuestHands.sanitize(String($0.suffix(80))) } ?? "no answer")); a silent probe would prove nothing")
        }
        guard let gateway else {
            problems.append("could not read the guest's gateway to probe it")
            return Report(problems: problems, gateway: nil)
        }
        // The guest's own gateway is this Mac: every port but DNS must be shut.
        switch classify(gwprobe ?? "") {
        case .blocked: break
        case .reachable(let d): problems.append("the guest can reach the vmnet gateway \(gateway) (this Mac): \(d)")
        case .inconclusive(let d): problems.append("isolation from the vmnet gateway \(gateway) was not proven: \(d)")
        }
        for (i, p) in probes.enumerated() {
            switch classify(results[i] ?? "") {
            case .blocked: break
            case .reachable(let d): problems.append("the guest can reach \(p.label) \(p.ip):\(p.port) (\(d))")
            case .inconclusive(let d): problems.append("isolation from \(p.label) \(p.ip):\(p.port) was not proven: \(d)")
            }
        }
        if hostHits > 0 { problems.append("the host listener saw \(hostHits) connection(s) from the guest") }
        return Report(problems: problems, gateway: gateway)
    }

    /// What a guest that is root can do over IPv6 once it switches IPv6 back on, gives itself an address in the
    /// Mac's bridge prefix and tries the Mac's bridge addresses (link-local with its scope, and unique-local): the
    /// answer must be nothing. This is the enforcement test for the host side: Softnet drops every frame that is not
    /// IPv4 (measured with tcpdump on the bridge: guest frames were all IPv4 while the guest sent IPv6), so the guest's
    /// own setting is not what keeps it out. Returns the problems; the guest ends with IPv6 off again.
    public static func rootIPv6Attempt(vm: String, tart: SandboxTart, hostFacts: HostFactsReading) -> [String] {
        let facts = hostFacts.read()
        guard let listener = hostFacts.listener6() else { return ["could not open an IPv6 listener on this Mac to test against"] }
        defer { listener.close() }
        let targets = facts.bridge6
        guard !targets.isEmpty else { return ["this Mac's vmnet bridge has no IPv6 address to test against (is the guest running?)"] }
        let ula = targets.first { !$0.ip.hasPrefix("fe80:") }?.ip
        let prefix = ula.map { $0.split(separator: ":").prefix(4).joined(separator: ":") }
        var s = "export PATH=/usr/bin:/bin:/usr/sbin:/sbin\nsudo -n networksetup -setv6automatic Ethernet >/dev/null 2>&1; sleep 5\n"
        if let prefix { s += "sudo -n ifconfig en0 inet6 \(prefix)::99 prefixlen 64 >/dev/null 2>&1; sleep 4\n" }
        s += "echo \"HAS6 $(ifconfig en0 | grep -c 'inet6 ')\"\n"
        for (i, t) in targets.enumerated() {
            let addr = t.ip.hasPrefix("fe80:") ? t.ip + "%en0" : t.ip
            s += "(out=$(/usr/bin/nc -6 -vz -G 4 -w 5 '\(addr)' \(listener.port) 2>&1); printf 'RC=%s %s' \"$?\" \"$(printf %s \"$out\" | tr '\\n' ' ')\" > /tmp/bsx-v6-\(i)) &\n"
        }
        s += "wait\n"
        for i in targets.indices { s += "echo \"V6PROBE \(i) $(cat /tmp/bsx-v6-\(i) 2>/dev/null)\"; rm -f /tmp/bsx-v6-\(i)\n" }
        if let prefix { s += "sudo -n ifconfig en0 inet6 \(prefix)::99 delete >/dev/null 2>&1\n" }
        s += "sudo -n networksetup -setv6off Ethernet >/dev/null 2>&1\n"
        let r = tart.guest(vm, s, timeout: 90)
        tart.clock.sleep(0.2)
        var problems: [String] = []
        guard r.ok else { return ["the guest-root IPv6 test could not run (tart exec failed \(r.status))"] }
        var has6 = 0
        var results: [Int: String] = [:]
        for line in r.stdout.split(separator: "\n") {
            if line.hasPrefix("HAS6 ") { has6 = Int(line.dropFirst(5).trimmingCharacters(in: .whitespaces)) ?? 0 }
            else if line.hasPrefix("V6PROBE ") {
                let rest = line.dropFirst(8)
                if let sp = rest.firstIndex(of: " "), let n = Int(rest[rest.startIndex..<sp]) { results[n] = String(rest[sp...]) }
            }
        }
        if has6 == 0 { problems.append("the guest did not get IPv6 back, so the test proved nothing") }
        for (i, t) in targets.enumerated() {
            switch classify(results[i] ?? "") {
            case .blocked: break
            case .reachable(let d): problems.append("a root guest with IPv6 on reached \(t.label) \(t.ip) over IPv6 (\(d))")
            case .inconclusive(let d): problems.append("IPv6 isolation from \(t.label) \(t.ip) was not proven: \(d)")
            }
        }
        let hits = listener.accepted()
        if hits > 0 { problems.append("the host's IPv6 listener saw \(hits) connection(s) from the guest") }
        return problems
    }

    /// Switches IPv6 off in the guest (every network service). A rooted guest could switch it back on, so the
    /// check below fails if it finds an address, and the PIN notes what Softnet does and doesn't cover.
    public static func harden(vm: String, tart: SandboxTart) {
        _ = tart.guest(vm, "export PATH=/usr/bin:/bin:/usr/sbin:/sbin; networksetup -listallnetworkservices | tail -n +2 | sed 's/^\\*//' | while IFS= read -r s; do sudo -n /usr/sbin/networksetup -setv6off \"$s\"; done; true", timeout: 60)
    }

    /// Runs the whole check against a booted guest. Any failure to run counts as a failure.
    public static func run(vm: String, tart: SandboxTart, hostFacts: HostFactsReading, refresh: Bool = true) -> Report {
        var facts = hostFacts.read()
        let l4 = hostFacts.listener()
        defer { l4?.close() }
        guard let l4 else {
            return Report(problems: ["could not open a listener on this Mac to probe isolation against"], gateway: nil)
        }
        let port = l4.port
        // First ask the guest for its gateway so the probes include it; the script also probes it itself.
        let gw = tart.guest(vm, "PATH=/usr/bin:/bin:/usr/sbin:/sbin route -n get default | awk '/gateway:/ {print $2; exit}'", timeout: 30)
        let gateway = gw.ok ? gw.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        if refresh { // the vmnet bridge only exists while a VM runs
            let fresh = hostFacts.read()
            for a in fresh.addresses where !facts.addresses.contains(where: { $0.ip == a.ip }) { facts.addresses.append(a) }
        }
        let probes = probes(facts: facts, gateway: gateway.flatMap { SandboxNetwork.isUsableIPv4($0) ? $0 : nil }, listenerPort: port)
        let script = guestScript(probes: probes, gatewayPort: port)
        let r = tart.guest(vm, script, timeout: 120)
        tart.clock.sleep(0.2) // connections the guest made a moment ago may still be arriving
        return evaluate(facts: facts, probes: probes, output: r.stdout, hostHits: l4.accepted(),
                        exitStatus: r.timedOut ? 124 : (r.truncated ? 125 : r.status))
    }
}
