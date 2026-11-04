import Foundation
import XCTest
@testable import BaneySpacesCore

/// Agent access modes (Donovan, 2026-11-04): Read Only, Default and Full Access, set only by him in Settings.
final class AgentAccessModeTests: XCTestCase {
    func testASavedValueThatIsNoModeReadsAsDefaultNeverMore() {
        XCTAssertEqual(AgentAccessMode(saved: nil), .standard)
        XCTAssertEqual(AgentAccessMode(saved: ""), .standard)
        XCTAssertEqual(AgentAccessMode(saved: "FULL"), .standard)
        XCTAssertEqual(AgentAccessMode(saved: "full"), .full)
        XCTAssertEqual(AgentAccessMode(saved: "read_only"), .readOnly)
        XCTAssertEqual(AgentAccessMode(saved: "default"), .standard)
    }

    func testOnlyWideningAsks() {
        XCTAssertTrue(AgentAccessMode.full.widens(from: .standard))
        XCTAssertTrue(AgentAccessMode.full.widens(from: .readOnly))
        XCTAssertTrue(AgentAccessMode.standard.widens(from: .readOnly))
        XCTAssertFalse(AgentAccessMode.standard.widens(from: .full))
        XCTAssertFalse(AgentAccessMode.readOnly.widens(from: .standard))
        XCTAssertFalse(AgentAccessMode.full.widens(from: .full))
    }

    func testTheFullAccessTextSaysWhatStillHolds() {
        let d = AgentAccessMode.full.detail
        for kept in ["bring an app forward", "move your pointer", "30 seconds", "Open or Save panel"] {
            XCTAssertTrue(d.contains(kept), "Full Access says it keeps: \(kept)")
        }
    }
}

final class FullAccessScopeTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func win(_ ws: Int?, pid: Int32 = 100) -> HandsWindow {
        HandsWindow(id: 7, pid: pid, app: "Notes", bundle: "com.apple.Notes", title: "t", workspace: ws)
    }

    func testFullAccessOpensEveryWorkspace() {
        XCTAssertEqual(ScopeGuard.check(win(2), agentWorkspace: 9, lends: LendBook(), now: now, mode: .full), .fullAccess)
        XCTAssertEqual(ScopeGuard.check(win(2), agentWorkspace: nil, lends: LendBook(), now: now, mode: .full), .fullAccess, "no agent workspace needed")
        XCTAssertEqual(ScopeGuard.check(win(9), agentWorkspace: 9, lends: LendBook(), now: now, mode: .full), .onAgentWorkspace)
        XCTAssertEqual(ScopeDecision.fullAccess.reason, "full_access")
    }

    func testFullAccessStillWaitsWhileDonovanUsesTheApp() {
        guard case .denied(let e) = ScopeGuard.check(win(2), agentWorkspace: 9, lends: LendBook(), now: now, inUse: true, mode: .full) else { return XCTFail() }
        XCTAssertEqual(e.code, .inUse)
    }

    func testFullAccessStillRefusesAWindowBaneySpacesDoesNotPlace() {
        XCTAssertFalse(ScopeGuard.check(win(nil), agentWorkspace: 9, lends: LendBook(), now: now, mode: .full).allowed)
    }

    func testDefaultAndReadOnlyKeepTheOldLine() {
        for mode in [AgentAccessMode.standard, .readOnly] {
            guard case .denied(let e) = ScopeGuard.check(win(2), agentWorkspace: 9, lends: LendBook(), now: now, mode: mode) else { return XCTFail("\(mode)") }
            XCTAssertEqual(e.code, .outsideAgentWorkspace)
        }
        XCTAssertFalse(ScopeGuard.check(win(2), agentWorkspace: 9, lends: LendBook(), now: now).allowed, "the default argument is Default")
    }

    func testVisibleListsEveryPlacedWindowUnderFullAccess() {
        let all = [win(1), win(2, pid: 101), win(nil, pid: 102)]
        XCTAssertEqual(ScopeGuard.visible(all, agentWorkspace: 9, lends: LendBook(), now: now, mode: .full).count, 2)
        XCTAssertEqual(ScopeGuard.visible(all, agentWorkspace: 9, lends: LendBook(), now: now).count, 0)
    }
}

final class ReadOnlyGateTests: XCTestCase {
    func testEveryVerbThatChangesSomethingIsRefused() {
        for verb in AgentAccessGate.changes {
            let e = AgentAccessGate.refusal(verb: verb, mode: .readOnly)
            XCTAssertEqual(e?.code, .permissionDenied, verb)
            XCTAssertEqual(e?.retry, .never, verb)
            XCTAssertNil(AgentAccessGate.refusal(verb: verb, mode: .standard), verb)
            XCTAssertNil(AgentAccessGate.refusal(verb: verb, mode: .full), verb)
        }
    }

