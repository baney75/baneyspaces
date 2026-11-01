import XCTest
@testable import BaneySpacesCore

/// The round 2 review: nothing the guest made is followed, no result is lost, the host decides, quitting is final.
final class SandboxSecurityTests: XCTestCase {
    var rigs: [Rig] = []
    func rig(_ gb: UInt64 = 0) -> Rig { let r = Rig.make(availableGB: gb); rigs.append(r); return r }
    override func tearDown() { for r in rigs { r.manager.shutdown(); try? FileManager.default.removeItem(at: r.dir) }; rigs = [] }

    func names(_ dir: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }
    func slotPath(_ r: Rig, _ vm: String) -> URL { SandboxPaths(root: r.dir).slots.appendingPathComponent(vm) }

    // MARK: guest-made links never reach the host's files

    func testSymlinksHardlinksAndFIFOsAreNeverFollowedOrCopied() throws {
        let r = rig()
        let paths = SandboxPaths(root: r.dir)
        let rest = try SandboxHandoff.folder(for: "t1", paths: paths)
        let slot = try SandboxHandoff.makeSlot(vm: "bsx-w-x", paths: paths)
        try SandboxHandoff.bind(task: "t1", slot: slot, paths: paths)
        // a host file the guest would love to reach
        let secret = r.dir.appendingPathComponent("host-secret.txt")
        try Data("SECRET".utf8).write(to: secret)
        let fm = FileManager.default
        try Data("fine".utf8).write(to: slot.appendingPathComponent("report.txt"))
        try fm.createSymbolicLink(at: slot.appendingPathComponent("out.txt"), withDestinationURL: secret)        // symlink to a host file
        try fm.createDirectory(at: slot.appendingPathComponent("sub"), withIntermediateDirectories: false)
        try Data("nested".utf8).write(to: slot.appendingPathComponent("sub/n.txt"))
        try fm.createSymbolicLink(at: slot.appendingPathComponent("sub/dirlink"), withDestinationURL: URL(fileURLWithPath: NSHomeDirectory())) // nested symlink to a directory
        XCTAssertEqual(link(secret.path, slot.appendingPathComponent("hard.txt").path), 0)                      // hard link to a host file
        XCTAssertEqual(mkfifo(slot.appendingPathComponent("pipe").path, 0o600), 0)                              // FIFO
        let result = SandboxHandoff.release(slot: slot, paths: paths)
        XCTAssertTrue(result.complete, result.failure ?? "")
        XCTAssertEqual(result.copied, 2, "report.txt and sub/n.txt")
        XCTAssertEqual(Set(names(rest)), ["report.txt", "sub", "SANDBOX-SKIPPED.txt"])
        XCTAssertEqual(names(rest.appendingPathComponent("sub")), ["n.txt"], "the nested directory symlink was not followed or copied")
        for e in ["out.txt", "sub/dirlink", "hard.txt", "pipe"] {
            XCTAssertTrue(result.skipped.contains { $0.hasPrefix(e) }, "\(e) is listed as skipped: \(result.skipped)")
        }
        // nothing in the task folder is a link, and the host file is untouched
        for n in names(rest) {
            var st = stat(); XCTAssertEqual(lstat(rest.appendingPathComponent(n).path, &st), 0)
            XCTAssertTrue(st.st_mode & S_IFMT == S_IFREG || st.st_mode & S_IFMT == S_IFDIR, "\(n) is a plain file or folder")
            if st.st_mode & S_IFMT == S_IFREG { XCTAssertEqual(st.st_mode & 0o777, 0o600, "no mode the guest chose") }
        }
        XCTAssertEqual(try String(contentsOf: secret), "SECRET")
        XCTAssertFalse(fm.fileExists(atPath: slot.path), "the slot is gone once everything is safe")
        XCTAssertTrue((try String(contentsOf: rest.appendingPathComponent("SANDBOX-SKIPPED.txt"))).contains("symbolic link"))
    }

