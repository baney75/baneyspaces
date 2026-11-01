import XCTest
@testable import BaneySpacesCore

final class SandboxRulesTests: XCTestCase {
    func testRulesBlockEveryPrivateRangeTheMacAndTheGatewayButNotItsDNS() {
        let r = SandboxNetwork.rules(hostAddresses: ["192.168.1.20", "100.101.102.103", "203.0.113.9", "127.0.0.1"])
        let block = r.block.split(separator: ",").map(String.init)
        for need in ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16", "out @host"] {
            XCTAssertTrue(block.contains(need), need)
        }
        XCTAssertTrue(block.contains("203.0.113.9/32"), "the Mac's own public address is blocked too")
        XCTAssertFalse(block.contains("127.0.0.1/32"))
        XCTAssertEqual(r.allow, "out proto udp @host port 53,out proto tcp @host port 53", "only the gateway's DNS comes back")
        XCTAssertTrue(SandboxNetwork.problems(in: r).isEmpty)
    }

    func testWeakRulesAreRefused() {
        var r = SandboxNetwork.rules(hostAddresses: [])
        r.block = "10.0.0.0/8"
        XCTAssertTrue(SandboxNetwork.problems(in: r).contains("block list lacks out @host"))
        r = SandboxNetwork.rules(hostAddresses: [])
        r.allow = "out proto udp @host port 53,192.168.0.0/16"
        XCTAssertTrue(SandboxNetwork.problems(in: r).contains { $0.contains("opens 192.168.0.0/16") })
        r.allow = ""
        XCTAssertFalse(SandboxNetwork.problems(in: r).isEmpty)
        XCTAssertThrowsError(try SandboxTart.runArguments(vm: "bsx-x", options: TartRunOptions(rules: r)))
    }

    func testTheVmnetBridgeDoesNotChangeTheRules() {
        let without = HostFacts(addresses: [.init("en0", "192.168.1.20", iface: "en0")])
        let with = HostFacts(addresses: [.init("en0", "192.168.1.20", iface: "en0"), .init("bridge100", "192.168.64.1", iface: "bridge100")])
        XCTAssertEqual(SandboxNetwork.rules(hostAddresses: without.ipv4).hash, SandboxNetwork.rules(hostAddresses: with.ipv4).hash,
                       "a reset must find the same stamp as the up that came before it")
    }

    func testRulesHashChangesWithAddresses() {
        XCTAssertNotEqual(SandboxNetwork.rules(hostAddresses: ["192.168.1.2"]).hash, SandboxNetwork.rules(hostAddresses: ["192.168.1.3"]).hash)
        XCTAssertEqual(SandboxNetwork.rules(hostAddresses: ["1.2.3.4", "5.6.7.8"]).hash, SandboxNetwork.rules(hostAddresses: ["5.6.7.8", "1.2.3.4"]).hash)
    }

    func testRunArgumentsAreHeadlessSuspendableSoftnetAndShareOnlyTheHandoff() throws {
        let rules = SandboxNetwork.rules(hostAddresses: ["192.168.1.20"])
        let a = try SandboxTart.runArguments(vm: "bsx-w-1", options: TartRunOptions(rules: rules, handoff: "/h/task1"))
        XCTAssertEqual(a.first, "run"); XCTAssertEqual(a.last, "bsx-w-1")
        XCTAssertTrue(a.contains("--no-graphics")); XCTAssertTrue(a.contains("--suspendable"))
        XCTAssertTrue(a.contains("--net-softnet")); XCTAssertTrue(a.contains("--no-clipboard"))
        XCTAssertTrue(a.contains("--net-softnet-block=\(rules.block)")); XCTAssertTrue(a.contains("--net-softnet-allow=\(rules.allow)"))
        XCTAssertEqual(a.filter { $0.hasPrefix("--dir") }, ["--dir=handoff:/h/task1"], "exactly one share")
        XCTAssertFalse(a.contains("--net-bridged=en0"))
        let shown = try SandboxTart.runArguments(vm: "v", options: TartRunOptions(graphics: true, rules: rules))
        XCTAssertFalse(shown.contains("--no-graphics")); XCTAssertTrue(shown.filter { $0.hasPrefix("--dir") }.isEmpty)
    }

    func testOnlyAPinnedDigestIsAccepted() {
        XCTAssertTrue(SandboxPin.isPinnedByDigest(SandboxPin.image))
        XCTAssertFalse(SandboxPin.isPinnedByDigest("ghcr.io/cirruslabs/macos-tahoe-base:latest"))
        let rig = Rig.make()
        XCTAssertThrowsError(try rig.st.cloneAndSize(image: "ghcr.io/cirruslabs/macos-tahoe-base:latest", vm: "bsx-a", memoryGB: 4, cpus: 4))
        XCTAssertTrue(rig.tart.calls.isEmpty, "an unpinned image never reaches tart")
    }

    func testSettingsAreClamped() {
        XCTAssertEqual(SandboxSettings(enabled: true, memoryGB: 5, cpus: 99).memoryGB, 4)
        XCTAssertEqual(SandboxSettings(enabled: true, memoryGB: 16, cpus: 8).clamped(hostMemoryGB: 32, hostCPUs: 10).memoryGB, 8)
        XCTAssertEqual(SandboxSettings(enabled: true, memoryGB: 16, cpus: 8).clamped(hostMemoryGB: 32, hostCPUs: 10).cpus, 4)
        XCTAssertFalse(SandboxSettings().enabled, "off until you turn it on")
    }

    func testTheSandboxIsNeverAllowedFromAnotherMachine() {
        XCTAssertFalse(Remote.allows(Wire.Request(op: .sandbox, text: "status")))
        XCTAssertFalse(Remote.allows(Wire.Request(op: .sandbox, text: "up")))
    }
}