    func testReadingStaysOpen() {
        for verb in ["windows", "snapshot", "find", "get", "shot"] {
            XCTAssertNil(AgentAccessGate.refusal(verb: verb, mode: .readOnly), verb)
        }
    }

    /// A tool added later that acts is refused under Read Only unless it is a capture: it has to be put on the list.
    func testEveryActingToolIsOnTheList() {
        for tool in HandsTools.all where tool.acts && tool.verb != "shot" {
            XCTAssertTrue(AgentAccessGate.changes.contains(tool.verb), "\(tool.verb) acts, so Read Only must refuse it")
        }
        for verb in AgentAccessGate.changes { XCTAssertNotNil(HandsTools.tool(verb: verb), "\(verb) is a real tool") }
    }

    func testTheSessionOpsThatStartOrMoveAreRefused() {
        for op in ["open", "run", "move"] { XCTAssertNotNil(AgentAccessGate.sessionRefusal(op: op, mode: .readOnly), op) }
        for op in ["status", "mode", "on", "off", "cursor", "lend-ask"] { XCTAssertNil(AgentAccessGate.sessionRefusal(op: op, mode: .readOnly), op) }
        XCTAssertNil(AgentAccessGate.sessionRefusal(op: "open", mode: .standard))
    }
}

final class FullAccessOpenTests: XCTestCase {
    var handoff: URL!
    var outside: URL!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("access-\(UUID().uuidString)")
        handoff = root.appendingPathComponent("handoff")
        try FileManager.default.createDirectory(at: handoff, withIntermediateDirectories: true)
        outside = root.appendingPathComponent("elsewhere.txt")
        try Data("x".utf8).write(to: outside)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: handoff.deletingLastPathComponent()) }

    func testDefaultStillRefusesAnAppOffTheList() {
        guard case .failure(let e) = AgentOpenGate.check(app: "Notes", bundle: "com.apple.Notes", targets: [], handoff: handoff) else { return XCTFail() }
        XCTAssertEqual(e.code, .needsSandbox)
    }

    func testFullAccessStartsAnyAppAndOpensAnyFile() {
        guard case .success(let none) = AgentOpenGate.check(app: "Notes", bundle: "com.apple.Notes", targets: [], handoff: handoff, mode: .full) else { return XCTFail() }
        XCTAssertEqual(none, [])
        guard case .success(let files) = AgentOpenGate.check(app: "BBEdit", bundle: "com.barebones.bbedit", targets: [outside.path], handoff: handoff, mode: .full) else { return XCTFail() }
        XCTAssertEqual(files, [outside.standardizedFileURL.resolvingSymlinksInPath().path])
        guard case .failure(let missing) = AgentOpenGate.check(app: "BBEdit", bundle: "com.barebones.bbedit", targets: ["/no/such/file"], handoff: handoff, mode: .full) else { return XCTFail() }
        XCTAssertEqual(missing.code, .badArguments)
    }

    func testFullAccessKeepsWhatWouldShowAPanelOrABrowser() {
        guard case .failure(let url) = AgentOpenGate.check(app: "Notes", bundle: "com.apple.Notes", targets: ["https://example.com"], handoff: handoff, mode: .full) else { return XCTFail() }
        XCTAssertEqual(url.code, .notSupported)
        guard case .failure(let panel) = AgentOpenGate.check(app: "TextEdit", bundle: "com.apple.TextEdit", targets: [], handoff: handoff, mode: .full) else {
            return XCTFail("TextEdit with no file shows an Open panel")
        }
        XCTAssertEqual(panel.code, .badArguments)
    }

    func testDefaultStillRefusesAFileOutsideTheHandoffFolder() {
        guard case .failure = AgentOpenGate.check(app: "TextEdit", bundle: "com.apple.TextEdit", targets: [outside.path], handoff: handoff) else { return XCTFail() }
    }

    func testReadOnlyOpensNothing() {
        guard case .failure(let e) = AgentOpenGate.check(app: "Calculator", bundle: "com.apple.calculator", targets: [], handoff: handoff, mode: .readOnly) else { return XCTFail() }
        XCTAssertEqual(e.code, .permissionDenied)
    }
}

final class FullAccessBackgroundTests: XCTestCase {
    func facts(_ scope: ScopeKind, owned: Bool) -> BackgroundFacts {
        BackgroundFacts(kind: .keys, app: "Notes", pid: 500, window: 77, scope: scope, pidIsAgentOwned: owned,
                        windowOwnerPid: 500, axWindowResolved: true, siblingWindows: 0, condition: .normal, hasSheetOrPanel: false,
                        focusedWindow: 77, focusedElementWindow: 77, targetIsFront: false,
                        transports: TransportSupport(skyLight: true), block: nil, verifier: .ax)
    }