    func testAGuestChosenModeIsNeverCopied() throws {
        let r = rig()
        let paths = SandboxPaths(root: r.dir)
        let rest = try SandboxHandoff.folder(for: "t1", paths: paths)
        let slot = try SandboxHandoff.makeSlot(vm: "bsx-w-x", paths: paths)
        try SandboxHandoff.bind(task: "t1", slot: slot, paths: paths)
        try Data("x".utf8).write(to: slot.appendingPathComponent("tool"))
        chmod(slot.appendingPathComponent("tool").path, 0o4777) // setuid and world-writable
        XCTAssertTrue(SandboxHandoff.release(slot: slot, paths: paths).complete)
        var st = stat(); XCTAssertEqual(stat(rest.appendingPathComponent("tool").path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o7777, 0o600)
    }

    func testOverlongCollisionNamesStayValid() throws {
        let r = rig()
        let paths = SandboxPaths(root: r.dir)
        let rest = try SandboxHandoff.folder(for: "t1", paths: paths)
        let long = String(repeating: "a", count: 240) + ".txt" // 244 bytes: a valid name that has no room for a suffix
        try Data("yours".utf8).write(to: rest.appendingPathComponent(long))
        let slot = try SandboxHandoff.makeSlot(vm: "bsx-w-x", paths: paths)
        try SandboxHandoff.bind(task: "t1", slot: slot, paths: paths)   // moves yours into the slot ...
        try Data("guest".utf8).write(to: slot.appendingPathComponent(long + "x"))
        try Data("yours2".utf8).write(to: rest.appendingPathComponent(long)) // ... and something new takes the name meanwhile
        let result = SandboxHandoff.release(slot: slot, paths: paths)
        XCTAssertTrue(result.complete, result.failure ?? "")
        XCTAssertEqual(names(rest).count, 3)
        XCTAssertTrue(names(rest).allSatisfy { $0.utf8.count <= 255 }, "\(names(rest).map { $0.utf8.count })")
    }

    // MARK: results are never lost

    func testAFailedReleaseKeepsTheSlotAndTheRecordAndIsRetried() throws {
        let r = rig()
        let rest = try SandboxHandoff.folder(for: "t1", paths: SandboxPaths(root: r.dir))
        try Data("x".utf8).write(to: rest.appendingPathComponent("a.txt"))
        _ = try r.manager.up(task: "t1")
        let vm = r.manager.snapshot().vm!
        let slot = slotPath(r, vm)
        try Data(count: 3 << 20).write(to: slot.appendingPathComponent("big.bin"))
        r.manager.handoffLimit = { 1 << 20 }          // the release may copy at most 2 MB: this one fails
        let gone = (try? r.manager.down()) != nil
        XCTAssertFalse(gone, "down reports that the files are not safe yet")
        XCTAssertTrue(FileManager.default.fileExists(atPath: slot.appendingPathComponent("big.bin").path), "the slot was not deleted")
        XCTAssertEqual(r.manager.snapshot().pendingRestores[vm], "t1", "status shows it")
        XCTAssertEqual(SandboxHandoff.pending(paths: SandboxPaths(root: r.dir))[vm], "t1")
        r.manager.handoffLimit = { 10 << 30 }         // now it can
        r.manager.tick()
        XCTAssertTrue(r.manager.snapshot().pendingRestores.isEmpty)
        XCTAssertEqual(names(rest), ["a.txt", "big.bin"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: slot.path))
    }

    func testAFailedReleaseTakesBackWhatItCopiedSoARetryAddsNoSecondCopies() throws {
        let r = rig()
        let paths = SandboxPaths(root: r.dir)
        let rest = try SandboxHandoff.folder(for: "t1", paths: paths)
        try Data("yours".utf8).write(to: rest.appendingPathComponent("mine.txt"))
        let slot = try SandboxHandoff.makeSlot(vm: "bsx-w-x", paths: paths)
        try SandboxHandoff.bind(task: "t1", slot: slot, paths: paths)   // mine.txt moves into the slot
        let fm = FileManager.default
        for d in ["a", "b"] {
            try fm.createDirectory(at: slot.appendingPathComponent(d), withIntermediateDirectories: false)
            for i in 0..<5 { try Data(count: 100).write(to: slot.appendingPathComponent("\(d)/f\(i).bin")) }
        }
        try fm.createSymbolicLink(at: slot.appendingPathComponent("link"), withDestinationURL: r.dir)
        // 1,005 bytes against a 550-byte limit: at least five files copy before it fails, in any walk order
        for _ in 0..<3 {
            let failed = SandboxHandoff.release(slot: slot, paths: paths, limitBytes: 550)
            XCTAssertFalse(failed.complete)
            XCTAssertEqual(names(rest), [], "a failed attempt leaves nothing in the task folder")
            XCTAssertEqual(SandboxHandoff.pending(paths: paths)["bsx-w-x"], "t1")
        }
        let done = SandboxHandoff.release(slot: slot, paths: paths)
        XCTAssertTrue(done.complete, done.failure ?? "")
        XCTAssertEqual(done.copied, 11)
        XCTAssertEqual(names(rest), ["SANDBOX-SKIPPED.txt", "a", "b", "mine.txt"], "one copy each, under its own name")
        for d in ["a", "b"] { XCTAssertEqual(names(rest.appendingPathComponent(d)), (0..<5).map { "f\($0).bin" }) }
    }

    func testAGuestThatWontDieKeepsItsFilesAndItsSlot() throws {
        let r = rig()
        let rest = try SandboxHandoff.folder(for: "t1", paths: SandboxPaths(root: r.dir))
        try Data("x".utf8).write(to: rest.appendingPathComponent("a.txt"))
        r.tart.spawnImmortal = true
        _ = try r.manager.up(task: "t1")
        let vm = r.manager.snapshot().vm!
        let slot = slotPath(r, vm)
        r.tart.failDeleteOnce = 1000                  // `tart delete` does nothing: the VM is still there
        XCTAssertThrowsError(try r.manager.down())
        XCTAssertEqual(names(slot), ["a.txt"], "its files were not touched while it may still run")
        XCTAssertEqual(names(rest), [])
        r.tart.failDeleteOnce = 0; r.tart.spawned.forEach { $0.proc.immortal = false; $0.proc.stop() }
        r.manager.tick()
        XCTAssertEqual(names(rest), ["a.txt"])
        XCTAssertFalse(r.tart.vmNames().contains(vm))
    }

    func testResetStopsBeforeTheNextGuestWhenTheOldOnesFilesAreNotSafe() throws {
        let r = rig()
        _ = try r.manager.up(task: "t1")
        XCTAssertTrue(r.manager.waitUntilWarm(limit: 120))
        let vm = r.manager.snapshot().vm!
        try Data(count: 3 << 20).write(to: slotPath(r, vm).appendingPathComponent("big.bin"))
        r.manager.handoffLimit = { 1 << 20 }
        XCTAssertThrowsError(try r.manager.reset()) { XCTAssertEqual(($0 as? SandboxError)?.code, "handoff_pending") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: slotPath(r, vm).appendingPathComponent("big.bin").path), "never deleted")
    }

