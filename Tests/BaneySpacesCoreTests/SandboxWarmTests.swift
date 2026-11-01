import XCTest
@testable import BaneySpacesCore

final class SandboxWarmPolicyTests: XCTestCase {
    func testMemoryOnlyWhileInUseAndWithRoom() {
        let gb: UInt64 = 1 << 30
        // active and room for the VM plus 4 GB: memory
        XCTAssertEqual(SandboxWarmPolicy.location(lastActivity: 100, now: 150, available: 8 * gb, vmMemoryGB: 4), .memory)
        // exactly VM + 4 GB is enough, a byte less is not
        XCTAssertEqual(SandboxWarmPolicy.location(lastActivity: 100, now: 150, available: 8 * gb, vmMemoryGB: 4), .memory)
        XCTAssertEqual(SandboxWarmPolicy.location(lastActivity: 100, now: 150, available: 8 * gb - 1, vmMemoryGB: 4), .disk)
        XCTAssertEqual(SandboxWarmPolicy.location(lastActivity: 100, now: 150, available: 11 * gb, vmMemoryGB: 8), .disk)
        // idle 15 minutes: disk
        XCTAssertEqual(SandboxWarmPolicy.location(lastActivity: 100, now: 100 + 899, available: 64 * gb, vmMemoryGB: 4), .memory)
        XCTAssertEqual(SandboxWarmPolicy.location(lastActivity: 100, now: 100 + 900, available: 64 * gb, vmMemoryGB: 4), .disk)
        // a VM that is already running has its memory out of `available`: only the 4 GB headroom is checked
        XCTAssertEqual(SandboxWarmPolicy.location(lastActivity: 100, now: 150, available: 4 * gb, vmMemoryGB: 4, resident: true), .memory)
        XCTAssertEqual(SandboxWarmPolicy.location(lastActivity: 100, now: 150, available: 4 * gb - 1, vmMemoryGB: 4, resident: true), .disk)
        // never used: disk
        XCTAssertEqual(SandboxWarmPolicy.location(lastActivity: nil, now: 5, available: 64 * gb, vmMemoryGB: 4), .disk)
    }

    func testPercentiles() {
        let s = SandboxResetStats(samples: [6.2, 6.1, 11.3])
        XCTAssertEqual(s.count, 3); XCTAssertEqual(s.p50, 6.2); XCTAssertEqual(s.p90, 11.3)
        XCTAssertFalse(s.p90WithinBudget)
        let ten = SandboxResetStats(samples: [1, 2, 3, 4, 5, 6, 7, 8, 9, 30])
        XCTAssertEqual(ten.p50, 5); XCTAssertEqual(ten.p90, 9, "nearest rank: the 9th of 10")
        XCTAssertTrue(ten.p90WithinBudget)
        XCTAssertFalse(SandboxResetStats(samples: []).p90WithinBudget)
    }
}

final class SandboxWarmStateTests: XCTestCase {
    var rigs: [Rig] = []
    func rig(_ gb: UInt64) -> Rig { let r = Rig.make(availableGB: gb); rigs.append(r); return r }
    override func tearDown() { for r in rigs { r.manager.shutdown(); try? FileManager.default.removeItem(at: r.dir) }; rigs = [] }

    func warmName(_ r: Rig) -> String? { r.tart.ours().first { $0.hasPrefix("bsx-s-") } }
    func suspends(_ r: Rig) -> [String] { r.tart.calls.filter { $0.first == "suspend" }.map { $0[1] } }

    func testActiveWithRoomKeepsTheWarmCloneRunningInMemoryOnTheTasksFolder() throws {
        let r = rig(64)
        _ = try r.manager.up(task: "t1")
        XCTAssertTrue(r.manager.waitUntilWarm(limit: 120))
        let s = r.manager.snapshot()
        XCTAssertEqual(s.warmLocation, .memory)
        let w = warmName(r)!
        XCTAssertFalse(suspends(r).contains(w), "not written to disk")
        let spawn = r.tart.spawned.first { $0.args.last == w }!
        XCTAssertTrue(spawn.proc.isRunning)
        XCTAssertTrue(spawn.args.contains { $0.hasSuffix("/handoff/t1") }, "it already has the task's folder, which a running VM can't change later")
    }

    func testResetPromotesTheRunningCloneWithNothingToRestore() throws {
        let r = rig(64)
        _ = try r.manager.up(task: "t1")
        XCTAssertTrue(r.manager.waitUntilWarm(limit: 120))
        let w = warmName(r)!
        let old = r.manager.snapshot().vm!
        let t = try r.manager.reset()
        XCTAssertEqual(t.from, .memory)
        XCTAssertEqual(r.manager.snapshot().vm, w, "the warm clone is now the working VM")
        XCTAssertEqual(r.tart.spawned.filter { $0.args.last == w }.count, 1, "no second `tart run`: nothing was restored")
        XCTAssertFalse(r.tart.vmNames().contains(old))
        XCTAssertTrue(t.withinBudget)
        XCTAssertTrue(r.manager.waitUntilWarm(limit: 120))
        XCTAssertEqual(r.manager.snapshot().warmLocation, .memory, "and the next one is built the same way")
    }

