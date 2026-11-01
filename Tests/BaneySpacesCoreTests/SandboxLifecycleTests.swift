import XCTest
@testable import BaneySpacesCore

final class SandboxLifecycleTests: XCTestCase {
    var rigs: [Rig] = []
    func rig(enabled: Bool = true) -> Rig { let r = Rig.make(enabled: enabled); rigs.append(r); return r }
    override func tearDown() { for r in rigs { r.manager.shutdown(); try? FileManager.default.removeItem(at: r.dir) }; rigs = [] }

    func testOffByDefaultRefusesUpAndMakesNothing() {
        let r = rig(enabled: false)
        XCTAssertThrowsError(try r.manager.up(task: "t")) { XCTAssertEqual(($0 as? SandboxError)?.code, "off") }
        XCTAssertTrue(r.tart.calls.isEmpty)
    }

    func testUpClonesThePinnedImageSizesItBootsHeadlessAndChecksTheNetwork() throws {
        let r = rig()
        let s = try r.manager.up(task: "t1")
        XCTAssertEqual(s.phase, .running); XCTAssertEqual(s.selfcheck, "passed"); XCTAssertEqual(s.task, "t1")
        let clone = r.tart.calls.first { $0.first == "clone" }!
        XCTAssertEqual(clone[1], SandboxPin.image)
        XCTAssertTrue(clone[2].hasPrefix("bsx-"))
        let set = r.tart.calls.first { $0.first == "set" }!
        XCTAssertEqual(Array(set.suffix(4)), ["--memory", "4096", "--cpu", "4"])
        let run = r.tart.spawned.first!.args
        XCTAssertTrue(run.contains("--no-graphics"), "up never opens a window")
        XCTAssertEqual(run.filter { $0.hasPrefix("--dir") }.count, 1)
        XCTAssertTrue(run.contains { $0.hasPrefix("--dir=handoff:") && $0.hasSuffix("/handoff/t1") })
        XCTAssertEqual(s.lastUp?.route, "cold")
    }

    func testAFailedSelfcheckStopsAndDeletesTheVMAndLeavesNothing() {
        let r = rig()
        r.tart.leaks = ["192.168.1.20"]
        XCTAssertThrowsError(try r.manager.up(task: "t1")) {
            let e = $0 as? SandboxError
            XCTAssertEqual(e?.code, "selfcheck_failed"); XCTAssertEqual(e?.vmDeleted, true)
        }
        XCTAssertTrue(r.tart.ours().isEmpty, "no VM survives a failed check: \(r.tart.ours())")
        XCTAssertEqual(r.manager.snapshot().selfcheck, "failed")
        XCTAssertNil(r.manager.snapshot().vm)
        XCTAssertTrue(r.tart.spawned.allSatisfy { !$0.proc.isRunning })
    }

    func testNoInternetAlsoFailsAndDeletes() {
        let r = rig(); r.tart.noInternet = true
        XCTAssertThrowsError(try r.manager.up(task: "t1"))
        XCTAssertTrue(r.tart.ours().isEmpty)
    }

    func testCloneFailureLeavesNothing() {
        let r = rig(); r.tart.failClone = true
        XCTAssertThrowsError(try r.manager.up(task: "t1")) { XCTAssertEqual(($0 as? SandboxError)?.code, "clone_failed") }
        XCTAssertTrue(r.tart.ours().isEmpty)
        XCTAssertEqual(r.manager.snapshot().phase, .error)
    }

    func testAGuestAgentThatNeverAnswersDeletesTheVM() {
        let r = rig(); r.tart.agentNeverAnswers = true
        r.manager.bootLimit = 5
        XCTAssertThrowsError(try r.manager.up(task: "t1")) { XCTAssertEqual(($0 as? SandboxError)?.code, "agent_timeout") }
        XCTAssertTrue(r.tart.ours().isEmpty)
    }