    func testARegistryThatCannotBeReadMovesNothing() throws {
        let r = rig()
        let paths = SandboxPaths(root: r.dir)
        let rest = try SandboxHandoff.folder(for: "t1", paths: paths)
        try Data("x".utf8).write(to: rest.appendingPathComponent("a.txt"))
        try Data("not json".utf8).write(to: paths.registry)
        let slot = try SandboxHandoff.makeSlot(vm: "bsx-w-x", paths: paths)
        XCTAssertThrowsError(try SandboxHandoff.bind(task: "t1", slot: slot, paths: paths))
        XCTAssertEqual(names(rest), ["a.txt"])
        try Data("y".utf8).write(to: slot.appendingPathComponent("g.txt"))
        XCTAssertFalse(SandboxHandoff.release(slot: slot, paths: paths).complete)
        SandboxHandoff.removeUnboundSlot(slot, paths: paths)
        XCTAssertTrue(FileManager.default.fileExists(atPath: slot.appendingPathComponent("g.txt").path), "an unreadable record deletes nothing")
    }

    // MARK: startup

    func testALeftoverGuestThatWontStopLeavesItsSlotAloneAndReportsBusy() throws {
        let r = rig()
        let paths = SandboxPaths(root: r.dir)
        let rest = try SandboxHandoff.folder(for: "t1", paths: paths)
        try Data("x".utf8).write(to: rest.appendingPathComponent("a.txt"))
        let slot = try SandboxHandoff.makeSlot(vm: "bsx-w-old", paths: paths)
        try SandboxHandoff.bind(task: "t1", slot: slot, paths: paths)
        r.tart.vms["bsx-w-old"] = .init(proc: FakeProc())
        r.tart.failDeleteOnce = 1000
        XCTAssertThrowsError(try r.manager.up(task: "t1")) {
            let e = $0 as? SandboxError
            XCTAssertEqual(e?.code, "busy"); XCTAssertEqual(e?.retry, "after")
        }
        XCTAssertEqual(names(slot), ["a.txt"], "its folder was not touched")
        XCTAssertEqual(names(rest), [])
        // the lock was given back, so a later attempt can still take ownership
        r.tart.failDeleteOnce = 0
        XCTAssertNoThrow(try r.manager.up(task: "t1"))
    }

    func testWithTheSandboxOffTheLaunchCleanupDoesNotKeepTheLock() throws {
        let r = rig()
        try r.manager.startupCleanup(keepOwnership: false)
        let other = SandboxManager(tart: r.st, facts: r.facts, clock: r.clock, paths: SandboxPaths(root: r.dir), settings: { SandboxSettings(enabled: true) },
                                   memory: r.memory, hostMemoryGB: 32)
        XCTAssertNoThrow(try other.startupCleanup(keepOwnership: true), "someone else (the probe) can own it")
        other.shutdown(deadline: 2)
    }

