import XCTest
@testable import BaneySpacesCore

final class SandboxHandoffTests: XCTestCase {
    func testTaskNames() {
        for ok in ["a", "task-20261031-120000", "fix_1.2", "A9"] { XCTAssertTrue(SandboxHandoff.valid(ok), ok) }
        for bad in ["", ".x", "-x", "a/b", "a b", "..", "a..b", String(repeating: "x", count: 65), "é"] { XCTAssertFalse(SandboxHandoff.valid(bad), bad) }
    }

    func testFolderIsPrivateAndPerTask() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bsx-h-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = SandboxPaths(root: dir)
        let a = try SandboxHandoff.folder(for: "one", paths: paths), b = try SandboxHandoff.folder(for: "two", paths: paths)
        XCTAssertNotEqual(a, b)
        let mode = try FileManager.default.attributesOfItem(atPath: a.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
        XCTAssertThrowsError(try SandboxHandoff.folder(for: "../escape", paths: paths))
        XCTAssertEqual(SandboxPin.guestHandoffPath, "/Volumes/My Shared Files/handoff")
    }

    func testASymlinkedFolderIsRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bsx-h-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = SandboxPaths(root: dir)
        try FileManager.default.createDirectory(at: paths.handoffRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: paths.handoffRoot.appendingPathComponent("evil"), withDestinationURL: URL(fileURLWithPath: NSHomeDirectory()))
        XCTAssertThrowsError(try SandboxHandoff.folder(for: "evil", paths: paths))
    }
}

final class SandboxGuestHandsTests: XCTestCase {
    func testTheStubAnswersStatusForReal() throws {
        let req = GuestHands.Request(id: "abc", verb: "status")
        let r = SystemProcessRunner().run("/bin/bash", ["-c", GuestHands.stubScript], env: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
                                          stdin: String(data: try JSONEncoder().encode(req), encoding: .utf8)! + "\n", timeout: 20, outputLimit: 1 << 20)
        XCTAssertTrue(r.ok, r.stderr)
        let reply = GuestHands.decode(r.stdout, id: "abc")
        XCTAssertTrue(reply.ok, r.stdout)
        XCTAssertEqual(reply.id, "abc")
        XCTAssertEqual(reply.data?["daemon"], "stub")
        XCTAssertEqual(reply.data?["protocol"], "1")
        for k in GuestHands.statusKeys { XCTAssertNotNil(reply.data?[k], k) }
    }

    func testTheStubRefusesOtherVerbsWithASuggestion() throws {
        let req = GuestHands.Request(id: "q", verb: "click", args: ["ref": "@s1:e8"])
        let r = SystemProcessRunner().run("/bin/bash", ["-c", GuestHands.stubScript], env: ["PATH": "/usr/bin:/bin"],
                                          stdin: String(data: try JSONEncoder().encode(req), encoding: .utf8)! + "\n", timeout: 20, outputLimit: 1 << 20)
        let reply = GuestHands.decode(r.stdout, id: "q")
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, "not_implemented"); XCTAssertEqual(reply.error?.retry, "never")
        XCTAssertTrue(reply.error?.suggestion.contains("#105") == true)
    }

    func ok(_ id: String = "r", data: String = "\"daemon\":\"stub\"") -> String { "{\"v\":1,\"id\":\"\(id)\",\"ok\":true,\"data\":{\(data)}}" }

    func testAMalformedReplyIsRejectedWhole() {
        for (why, text) in [("not json", "hello"), ("two lines", ok() + "\n" + ok()), ("empty", ""),
                            ("wrong id", ok("other")), ("ok with error", "{\"v\":1,\"id\":\"r\",\"ok\":true,\"error\":{\"code\":\"x\",\"retry\":\"never\",\"suggestion\":\"s\"}}"),
                            ("failure without error", "{\"v\":1,\"id\":\"r\",\"ok\":false}"),
                            ("bad field name", ok(data: "\"Bad Name\":\"x\"")),
                            ("control characters", ok(data: "\"daemon\":\"a\\u0007b\"")),
                            ("bad retry", "{\"v\":1,\"id\":\"r\",\"ok\":false,\"error\":{\"code\":\"x\",\"retry\":\"sudo\",\"suggestion\":\"s\"}}"),
                            ("shell in the code", "{\"v\":1,\"id\":\"r\",\"ok\":false,\"error\":{\"code\":\"$(rm -rf ~)\",\"retry\":\"never\",\"suggestion\":\"s\"}}")] {
            let r = GuestHands.decode(text, id: "r")
            XCTAssertFalse(r.ok, why)
            XCTAssertEqual(r.error?.code, "bad_reply", why)
        }
        XCTAssertTrue(GuestHands.decode(ok(), id: "r").ok)
    }

    func testAnOversizedReplyIsRejected() {
        let big = ok(data: "\"daemon\":\"" + String(repeating: "x", count: GuestHands.maxReplyBytes) + "\"")
        XCTAssertEqual(GuestHands.decode(big, id: "r").error?.code, "bad_reply")
        let long = ok(data: "\"daemon\":\"" + String(repeating: "x", count: GuestHands.maxValueBytes + 1) + "\"")
        XCTAssertEqual(GuestHands.decode(long, id: "r").error?.code, "bad_reply")
        let many = ok(data: (0..<(GuestHands.maxDataEntries + 1)).map { "\"k\($0)\":\"v\"" }.joined(separator: ","))
        XCTAssertEqual(GuestHands.decode(many, id: "r").error?.code, "bad_reply")
    }

    func testATruncatedOrMalformedReplyThroughTheTransportIsRejected() throws {
        let rig = Rig.make(); defer { rig.manager.shutdown(); try? FileManager.default.removeItem(at: rig.dir) }
        _ = try rig.manager.up(task: "t")
        rig.tart.guestTruncated = true
        rig.tart.guestReply = String(repeating: "x", count: 1000)
        XCTAssertEqual(rig.manager.guestCall(.init(id: "a", verb: "status")).error?.code, "bad_reply")
        rig.tart.guestTruncated = false
        rig.tart.guestReply = "{\"v\":1,\"id\":\"a\",\"ok\":true,\"data\":{\"daemon\":\"stub\"}}\nextra"
        XCTAssertEqual(rig.manager.guestCall(.init(id: "a", verb: "status")).error?.code, "bad_reply")
    }

    func testBadAnswersAreFailuresNotCrashes() {
        XCTAssertEqual(GuestHands.decode("", id: "x").error?.code, "bad_reply")
        XCTAssertEqual(GuestHands.decode("{\"v\":9,\"id\":\"x\",\"ok\":true}", id: "x").error?.code, "version")
    }

    func testCallGoesThroughTartExecWithTheRequestOnStdin() throws {
        let rig = Rig.make(); defer { rig.manager.shutdown(); try? FileManager.default.removeItem(at: rig.dir) }
        _ = try rig.manager.up(task: "t")
        let g = rig.manager.guestCall(GuestHands.Request(id: "x", verb: "status"))
        XCTAssertTrue(g.ok)
        XCTAssertTrue(rig.tart.stdinSeen.last?.contains("\"verb\":\"status\"") == true)
        let exec = rig.tart.calls.last { $0.first == "exec" && $0.contains("-i") }
        XCTAssertNotNil(exec, "-i: stdin carries the request; no ssh, no password")
        _ = try rig.manager.down()
        XCTAssertEqual(rig.manager.guestCall(.init(verb: "status")).error?.code, "not_up")
    }
}