    func testIdleFifteenMinutesSavesTheWarmCloneToDiskAndTheNextResetRestoresIt() throws {
        let r = rig(64)
        _ = try r.manager.up(task: "t1")
        XCTAssertTrue(r.manager.waitUntilWarm(limit: 120))
        let w = warmName(r)!
        r.clock.advance(SandboxWarmPolicy.idleLimit - 5)
        r.manager.tick()
        XCTAssertEqual(r.manager.snapshot().warmLocation, .memory, "still in use 14 minutes in")
        r.clock.advance(10)
        _ = r.manager.snapshot() // a look is not use
        r.manager.tick()
        XCTAssertEqual(r.manager.snapshot().warmLocation, .disk)
        XCTAssertEqual(suspends(r).filter { $0 == w }.count, 1)
        XCTAssertFalse(r.tart.spawned.first { $0.args.last == w }!.proc.isRunning, "RAM freed")
        let t = try r.manager.reset()
        XCTAssertEqual(t.from, .disk, "the disk path is the fallback")
        XCTAssertEqual(r.tart.spawned.filter { $0.args.last == w }.count, 2, "restored with a second `tart run`")
        XCTAssertEqual(r.manager.snapshot().vm, w)
    }

    func testStatusAloneDoesNotKeepItInMemory() throws {
        let r = rig(64)
        let svc = SandboxService(manager: r.manager, tart: r.st, settings: { SandboxSettings(enabled: true) }, tartHome: r.dir)
        _ = try r.manager.up(task: "t1")
        XCTAssertTrue(r.manager.waitUntilWarm(limit: 120))
        r.clock.advance(SandboxWarmPolicy.idleLimit + 1)
        _ = svc.handle(Wire.Request(op: .sandbox, text: "status"))
        r.manager.tick()
        XCTAssertEqual(r.manager.snapshot().warmLocation, .disk)
    }

    func testTightMemoryAtBuildTimePutsItOnDisk() throws {
        let r = rig(7) // VM 4 GB + 4 GB needed
        _ = try r.manager.up(task: "t1")
        XCTAssertTrue(r.manager.waitUntilWarm(limit: 120))
        XCTAssertEqual(r.manager.snapshot().warmLocation, .disk)
        XCTAssertEqual(suspends(r), [warmName(r)!])
        let t = try r.manager.reset()
        XCTAssertEqual(t.from, .disk)
    }

    func testMemoryGettingTightLaterMovesItToDisk() throws {
        let r = rig(64)
        _ = try r.manager.up(task: "t1")
        XCTAssertTrue(r.manager.waitUntilWarm(limit: 120))
        r.memory.bytes = 3 << 30
        r.manager.tick()
        XCTAssertEqual(r.manager.snapshot().warmLocation, .disk)
        XCTAssertEqual(suspends(r).count, 1)
    }

    func testDownGivesTheMemoryBack() throws {
        let r = rig(64)
        _ = try r.manager.up(task: "t1")
        XCTAssertTrue(r.manager.waitUntilWarm(limit: 120))
        _ = try r.manager.down()
        XCTAssertEqual(r.manager.snapshot().warmLocation, .disk)
        XCTAssertEqual(suspends(r).count, 1)
        XCTAssertTrue(r.tart.spawned.allSatisfy { $0.proc.isRunning == false })
    }

    func testAWarmCloneThatDiedInMemoryIsDroppedNotPromoted() throws {
        let r = rig(64)
        _ = try r.manager.up(task: "t1")
        XCTAssertTrue(r.manager.waitUntilWarm(limit: 120))
        let w = warmName(r)!
        r.tart.spawned.first { $0.args.last == w }!.proc.stop()
        r.manager.tick()
        XCTAssertFalse(r.tart.vmNames().contains(w))
        XCTAssertEqual(r.manager.snapshot().warm, .none)
    }

    func testResetStatsAppearInStatus() throws {
        let r = rig(64)
        let svc = SandboxService(manager: r.manager, tart: r.st, settings: { SandboxSettings(enabled: true) }, tartHome: r.dir)
        _ = try r.manager.up(task: "t1")
        for _ in 0..<2 { XCTAssertTrue(r.manager.waitUntilWarm(limit: 120)); _ = try r.manager.reset() }
        XCTAssertTrue(r.manager.waitUntilWarm(limit: 120))
        let d = (try JSONSerialization.jsonObject(with: Data((svc.handle(Wire.Request(op: .sandbox, text: "status")).info?["json"] ?? "{}").utf8))) as? [String: Any]
        let st = d?["reset_stats"] as? [String: Any]
        XCTAssertEqual(st?["count"] as? Int, 2)
        XCTAssertNotNil(st?["p50_ms"]); XCTAssertNotNil(st?["p90_ms"]); XCTAssertEqual(st?["budget_ms"] as? Int, 10000)
        XCTAssertEqual((d?["warm"] as? [String: Any])?["location"] as? String, "memory")
    }
}