final class SandboxSelfcheckTests: XCTestCase {
    let facts = HostFacts(addresses: [.init("this Mac's address on en0", "192.168.1.20"), .init("this Mac's tailnet address", "100.101.102.103")],
                          router: "192.168.1.1", tailscaleInstalled: true)

    func probes() -> [SandboxSelfcheck.Probe] {
        SandboxSelfcheck.probes(facts: facts, gateway: "192.168.64.1", listenerPort: 5000, listener6Port: nil)
    }

    func output(web: Int = 0, control: String = "RC=0 succeeded!", gw: String = "RC=1 Operation timed out", each: String = "RC=1 Operation timed out") -> String {
        var s = "GATEWAY 192.168.64.1\nWEB \(web)\nCONTROL \(control)\nGWPROBE \(gw)\n"
        for i in probes().indices { s += "PROBE \(i) \(each)\n" }
        return s
    }

    func eval(_ out: String, hits: Int = 0, facts f: HostFacts? = nil, status: Int32 = 0) -> SandboxSelfcheck.Report {
        SandboxSelfcheck.evaluate(facts: f ?? facts, probes: probes(), output: out, hostHits: hits, host6Hits: 0, exitStatus: status)
    }

    func testProbesCoverTheMacTheGatewayTheRouterAndTheTailnet() {
        let ips = probes().map(\.ip)
        XCTAssertEqual(ips, ["192.168.1.20", "100.101.102.103", "192.168.64.1", "192.168.1.1", "100.100.100.100"])
    }

    func testPassesWhenTheInternetWorksAndEverythingElseTimesOut() {
        XCTAssertEqual(eval(output()).problems, [])
        XCTAssertTrue(eval(output()).passed)
    }

    func testAReachableAddressFails() {
        let out = output().replacingOccurrences(of: "PROBE 1 RC=1 Operation timed out", with: "PROBE 1 RC=0 succeeded!")
        let r = eval(out)
        XCTAssertFalse(r.passed)
        XCTAssertTrue(r.problems.contains { $0.contains("can reach") && $0.contains("100.101.102.103") })
    }

    func testTheGatewayMustBeShut() {
        XCTAssertTrue(eval(output(gw: "RC=0 succeeded!")).problems.contains { $0.contains("vmnet gateway") })
    }

    func testNoInternetFailsClosed() {
        XCTAssertTrue(eval(output(web: 6)).problems.contains { $0.contains("no internet") })
    }

    func testAMissingPositiveControlFailsEvenIfEverythingTimedOut() {
        XCTAssertTrue(eval(output(control: "RC=1 Operation timed out")).problems.contains { $0.contains("positive control") })
    }

    func testAnAnswerThatIsNotATimeoutIsNotProof() {
        let r = eval(output(each: "RC=1 nc: bad address"))
        XCTAssertFalse(r.passed)
        XCTAssertTrue(r.problems.contains { $0.contains("not proven") })
    }

    func testAScriptThatCouldNotRunFails() {
        XCTAssertFalse(eval("", status: 1).passed)
        XCTAssertFalse(eval("", status: 124).passed)
        XCTAssertFalse(eval("").passed, "empty output proves nothing")
    }

    func testHostListenerHitsFail() {
        XCTAssertTrue(eval(output(), hits: 1).problems.contains { $0.contains("listener saw 1") })
    }

    func testFirewallAndTailscaleProblemsFail() {
        var f = facts
        f.firewallProblem = "the Application Firewall is on"
        XCTAssertTrue(eval(output(), facts: f).problems.contains("the Application Firewall is on"))
        f = HostFacts(addresses: [.init("en0", "192.168.1.20")], tailscaleInstalled: true)
        XCTAssertTrue(eval(output(), facts: f).problems.contains { $0.contains("tailnet address was not found") })
        XCTAssertTrue(eval(output(), facts: HostFacts()).problems.contains { $0.contains("no address of this Mac") })
    }

    func testTheGuestScriptRunsEveryProbeAtOnce() {
        let script = SandboxSelfcheck.guestScript(probes: probes(), gatewayPort: 5000)
        XCTAssertEqual(script.components(separatedBy: "\nprobe p").count - 1, 5)
        XCTAssertTrue(script.contains("wait\n"))
        XCTAssertTrue(script.contains("-G 4"))
    }

    func testClassify() {
        XCTAssertEqual(SandboxSelfcheck.classify("RC=0 x"), .reachable("RC=0 x"))
        if case .reachable = SandboxSelfcheck.classify("RC=1 Connection refused") {} else { XCTFail("refused means the host answered") }
        if case .blocked = SandboxSelfcheck.classify("RC=1 No route to host") {} else { XCTFail() }
        if case .inconclusive = SandboxSelfcheck.classify("") {} else { XCTFail() }
    }
}

final class SandboxSocketPolicyTests: XCTestCase {
    func testDeletingImagesIsNotSomethingTheSocketDoes() {
        XCTAssertNotNil(SocketPolicy.refusal(for: Wire.Request(op: .sandbox, text: "images", args: ["delete"])))
        for ok in ["up", "down", "reset", "status", "view", "guest"] {
            XCTAssertNil(SocketPolicy.refusal(for: Wire.Request(op: .sandbox, text: ok)), ok)
        }
    }
}