final class SandboxServiceTests: XCTestCase {
    func service(_ r: Rig) -> SandboxService {
        SandboxService(manager: r.manager, tart: r.st, settings: { SandboxSettings(enabled: true) },
                       tartHome: r.dir.appendingPathComponent("no-tart-home"))
    }

    func json(_ r: Wire.Reply) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data((r.info?["json"] ?? "{}").utf8))) as? [String: Any] ?? [:]
    }

    func testStatusIsJSONWithTheFieldsCallersRelyOn() throws {
        let r = Rig.make(); defer { r.manager.shutdown(); try? FileManager.default.removeItem(at: r.dir) }
        let s = service(r)
        var d = json(s.handle(Wire.Request(op: .sandbox, text: "status")))
        XCTAssertEqual(d["state"] as? String, "stopped")
        XCTAssertEqual((d["image"] as? [String: Any])?["ref"] as? String, SandboxPin.image)
        let up = s.handle(Wire.Request(op: .sandbox, text: "up", args: ["--task", "svc"]))
        XCTAssertTrue(up.ok, up.error ?? "")
        d = json(s.handle(Wire.Request(op: .sandbox, text: "status")))
        XCTAssertEqual(d["state"] as? String, "running"); XCTAssertEqual(d["task"] as? String, "svc")
        XCTAssertEqual((d["network"] as? [String: Any])?["selfcheck"] as? String, "passed")
        let g = d["guest"] as? [String: Any]
        XCTAssertEqual((g?["data"] as? [String: Any])?["daemon"] as? String, "stub")
        XCTAssertEqual(g?["source"] as? String, "guest-asserted", "the guest's word is labeled as such")
        XCTAssertEqual((d["handoff"] as? [String: Any])?["guest_path"] as? String, "/Volumes/My Shared Files/handoff")
        XCTAssertEqual((d["settings"] as? [String: Any])?["memory_gb"] as? Int, 4)
        XCTAssertTrue(s.handle(Wire.Request(op: .sandbox, text: "down")).ok)
    }

    func testErrorsCarryACodeAndWhetherTheVMIsGone() {
        let r = Rig.make(); defer { r.manager.shutdown(); try? FileManager.default.removeItem(at: r.dir) }
        r.tart.leaks = ["192.168.1.20"]
        let reply = service(r).handle(Wire.Request(op: .sandbox, text: "up"))
        XCTAssertFalse(reply.ok)
        let d = json(reply)
        XCTAssertEqual(d["code"] as? String, "selfcheck_failed"); XCTAssertEqual(d["vm_deleted"] as? Bool, true)
        XCTAssertFalse(service(r).handle(Wire.Request(op: .sandbox, text: "bogus")).ok)
    }

    func testProbeSequencePassesAgainstTheFakeAndLeavesNothing() {
        let r = Rig.make(); defer { r.manager.shutdown(); try? FileManager.default.removeItem(at: r.dir) }
        let report = SandboxProbe.run(manager: r.manager, tart: r.st, resets: 3, clock: r.clock, plantLinks: false)
        XCTAssertTrue(report.passed, report.steps.filter { !$0.ok }.map { "\($0.name): \($0.detail)" }.joined(separator: "\n"))
        r.manager.shutdown()
        XCTAssertTrue(r.tart.ours().isEmpty)
    }

    func testWireCarriesTheSandboxOp() throws {
        let req = Wire.Request(op: .sandbox, text: "up", args: ["--task", "x"])
        let back = try JSONDecoder().decode(Wire.Request.self, from: JSONEncoder().encode(req))
        XCTAssertEqual(back, req)
    }
}