    // MARK: quit

    func testQuittingWhileAGuestIsBootingKillsItAndLeavesNothing() throws {
        let r = rig()
        r.tart.agentNeverAnswers = true
        r.manager.bootLimit = 1e9               // it would wait for ever
        let finished = expectation(description: "up ended")
        var error: Error?
        Thread.detachNewThread { do { _ = try r.manager.up(task: "t1") } catch let e { error = e }; finished.fulfill() }
        let deadline = Date().addingTimeInterval(5)
        while r.tart.spawned.isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertFalse(r.tart.spawned.isEmpty, "the guest is booting")
        let t0 = Date()
        r.manager.shutdown(deadline: 3)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 3)
        wait(for: [finished], timeout: 5)
        XCTAssertNotNil(error)
        XCTAssertTrue(r.tart.spawned.allSatisfy { !$0.proc.isRunning }, "every guest process was killed")
        XCTAssertTrue(r.tart.ours().isEmpty, "\(r.tart.ours())")
    }

    func testNothingStartsAfterShutdownBegan() throws {
        let r = rig()
        r.manager.shutdown(deadline: 1)
        XCTAssertThrowsError(try r.manager.up(task: "t1")) { XCTAssertEqual(($0 as? SandboxError)?.code, "shutting_down") }
        XCTAssertTrue(r.tart.spawned.isEmpty)
    }

    // MARK: the host decides

    func testTheMacsAddressesChangingStopsTheGuest() throws {
        let r = rig()
        let rest = try SandboxHandoff.folder(for: "t1", paths: SandboxPaths(root: r.dir))
        try Data("x".utf8).write(to: rest.appendingPathComponent("a.txt"))
        _ = try r.manager.up(task: "t1")
        r.manager.tick()
        XCTAssertNotNil(r.manager.snapshot().vm, "same addresses: nothing happens")
        r.facts.facts.addresses.append(.init("new Wi-Fi", "203.0.113.7", iface: "en1"))
        r.manager.tick()
        XCTAssertNil(r.manager.snapshot().vm)
        XCTAssertTrue(r.manager.snapshot().lastError?.contains("addresses changed") == true)
        XCTAssertEqual(names(rest), ["a.txt"], "the files are back")
    }

    func testARunningWarmCloneUnderOldRulesIsNotPromotedAfterAnAddressChange() throws {
        let r = rig(64)
        _ = try r.manager.up(task: "t1")
        XCTAssertTrue(r.manager.waitUntilWarm(limit: 120))
        XCTAssertEqual(r.manager.snapshot().warmLocation, .memory)
        r.facts.facts.addresses.append(.init("new Wi-Fi", "203.0.113.7", iface: "en1"))
        let warm = r.tart.ours().first { $0.hasPrefix("bsx-s-") }!
        let t = try r.manager.reset()
        XCTAssertEqual(t.from, .disk, "its Softnet rules were stale, so it was saved and resumed with today's")
        let resume = r.tart.spawned.last { $0.args.last == warm }!.args
        XCTAssertTrue(resume.contains { $0.contains("203.0.113.7/32") })
    }

    func testACloneThatCanReachTheMacStopsTheWorkingGuestToo() throws {
        let r = rig()
        _ = try r.manager.up(task: "t1")
        r.tart.leaks = ["192.168.1.20"]            // isolation breaks while the task runs
        XCTAssertTrue(r.manager.waitUntilWarm(limit: 120) || r.manager.snapshot().warm != .building)
        r.manager.tick()
        XCTAssertNil(r.manager.snapshot().vm)
        XCTAssertEqual(r.manager.snapshot().selfcheck, "failed")
        XCTAssertTrue(r.manager.snapshot().lastError?.contains("isolation") == true)
    }

    func testAGuestThatFillsItsHandoffFolderIsStopped() throws {
        let r = rig()
        let rest = try SandboxHandoff.folder(for: "t1", paths: SandboxPaths(root: r.dir))
        _ = try r.manager.up(task: "t1")
        let slot = slotPath(r, r.manager.snapshot().vm!)
        r.manager.handoffLimit = { 1 << 20 }
        let big = slot.appendingPathComponent("x.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let h = try FileHandle(forWritingTo: big); try h.truncate(atOffset: 3 << 19); try h.close()   // 1.5 MB, sparse: costs no disk
        r.manager.tick()
        XCTAssertNil(r.manager.snapshot().vm)
        XCTAssertTrue(r.manager.snapshot().lastError?.contains("handoff_full") == true)
        XCTAssertTrue(r.tart.ours().filter { !$0.hasPrefix("bsx-s-") }.isEmpty)
        _ = rest
    }

    func testAFolderTooDeepToMeasureCountsAsOverTheQuota() throws {
        let r = rig()
        let slot = try SandboxHandoff.makeSlot(vm: "bsx-w-x", paths: SandboxPaths(root: r.dir))
        try Data(count: 100).write(to: slot.appendingPathComponent("top.bin"))
        XCTAssertEqual(SandboxHandoff.size(of: slot), 100)
        var deep = slot
        for _ in 0...SandboxHandoff.maxDepth { deep.appendPathComponent("d") }
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data(count: 3 << 20).write(to: deep.appendingPathComponent("hidden.bin"))
        XCTAssertNil(SandboxHandoff.size(of: slot), "a walk that couldn't reach everything says so, not a smaller number")
    }

    func testAGuestWhoseHandoffFolderCannotBeMeasuredIsStopped() throws {
        let r = rig()
        _ = try r.manager.up(task: "t1")
        var deep = slotPath(r, r.manager.snapshot().vm!)
        for _ in 0...SandboxHandoff.maxDepth { deep.appendPathComponent("d") }
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data(count: 3 << 20).write(to: deep.appendingPathComponent("hidden.bin"))
        r.manager.handoffLimit = { 1 << 20 }
        r.manager.tick()
        XCTAssertNil(r.manager.snapshot().vm)
        XCTAssertTrue(r.manager.snapshot().lastError?.contains("could not be measured") == true, r.manager.snapshot().lastError ?? "")
        XCTAssertTrue(r.tart.ours().filter { !$0.hasPrefix("bsx-s-") }.isEmpty)
        // A later tick retries the pending release and must not replace the quota reason.
        r.manager.tick()
        XCTAssertTrue(r.manager.snapshot().lastError?.contains("could not be measured") == true, r.manager.snapshot().lastError ?? "")
        XCTAssertTrue(r.manager.snapshot().lastError?.hasPrefix("handoff_full:") == true, r.manager.snapshot().lastError ?? "")
    }
}