    func testFullAccessIsDonovansOwnProcessLikeALend() {
        guard case .success = BackgroundPlanner.plan(facts(.full, owned: false)) else { return XCTFail("a window of his under Full Access needs no agent-started process") }
        guard case .failure(let e) = BackgroundPlanner.plan(facts(.agentWorkspace, owned: false)) else { return XCTFail() }
        XCTAssertEqual(e.code, .needsLend, "the agent workspace still needs the agent's own process")
    }

    func testFullAccessKeepsTheBackgroundRules() {
        var front = facts(.full, owned: false); front.targetIsFront = true
        XCTAssertEqual(refused(front), .inUse)
        var sheet = facts(.full, owned: false); sheet.hasSheetOrPanel = true
        XCTAssertNotNil(refused(sheet))
        var hidden = facts(.full, owned: false); hidden.condition = .appHidden
        XCTAssertNotNil(refused(hidden))
    }

    private func refused(_ f: BackgroundFacts) -> HandsErrorCode? {
        if case .failure(let e) = BackgroundPlanner.plan(f) { return e.code }
        return nil
    }
}

final class AgentAccessSurfaceTests: XCTestCase {
    func testTheSocketNeverChangesTheMode() {
        XCTAssertNotNil(SocketPolicy.refusal(for: Wire.Request(op: .agent, text: "mode", args: ["full"])))
        XCTAssertNotNil(SocketPolicy.refusal(for: Wire.Request(op: .agent, text: "MODE", args: ["default"])))
        XCTAssertNil(SocketPolicy.refusal(for: Wire.Request(op: .agent, text: "mode")), "reading it is fine")
    }

    func testTheMenuShowsAModeOtherThanDefault() {
        let rows = MenuLayout.rows(current: 1, apps: [:])
        XCTAssertFalse(MenuLayout.entries(rows: rows, finished: 0, update: nil).contains { if case .access = $0 { return true }; return false })
        XCTAssertTrue(MenuLayout.entries(rows: rows, finished: 0, update: nil, access: .full).contains(.access(.full)))
        XCTAssertTrue(MenuLayout.entries(rows: rows, finished: 0, update: nil, access: .readOnly).contains(.access(.readOnly)))
        XCTAssertTrue(MenuLayout.accessTitle(.full).contains("Full Access"))
    }

    func testWideningGoesThroughTheRealClickSheet() throws {
        let access = try HandsSourceTests.code("Sources/BaneySpaces/Hands/AgentAccess.swift")
        let request = try XCTUnwrap(HandsSourceTests.block(after: "func request(", in: access))
        let ask = try XCTUnwrap(request.range(of: "if new.widens(from: old), !AccessConsent.ask(new) { return false }"))
        XCTAssertTrue(ask.lowerBound < request.range(of: "set(new)")!.lowerBound, "asked before it changes")
        let consent = try HandsSourceTests.code("Sources/BaneySpaces/LendConsent.swift")
        let sheet = try XCTUnwrap(HandsSourceTests.block(after: "static func ask(_ mode: AgentAccessMode)", in: consent))
        XCTAssertTrue(sheet.contains("button.isEnabled = false"))
        XCTAssertTrue(sheet.contains("LendConsent.notByHand(alert: alert, button: button, enabledAt: enabledAt)"), "a hardware click on the button only")
        XCTAssertTrue(sheet.range(of: "alert.addButton(withTitle: \"Keep")!.lowerBound < sheet.range(of: "Give Full Access")!.lowerBound, "the default button keeps")
    }

    func testEveryEntryPointReadsTheMode() throws {
        let router = try HandsSourceTests.code("Sources/BaneySpaces/Hands/HandsRouter.swift")
        let handle = try XCTUnwrap(HandsSourceTests.block(after: "func handle(_ req: HandsRequest)", in: router))
        XCTAssertTrue(handle.range(of: "AgentAccessGate.refusal(verb: req.verb")!.lowerBound < handle.range(of: "switch req.verb")!.lowerBound)
        XCTAssertTrue(router.contains("mode: mode)"), "the scope guard is asked with the mode")
        let session = try HandsSourceTests.code("Sources/BaneySpaces/Session/SessionController.swift")
        let agent = try XCTUnwrap(HandsSourceTests.block(after: "func agent(_ sub: String, _ args: [String])", in: session))
        XCTAssertTrue(agent.range(of: "AgentAccessGate.sessionRefusal(op: sub")!.lowerBound < agent.range(of: "switch sub")!.lowerBound)
        XCTAssertFalse(session.contains("AgentAccess.shared.set("), "the socket side never sets the mode")
        XCTAssertFalse(router.contains("AgentAccess.shared.set(") || router.contains("AgentAccess.shared.request("))
    }
}