final class SandboxRunnerTests: XCTestCase {
    func testAChildThatFloodsItsOutputIsStoppedAndTruncated() {
        let start = Date()
        let r = SystemProcessRunner().run("/usr/bin/yes", [], env: [:], stdin: nil, timeout: 20, outputLimit: 64 << 10)
        XCTAssertTrue(r.truncated); XCTAssertFalse(r.ok)
        XCTAssertLessThanOrEqual(r.stdout.utf8.count, 64 << 10)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "stopped when it hit the cap, not at the timeout")
    }

    func testAnOrdinaryChildIsUntouched() {
        let r = SystemProcessRunner().run("/bin/echo", ["hi"], env: [:], stdin: nil, timeout: 5, outputLimit: 1024)
        XCTAssertTrue(r.ok); XCTAssertEqual(r.stdout, "hi\n")
    }

    func testATimeoutIsReported() {
        let r = SystemProcessRunner().run("/bin/sleep", ["30"], env: [:], stdin: nil, timeout: 0.5, outputLimit: 1024)
        XCTAssertTrue(r.timedOut); XCTAssertFalse(r.ok)
    }
}

final class SandboxInstallScriptTests: XCTestCase {
    var repo: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    func script() throws -> String { try String(contentsOf: repo.appendingPathComponent("scripts/install-sandbox.sh"), encoding: .utf8) }

    func testItParsesAndPinsTheSameVersionsAsTheCode() throws {
        let r = SystemProcessRunner().run("/bin/bash", ["-n", repo.appendingPathComponent("scripts/install-sandbox.sh").path], env: [:], stdin: nil, timeout: 20, outputLimit: 1 << 16)
        XCTAssertTrue(r.ok, r.stderr)
        let s = try script()
        XCTAssertTrue(s.contains("TART_VERSION=\(SandboxPin.tartVersion)"))
        XCTAssertTrue(s.contains("SOFTNET_VERSION=\(SandboxPin.softnetVersion)"))
        XCTAssertTrue(s.contains("IMAGE=\(SandboxPin.image)"))
        let pin = try String(contentsOf: repo.appendingPathComponent("sandbox/PIN"), encoding: .utf8)
        for h in ["5a2e8ef779f0a2169b88d273ee806c0d64321ec7714c0dc99bf217523ae9b008", "5c838134bb91af720d3575a9918e0bebe48a40bf37deaf0a5ec2219ba94b8534",
                  "117016ba2df4cde92468ecf59bf278416ff850058bc03ad388c676336418a264", "e754c5494df67cb62087ebfd4b7358357955aaaf10e559f4df72c6e28f8e33c5"] {
            XCTAssertTrue(s.contains(h), "script pins \(h.prefix(12))")
            XCTAssertTrue(pin.contains(h), "sandbox/PIN records \(h.prefix(12))")
        }
    }

    func testItIsIdempotentAndSafeByConstruction() throws {
        let s = try script()
        XCTAssertTrue(s.contains("already installed and correct"), "skips a correct install")
        XCTAssertTrue(s.contains("--dry-run"))
        XCTAssertTrue(s.contains("install -m 4755 -o root -g wheel"))
        let code = s.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n")
        XCTAssertFalse(code.contains("make install"), "never the app's installer")
        XCTAssertFalse(code.contains("/Applications"), "never the installed app")
        XCTAssertTrue(s.contains("checksum mismatch"), "a download is verified before it is used")
    }

    func testTheFormulaeMatchTheirPinnedHashes() throws {
        for (name, h) in [("tart", "117016ba2df4cde92468ecf59bf278416ff850058bc03ad388c676336418a264"), ("softnet", "e754c5494df67cb62087ebfd4b7358357955aaaf10e559f4df72c6e28f8e33c5")] {
            let r = SystemProcessRunner().run("/usr/bin/shasum", ["-a", "256", repo.appendingPathComponent("sandbox/Formula/\(name).rb").path], env: [:], stdin: nil, timeout: 10, outputLimit: 4096)
            XCTAssertTrue(r.stdout.hasPrefix(h), name)
        }
    }
}