final class SandboxIPv6EnforcementTests: XCTestCase {
    func testARootGuestWithIPv6BackOnReachesNothing() throws {
        let r = Rig.make(); defer { r.manager.shutdown(); try? FileManager.default.removeItem(at: r.dir) }
        _ = try r.manager.up(task: "t1")
        let vm = r.manager.snapshot().vm!
        XCTAssertEqual(SandboxSelfcheck.rootIPv6Attempt(vm: vm, tart: r.st, hostFacts: r.facts), [])
        let script = r.tart.calls.last { $0.last?.contains("V6PROBE") == true }?.last ?? ""
        XCTAssertTrue(script.contains("networksetup -setv6automatic"), "the guest turns IPv6 on as root")
        XCTAssertTrue(script.contains("ifconfig en0 inet6"), "gives itself an address in the bridge's prefix")
        XCTAssertTrue(script.contains("fe80::5c9b:a6ff:fe68:4164%en0"), "tries the link-local with its scope")
        XCTAssertTrue(script.contains("fdc5:5ced:8bd3:9a9f:1447:5955:8b2d:5e2d"), "and the unique-local")
        XCTAssertTrue(script.contains("setv6off"), "and switches it off again")
    }

    func testAReachableIPv6TargetFails() throws {
        let r = Rig.make(); defer { r.manager.shutdown(); try? FileManager.default.removeItem(at: r.dir) }
        _ = try r.manager.up(task: "t1")
        r.tart.v6Leak = true
        XCTAssertTrue(SandboxSelfcheck.rootIPv6Attempt(vm: r.manager.snapshot().vm!, tart: r.st, hostFacts: r.facts).contains { $0.contains("reached") })
        r.tart.v6Leak = false
        r.facts.listenerHits = 1
        XCTAssertTrue(SandboxSelfcheck.rootIPv6Attempt(vm: r.manager.snapshot().vm!, tart: r.st, hostFacts: r.facts).contains { $0.contains("listener saw") })
    }

    func testNoBridgeAddressMeansTheTestProvedNothing() throws {
        let r = Rig.make(); defer { r.manager.shutdown(); try? FileManager.default.removeItem(at: r.dir) }
        _ = try r.manager.up(task: "t1")
        r.facts.facts.bridge6 = []
        XCTAssertFalse(SandboxSelfcheck.rootIPv6Attempt(vm: r.manager.snapshot().vm!, tart: r.st, hostFacts: r.facts).isEmpty)
    }
}