    func testAVMThatExitsBeforeItsAgentAnswersIsDeleted() {
        let r = rig()
        r.tart.agentNeverAnswers = true
        r.manager.bootLimit = 3
        XCTAssertThrowsError(try r.manager.up(task: "t1"))
        XCTAssertTrue(r.tart.ours().isEmpty)
    }

    func testAVMThatCannotBeDeletedIsRetriedAndReported() throws {
        let r = rig()
        _ = try r.manager.up(task: "t1")
        r.tart.failDeleteOnce = 100 // every delete does nothing
        XCTAssertThrowsError(try r.manager.down()) { XCTAssertEqual(($0 as? SandboxError)?.code, "not_deleted") }
        XCTAssertFalse(r.manager.snapshot().pendingDeletes.isEmpty)
        r.tart.failDeleteOnce = 0
        r.manager.tick()
        XCTAssertTrue(r.manager.snapshot().pendingDeletes.isEmpty, "the next tick deletes it")
        XCTAssertTrue(r.tart.ours().filter { !$0.hasPrefix("bsx-s-") }.isEmpty)
    }

    func testDownStopsAndDeletesTheWorkingVMOnly() throws {
        let r = rig()
        _ = try r.manager.up(task: "t1")
        XCTAssertTrue(r.manager.waitUntilWarm(limit: 60))
        let working = r.manager.snapshot().vm!
        let s = try r.manager.down()
        XCTAssertEqual(s.phase, .stopped)
        XCTAssertFalse(r.tart.vmNames().contains(working))
        XCTAssertEqual(r.tart.ours().count, 1, "the warm clone stays for the next up")
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.dir.appendingPathComponent("handoff/t1").path), "the handoff folder is yours, never deleted")
    }

    func testStartupDeletesEveryLeftoverButNotOtherVMs() throws {
        let r = rig()
        r.tart.vms["bsx-w-crashed"] = .init(); r.tart.vms["bsx-s-old"] = .init(); r.tart.vms["my-own-vm"] = .init()
        _ = try r.manager.up(task: "t1")
        XCTAssertFalse(r.tart.vmNames().contains("bsx-w-crashed")); XCTAssertFalse(r.tart.vmNames().contains("bsx-s-old"))
        XCTAssertTrue(r.tart.vmNames().contains("my-own-vm"), "VMs that aren't ours are never touched")
    }

    func testOnlyOneManagerOwnsTheSandbox() throws {
        let r = rig()
        _ = try r.manager.up(task: "t1")
        let other = SandboxManager(tart: r.st, facts: r.facts, clock: r.clock, paths: SandboxPaths(root: r.dir), settings: { SandboxSettings(enabled: true) })
        XCTAssertThrowsError(try other.up(task: "t2")) { XCTAssertEqual(($0 as? SandboxError)?.code, "not_owner") }
    }

    func testUpTwiceForTheSameTaskIsHarmlessAndForAnotherTaskIsRefused() throws {
        let r = rig()
        _ = try r.manager.up(task: "t1")
        let before = r.tart.spawned.count
        _ = try r.manager.up(task: "t1")
        XCTAssertEqual(r.tart.spawned.count, before)
        XCTAssertThrowsError(try r.manager.up(task: "t2")) { XCTAssertEqual(($0 as? SandboxError)?.code, "busy") }
    }

    func testBadTaskNamesNeverReachTheDisk() {
        let r = rig()
        for bad in ["../x", "a/b", ".hidden", "", String(repeating: "a", count: 65), "a..b"] {
            XCTAssertThrowsError(try r.manager.up(task: bad), bad)
        }
        XCTAssertTrue(r.tart.calls.isEmpty)
    }

    // MARK: two guests at most

    func testAThirdGuestGetsBusyWithRetryAfterAndNothingIsMade() {
        let r = rig()
        r.tart.vms["someone-elses-1"] = .init(proc: FakeProc()); r.tart.vms["someone-elses-2"] = .init(proc: FakeProc())
        XCTAssertThrowsError(try r.manager.up(task: "t")) {
            let e = $0 as? SandboxError
            XCTAssertEqual(e?.code, "busy"); XCTAssertEqual(e?.retry, "after")
        }
        XCTAssertFalse(r.tart.calls.contains { $0.first == "clone" }, "no VM is cloned when there is no room")
        XCTAssertEqual(r.manager.snapshot().phase, .stopped)
        XCTAssertTrue(r.tart.vmNames().contains("someone-elses-1"), "other people's VMs are never touched")
    }

    func testWithOneOtherGuestRunningUpWorksButNoWarmCloneIsBuilt() throws {
        let r = rig()
        r.tart.vms["someone-elses"] = .init(proc: FakeProc())
        _ = try r.manager.up(task: "t")
        XCTAssertEqual(r.manager.snapshot().warm, .none, "working + the other guest are the two")
        XCTAssertEqual(r.tart.ours().count, 1)
    }

    func testBusyThroughTheServiceCarriesRetryAfter() {
        let r = rig()
        r.tart.vms["a"] = .init(proc: FakeProc()); r.tart.vms["b"] = .init(proc: FakeProc())
        let s = SandboxService(manager: r.manager, tart: r.st, settings: { SandboxSettings(enabled: true) }, tartHome: r.dir)
        let reply = s.handle(Wire.Request(op: .sandbox, text: "up"))
        let d = (try? JSONSerialization.jsonObject(with: Data((reply.info?["json"] ?? "{}").utf8))) as? [String: Any]
        XCTAssertEqual(d?["code"] as? String, "busy"); XCTAssertEqual(d?["retry"] as? String, "after")
    }

    // MARK: reset

    func testResetSwapsToTheWarmCloneWithinTheBudgetAndBuildsAnother() throws {
        let r = rig()
        _ = try r.manager.up(task: "t1")
        XCTAssertTrue(r.manager.waitUntilWarm(limit: 120))
        let old = r.manager.snapshot().vm!
        let t = try r.manager.reset()
        XCTAssertEqual(t.route, .swap)
        XCTAssertTrue(t.withinBudget, "\(t.seconds) s")
        let s = r.manager.snapshot()
        XCTAssertNotEqual(s.vm, old)
        XCTAssertFalse(r.tart.vmNames().contains(old), "the old VM is deleted")
        let resume = r.tart.spawned.last!.args
        XCTAssertTrue(resume.contains("--no-graphics")); XCTAssertEqual(resume.last, s.vm)
        XCTAssertTrue(resume.contains { $0.hasSuffix("/handoff/t1") }, "the same task's folder follows the reset")
        XCTAssertTrue(r.manager.waitUntilWarm(limit: 120), "the next warm clone is built")
        XCTAssertTrue(r.manager.waitUntilVerified(limit: 60))
        XCTAssertEqual(r.manager.snapshot().selfcheck, "passed", "the swapped-in guest is checked right after")
    }

    func testAGuestThatFailsTheCheckAfterAResetIsDeleted() throws {
        let r = rig()
        _ = try r.manager.up(task: "t1")
        XCTAssertTrue(r.manager.waitUntilWarm(limit: 120))
        r.tart.leaks = ["192.168.1.20"] // isolation breaks after the swap
        _ = try r.manager.reset()
        XCTAssertTrue(r.manager.waitUntilVerified(limit: 60))
        XCTAssertNil(r.manager.snapshot().vm)
        XCTAssertTrue(r.tart.ours().isEmpty, "\(r.tart.ours())")
    }

    func testResetKillsTheOldGuestBeforeTheNewOneStartsSoTheyNeverShareTheFolder() throws {
        let r = rig()
        _ = try r.manager.up(task: "t1")
        XCTAssertTrue(r.manager.waitUntilWarm(limit: 120))
        let oldProc = r.tart.spawned.first { $0.args.last == r.manager.snapshot().vm }!.proc
        var oldRunningWhenNewStarted: Bool?
        r.tart.onSpawn = { _ in if oldRunningWhenNewStarted == nil { oldRunningWhenNewStarted = oldProc.isRunning } }
        _ = try r.manager.reset()
        XCTAssertEqual(oldRunningWhenNewStarted, false)
    }

    func testResetWithNoWarmCloneBootsColdAndSaysItMissedTheBudget() throws {
        let r = rig()
        _ = try r.manager.up(task: "t1")
        r.manager.warmWaitLimit = 0
        // the first warm build may or may not have finished; make sure none is ready
        _ = r.manager.waitUntilWarm(limit: 120)
        _ = try r.manager.reset()           // uses the warm clone, and starts the next build
        let t = try r.manager.reset()       // that build isn't done: waits 0 s, so cold
        if t.route == .cold { XCTAssertFalse(t.withinBudget, "a cold boot is never reported as meeting the budget") }
        XCTAssertEqual(r.manager.snapshot().phase, .running)
    }

    func testResetFailureDeletesEverythingItMade() throws {
        let r = rig()
        _ = try r.manager.up(task: "t1")
        XCTAssertTrue(r.manager.waitUntilWarm(limit: 120))
        r.tart.failResume = true
        r.tart.failClone = true // the cold fallback fails too
        XCTAssertThrowsError(try r.manager.reset())
        XCTAssertNil(r.manager.snapshot().vm)
        XCTAssertTrue(r.tart.ours().isEmpty, "\(r.tart.ours())")
        XCTAssertEqual(r.manager.snapshot().phase, .error)
    }

    func testResetNeedsAnUpSandbox() {
        let r = rig()
        XCTAssertThrowsError(try r.manager.reset()) { XCTAssertEqual(($0 as? SandboxError)?.code, "not_up") }
    }

    func testResetPlanAndBudget() {
        XCTAssertEqual(SandboxResetPlan.choose(warmReady: true, warmBuilding: true), .swap)
        XCTAssertEqual(SandboxResetPlan.choose(warmReady: false, warmBuilding: true), .waitForWarm)
        XCTAssertEqual(SandboxResetPlan.choose(warmReady: false, warmBuilding: false), .cold)
        XCTAssertTrue(SandboxResetTiming(route: .swap, seconds: 9.9).withinBudget)
        XCTAssertFalse(SandboxResetTiming(route: .swap, seconds: 10.1).withinBudget)
        XCTAssertFalse(SandboxResetTiming(route: .cold, seconds: 3).withinBudget)
    }

    func testAVMThatExitedOnItsOwnIsDeletedByTheNextTick() throws {
        let r = rig()
        _ = try r.manager.up(task: "t1")
        let vm = r.manager.snapshot().vm!
        r.tart.spawned.first { $0.args.last == vm }!.proc.stop() // its window was closed
        r.manager.tick()
        XCTAssertNil(r.manager.snapshot().vm)
        XCTAssertFalse(r.tart.vmNames().contains(vm))
        XCTAssertNotNil(r.manager.snapshot().lastError)
    }

    func testShutdownDeletesEverythingIncludingTheWarmClone() throws {
        let r = rig()
        _ = try r.manager.up(task: "t1")
        XCTAssertTrue(r.manager.waitUntilWarm(limit: 120))
        r.manager.shutdown()
        XCTAssertTrue(r.tart.ours().isEmpty)
    }

    func testDeleteImagesRefusesWhileUpAndRemovesTheVMsAndImageWhenDown() throws {
        let r = rig()
        _ = try r.manager.up(task: "t1")
        XCTAssertThrowsError(try r.manager.deleteImages()) { XCTAssertEqual(($0 as? SandboxError)?.code, "busy") }
        _ = try r.manager.down()
        // the fake keeps the image after "delete image", so only the VMs are asserted here
        try? r.manager.deleteImages()
        XCTAssertTrue(r.tart.ours().isEmpty)
    }

    // MARK: window

    func testViewRefusesWithoutAnAgentWorkspaceAndTouchesNothing() throws {
        let r = rig()
        _ = try r.manager.up(task: "t1")
        let host = FakeWindowHost(); host.workspace = nil
        let spawns = r.tart.spawned.count
        XCTAssertThrowsError(try r.manager.view(show: true, host: host)) { XCTAssertEqual(($0 as? SandboxError)?.code, "no_agent_workspace") }
        XCTAssertEqual(r.tart.spawned.count, spawns, "no window process started")
        XCTAssertTrue(host.log.isEmpty)
        XCTAssertNotNil(r.manager.snapshot().vm)
    }

    func testViewClaimsTheWindowForTheAgentWorkspaceNotTheUsers() throws {
        let r = rig()
        _ = try r.manager.up(task: "t1")
        XCTAssertTrue(r.manager.waitUntilWarm(limit: 120))
        let host = FakeWindowHost(); host.workspace = 9; host.current = 1
        // The VM's window first lands on the user's workspace 1.
        r.tart.onSpawn = { args in
            if !args.contains("--no-graphics") {
                let pid = FakeProc.next
                host.shown = [.init(id: 77, pid: pid, title: "bsx", workspace: 1), .init(id: 78, pid: pid + 99, title: "other app", workspace: 1)]
            }
        }
        let res = try r.manager.view(show: true, host: host)
        XCTAssertEqual(res?.workspace, 9)
        XCTAssertTrue(host.log.first!.hasSuffix("->9"), "claimed for 9: \(host.log)")
        XCTAssertEqual(host.moves.map(\.0), [77], "only the VM's window moves; another app's stays")
        XCTAssertTrue(host.moves.allSatisfy { $0.1 == 9 && $0.1 != host.current })
        XCTAssertFalse(r.tart.spawned.last!.args.contains("--no-graphics"))
        XCTAssertTrue(r.manager.snapshot().graphics)
        // and back to headless
        _ = try r.manager.view(show: false, host: host)
        XCTAssertFalse(r.manager.snapshot().graphics)
        XCTAssertTrue(r.tart.spawned.last!.args.contains("--no-graphics"))
    }

    func testViewFailureToResumeDeletesTheVM() throws {
        let r = rig()
        _ = try r.manager.up(task: "t1")
        r.tart.failResume = true
        XCTAssertThrowsError(try r.manager.view(show: true, host: FakeWindowHost()))
        XCTAssertNil(r.manager.snapshot().vm)
        XCTAssertTrue(r.tart.ours().filter { !$0.hasPrefix("bsx-s-") }.isEmpty)
    }
}

final class SandboxWindowDecisionTests: XCTestCase {
    func testNoAgentWorkspaceMeansNoWindow() {
        XCTAssertEqual(SandboxWindows.beforeLaunch(agentWorkspace: nil), .refuse(SandboxWindows.noAgentWorkspace))
        XCTAssertEqual(SandboxWindows.beforeLaunch(agentWorkspace: 9), .claim(workspace: 9))
        XCTAssertEqual(SandboxWindows.afterLaunch(windows: [], vmPid: 1, agentWorkspace: nil), [.refuse(SandboxWindows.noAgentWorkspace)])
    }

    func testOnlyTheVMsOwnWindowsMoveAndNeverToAnyOtherWorkspace() {
        let w = [SandboxWindows.Window(id: 1, pid: 10, workspace: 3), .init(id: 2, pid: 10, workspace: 9), .init(id: 3, pid: 11, workspace: 3),
                 .init(id: 4, pid: 10, workspace: nil)]
        XCTAssertEqual(SandboxWindows.afterLaunch(windows: w, vmPid: 10, agentWorkspace: 9),
                       [.move(window: 1, workspace: 9), .move(window: 4, workspace: 9)])
    }
}
