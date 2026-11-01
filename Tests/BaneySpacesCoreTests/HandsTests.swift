import XCTest
@testable import BaneySpacesCore

final class HandsEnvelopeTests: XCTestCase {
    func testASuccessHasDataAndNoError() throws {
        let line = HandsEnvelope.success(.object(["n": 1])).line
        let o = try XCTUnwrap(JSONValue.parse(line))
        XCTAssertEqual(o["ok"]?.bool, true)
        XCTAssertEqual(o["data"]?["n"]?.int, 1)
        XCTAssertNil(o["error"])
    }

    func testAFailureCarriesCodeRetryAndSuggestion() throws {
        let e = HandsError(.outsideAgentWorkspace, "nope", suggestion: "lend it")
        let o = try XCTUnwrap(JSONValue.parse(HandsEnvelope.failure(e).line))
        XCTAssertEqual(o["ok"]?.bool, false)
        XCTAssertNil(o["data"])
        XCTAssertEqual(o["error"]?["code"]?.string, "outside_agent_workspace")
        XCTAssertEqual(o["error"]?["retry"]?.string, "never")
        XCTAssertEqual(o["error"]?["suggestion"]?.string, "lend it")
        XCTAssertEqual(HandsEnvelope.decode(HandsEnvelope.failure(e).line)?.error, e)
    }

    func testEveryCodeHasARetryVerdictAndASnakeCaseName() {
        for c in HandsErrorCode.allCases {
            XCTAssertTrue([HandsRetry.safe, .afterSnapshot, .never].contains(c.defaultRetry))
            XCTAssertEqual(c.rawValue, c.rawValue.lowercased())
            XCTAssertFalse(c.rawValue.contains(" "))
        }
        XCTAssertEqual(HandsErrorCode.staleRef.defaultRetry, .afterSnapshot)
        XCTAssertEqual(HandsErrorCode.unknownRef.defaultRetry, .afterSnapshot)
        XCTAssertEqual(HandsErrorCode.outsideAgentWorkspace.defaultRetry, .never)
        XCTAssertEqual(HandsErrorCode.actionFailed.defaultRetry, .never, "an action that may have landed is never repeated blindly")
        XCTAssertEqual(HandsErrorCode.timeout.defaultRetry, .safe)
    }
}

final class HandsParseTests: XCTestCase {
    func parse(_ s: String) -> Result<HandsRequest, HandsError> { HandsParse.command(s.split(separator: " ").map(String.init)) }

    func testSnapshotTakesAppAndTheShortFlag() throws {
        let r = try parse("snapshot --app TextEdit -i").get()
        XCTAssertEqual(r.verb, "snapshot")
        XCTAssertEqual(r.string("app"), "TextEdit")
        XCTAssertTrue(r.bool("interactive"))
        XCTAssertFalse(r.bool("compact"))
    }

    func testActionsTakeARefAndTheRestAsText() throws {
        XCTAssertEqual(try parse("click @s1:e8").get().string("ref"), "@s1:e8")
        let t = try parse("type @s1:e3 Hello big world").get()
        XCTAssertEqual(t.string("ref"), "@s1:e3")
        XCTAssertEqual(t.string("text"), "Hello big world")
        XCTAssertEqual(try parse("set-value @s1:e3 42").get().string("value"), "42")
        XCTAssertEqual(try parse("scroll @s1:e3 down --amount 5").get().int("amount"), 5)
        XCTAssertEqual(try parse("press @s1:e3 cmd+a").get().string("key"), "cmd+a")
        XCTAssertEqual(try parse("open Safari https://example.com").get().string("targets"), "https://example.com")
        XCTAssertEqual(try parse("shot --window 4211").get().int("window"), 4211)
    }

    func testATextStartingWithADashNeedsTheSeparator() throws {
        XCTAssertEqual(try HandsParse.command(["type", "@s1:e3", "--", "--force"]).get().string("text"), "--force")
        XCTAssertEqual(try parse("type @s1:e3 -5").get().string("text"), "-5")
    }

    func testBadInputIsABadArgumentsErrorWithUsage() {
        for bad in ["click", "snapshot", "snapshot --bogus", "shot --window x", "scroll @s1:e1", "select @s1:e1", "fly @s1:e1", "type @s1:e1"] {
            guard case .failure(let e) = parse(bad) else { return XCTFail("\(bad) should fail") }
            XCTAssertEqual(e.code, .badArguments, bad)
            XCTAssertFalse(e.suggestion.isEmpty, bad)
        }
    }

    func testTheDocumentedCommandsAllExist() {
        let names = Set(HandsTools.all.map(\.verb))
        for v in ["snapshot", "find", "get", "click", "type", "set-value", "press", "scroll", "select", "toggle", "shot", "open", "lend", "return"] {
            XCTAssertTrue(names.contains(v), v)
        }
    }
}

final class ScopeGuardTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func win(_ ws: Int?, app: String = "TextEdit", bundle: String = "com.apple.TextEdit") -> HandsWindow {
        HandsWindow(id: 7, pid: 100, app: app, bundle: bundle, title: "t", workspace: ws)
    }

    func testTheAgentWorkspaceIsAllowed() {
        XCTAssertEqual(ScopeGuard.check(win(9), agentWorkspace: 9, lends: LendBook(), now: now), .onAgentWorkspace)
    }

    func testAUsersWorkspaceIsRefusedWithASuggestion() throws {
        guard case .denied(let e) = ScopeGuard.check(win(2), agentWorkspace: 9, lends: LendBook(), now: now) else { return XCTFail() }
        XCTAssertEqual(e.code, .outsideAgentWorkspace)
        XCTAssertEqual(e.retry, .never)
        XCTAssertTrue(e.suggestion.contains("agent lend TextEdit"))
        XCTAssertTrue(e.suggestion.contains("agent open TextEdit"))
    }

    func testAWindowBaneySpacesDoesNotPlaceIsRefused() {
        XCTAssertFalse(ScopeGuard.check(win(nil), agentWorkspace: 9, lends: LendBook(), now: now).allowed)
    }

    func testWithNoAgentWorkspaceNothingIsAllowedUnlessLent() {
        guard case .denied(let e) = ScopeGuard.check(win(2), agentWorkspace: nil, lends: LendBook(), now: now) else { return XCTFail() }
        XCTAssertEqual(e.code, .agentWorkspaceOff)
        var b = LendBook()
        b.lend(app: "TextEdit", bundle: "com.apple.TextEdit", session: "s", now: now, for: 60)
        XCTAssertEqual(ScopeGuard.check(win(2), agentWorkspace: nil, lends: b, now: now), .lent)
    }

    func testALentAppIsAllowedUntilReturnedExpiredOrItsSessionEnds() {
        var b = LendBook()
        b.lend(app: "TextEdit", bundle: "com.apple.TextEdit", session: "sess", now: now, for: 600)
        XCTAssertEqual(ScopeGuard.check(win(2), agentWorkspace: 9, lends: b, now: now), .lent)
        XCTAssertFalse(ScopeGuard.check(win(2, app: "Notes", bundle: "com.apple.Notes"), agentWorkspace: 9, lends: b, now: now).allowed, "only the lent app")
        // Timed out: refused without anyone returning it.
        XCTAssertFalse(ScopeGuard.check(win(2), agentWorkspace: 9, lends: b, now: now.addingTimeInterval(601)).allowed)
        var returned = b
        XCTAssertTrue(returned.giveBack("textedit"))
        XCTAssertFalse(ScopeGuard.check(win(2), agentWorkspace: 9, lends: returned, now: now).allowed)
        var ended = b
        XCTAssertEqual(ended.endSession("sess").map(\.app), ["TextEdit"])
        XCTAssertFalse(ScopeGuard.check(win(2), agentWorkspace: 9, lends: ended, now: now).allowed)
        var other = b
        XCTAssertTrue(other.endSession("someone else").isEmpty)
        XCTAssertTrue(other.expire(now: now.addingTimeInterval(601)).count == 1)
    }

    func testLendDurations() {
        XCTAssertEqual(LendBook.duration(nil), 1800)
        XCTAssertEqual(LendBook.duration("10m"), 600)
        XCTAssertEqual(LendBook.duration("2h"), 7200)
        XCTAssertEqual(LendBook.duration("90s"), 90)
        XCTAssertEqual(LendBook.duration("30"), 1800)
        XCTAssertEqual(LendBook.duration("99h"), 8 * 3600, "at most eight hours")
        XCTAssertNil(LendBook.duration("soon"))
    }

    func testVisibleListsOnlyWhatIsAllowed() {
        let all = [win(9), HandsWindow(id: 8, pid: 1, app: "Mail", workspace: 1)]
        XCTAssertEqual(ScopeGuard.visible(all, agentWorkspace: 9, lends: LendBook(), now: now).map(\.window.id), [7])
    }
}

final class FocusGuardTests: XCTestCase {
    func testAMarkLastsAboutASecond() {
        var g = FocusGuard()
        let t = Date(timeIntervalSince1970: 50)
        g.mark(pid: 5, now: t)
        XCTAssertTrue(g.isMarked(pid: 5, now: t.addingTimeInterval(0.9)))
        XCTAssertFalse(g.isMarked(pid: 5, now: t.addingTimeInterval(1.0)))
        XCTAssertFalse(g.isMarked(pid: 6, now: t), "only the app the action touched")
        XCTAssertEqual(FocusGuard.window, 1.0)
    }

    func testMarkingAgainOnlyExtends() {
        var g = FocusGuard()
        let t = Date(timeIntervalSince1970: 50)
        g.mark(pid: 5, now: t)
        g.mark(pid: 5, now: t.addingTimeInterval(0.5))
        XCTAssertTrue(g.isMarked(pid: 5, now: t.addingTimeInterval(1.4)))
        g.mark(pid: 5, now: t, for: 0.1)
        XCTAssertTrue(g.isMarked(pid: 5, now: t.addingTimeInterval(1.4)), "a shorter mark never shortens")
        g.prune(now: t.addingTimeInterval(5))
        XCTAssertEqual(g.count, 0)
    }

    func testTheSharedGuardFollowsItsClock() {
        var now = Date(timeIntervalSince1970: 10)
        let a = AgentActivity(clock: { now })
        XCTAssertFalse(a.caused(pid: 3))
        a.mark(pid: 3)
        XCTAssertTrue(a.caused(pid: 3))
        now = now.addingTimeInterval(1.1)
        XCTAssertFalse(a.caused(pid: 3))
    }
}

final class AXDiffTests: XCTestCase {
    func tree(_ names: [String]) -> JSONValue {
        .object(["role": "window", "children": .array(names.map { .object(["role": "button", "name": .string($0), "ref": "@s:e1"]) })])
    }

    func testNoChangeIsNotAChange() {
        let d = AXDiff.between(tree(["OK", "Cancel"]), tree(["OK", "Cancel"]))
        XCTAssertFalse(d.changed)
    }

    func testAddedAndRemovedElementsAreNamed() {
        let d = AXDiff.between(tree(["OK", "Cancel"]), tree(["OK", "Save"]))
        XCTAssertTrue(d.changed)
        XCTAssertEqual(d.added, ["button|Save||"])
        XCTAssertEqual(d.removed, ["button|Cancel||"])
        XCTAssertEqual(d.json()["kind"]?.string, "ax_diff")
        XCTAssertEqual(d.json()["added_count"]?.int, 1)
    }

    func testRefsDoNotCountAsChanges() {
        let a = JSONValue.object(["role": "button", "name": "A", "ref": "@s1:e1"])
        let b = JSONValue.object(["role": "button", "name": "A", "ref": "@s2:e9"])
        XCTAssertFalse(AXDiff.between(a, b).changed)
    }
}

final class HandsMCPTests: XCTestCase {
    func server(_ perform: @escaping (HandsRequest) -> HandsEnvelope = { _ in .success(.object([:])) }) -> HandsMCP {
        HandsMCP(version: "9.9", session: "mcp:1", perform: perform)
    }
    func reply(_ s: HandsMCP, _ line: String) -> JSONValue? { s.handle(line).flatMap(JSONValue.parse) }

    func testInitializeAnswersWithToolsCapability() {
        let r = reply(server(), #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#)
        XCTAssertEqual(r?["id"]?.int, 1)
        XCTAssertEqual(r?["result"]?["protocolVersion"]?.string, "2025-03-26")
        XCTAssertNotNil(r?["result"]?["capabilities"]?["tools"])
        XCTAssertEqual(r?["result"]?["serverInfo"]?["name"]?.string, "baneyspaces")
    }

    func testNotificationsGetNoReply() {
        XCTAssertNil(server().handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
    }

    func testToolsListShape() throws {
        let tools = try XCTUnwrap(reply(server(), #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)?["result"]?["tools"]?.array)
        XCTAssertEqual(tools.count, HandsTools.all.count)
        let names = tools.compactMap { $0["name"]?.string }
        for n in ["snapshot", "find", "get", "click", "type", "set_value", "press", "scroll", "select", "toggle", "shot", "open", "lend", "return"] {
            XCTAssertTrue(names.contains(n), n)
        }
        XCTAssertEqual(Set(names).count, names.count)
        for t in tools {
            XCTAssertFalse(t["description"]?.string?.isEmpty ?? true)
            XCTAssertEqual(t["inputSchema"]?["type"]?.string, "object")
            XCTAssertNotNil(t["inputSchema"]?["properties"]?.object)
            XCTAssertNotNil(t["annotations"]?["readOnlyHint"]?.bool)
        }
        let click = try XCTUnwrap(tools.first { $0["name"]?.string == "click" })
        XCTAssertEqual(click["inputSchema"]?["required"]?.array?.compactMap(\.string), ["ref"])
        XCTAssertEqual(click["annotations"]?["readOnlyHint"]?.bool, false)
        let snap = try XCTUnwrap(tools.first { $0["name"]?.string == "snapshot" })
        XCTAssertEqual(snap["annotations"]?["readOnlyHint"]?.bool, true)
        XCTAssertEqual(snap["inputSchema"]?["properties"]?["window"]?["type"]?.string, "integer")
    }

    func testToolsCallBuildsTheRequestAndReturnsTheEnvelope() throws {
        var seen: HandsRequest?
        let s = server { seen = $0; return .success(.object(["clicked": true])) }
        let r = reply(s, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"set_value","arguments":{"ref":"@s1:e2","value":"hi"}}}"#)
        XCTAssertEqual(seen?.verb, "set-value")
        XCTAssertEqual(seen?.string("value"), "hi")
        XCTAssertEqual(seen?.session, "mcp:1")
        XCTAssertEqual(r?["result"]?["isError"]?.bool, false)
        let text = try XCTUnwrap(r?["result"]?["content"]?.array?.first?["text"]?.string)
        XCTAssertEqual(HandsEnvelope.decode(text)?.data?["clicked"]?.bool, true)
    }

    func testAFailedCallIsMarkedAnErrorWithTheEnvelope() throws {
        let s = server { _ in .failure(HandsError(.staleRef, "gone", suggestion: "snapshot")) }
        let r = reply(s, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"click","arguments":{"ref":"@s1:e2"}}}"#)
        XCTAssertEqual(r?["result"]?["isError"]?.bool, true)
        let text = try XCTUnwrap(r?["result"]?["content"]?.array?.first?["text"]?.string)
        XCTAssertEqual(HandsEnvelope.decode(text)?.error?.retry, .afterSnapshot)
    }

    func testBadArgumentsNeverReachThePerformer() {
        var called = false
        let s = server { _ in called = true; return .success(.null) }
        let r = reply(s, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"click","arguments":{}}}"#)
        XCTAssertFalse(called)
        XCTAssertEqual(r?["result"]?["isError"]?.bool, true)
    }

    func testUnknownMethodAndGarbage() {
        XCTAssertEqual(reply(server(), #"{"jsonrpc":"2.0","id":6,"method":"nope"}"#)?["error"]?["code"]?.int, -32601)
        XCTAssertEqual(reply(server(), "not json")?["error"]?["code"]?.int, -32700)
    }

    func testAShotReturnsTheImageToo() throws {
        let s = HandsMCP(version: "1", session: "s",
                         perform: { _ in .success(.object(["path": "/tmp/x.png"])) },
                         readImage: { _ in Data([1, 2, 3]) })
        let r = reply(s, #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"shot","arguments":{"window":5}}}"#)
        let content = try XCTUnwrap(r?["result"]?["content"]?.array)
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[1]["type"]?.string, "image")
        XCTAssertEqual(content[1]["data"]?.string, Data([1, 2, 3]).base64EncodedString())
    }
}

final class HandsEventsTests: XCTestCase {
    final class Spy: HandsEventListener {
        var seen: [HandsActionEvent] = []
        func handsWillAct(_ event: HandsActionEvent) { seen.append(event) }
    }

    func testNoListenerMeansNothingIsMeasured() {
        HandsEvents.setListener(nil)
        XCTAssertFalse(HandsEvents.hasListener)
        var built = false
        HandsEvents.willAct({ built = true; return HandsActionEvent(kind: "click", ref: "r", window: 1, pid: 2, app: "A", point: nil) }())
        XCTAssertFalse(built, "with no listener the event is never even built")
    }

    func testAListenerGetsTheTargetBeforeDispatch() {
        let spy = Spy()
        HandsEvents.setListener(spy)
        defer { HandsEvents.setListener(nil) }
        XCTAssertTrue(HandsEvents.hasListener)
        let p = HandsEvents.center(ofBounds: .object(["x": 100, "y": 40, "width": 20, "height": 10]))
        HandsEvents.willAct(HandsActionEvent(kind: "click", ref: "@s1:e2", window: 9, pid: 4, app: "TextEdit", point: p))
        XCTAssertEqual(spy.seen.count, 1)
        XCTAssertEqual(spy.seen[0].point, CGPoint(x: 110, y: 45))
        XCTAssertEqual(spy.seen[0].window, 9)
        XCTAssertEqual(spy.seen[0].kind, "click")
    }

    func testBoundsThatCantBeReadGiveNoPoint() {
        XCTAssertNil(HandsEvents.center(ofBounds: nil))
        XCTAssertNil(HandsEvents.center(ofBounds: .object(["x": 1])))
    }
}

/// Regression (2026-10-31): `agent open TextEdit` left the app's launch window on the user's workspace.
final class AgentOpenLaunchTests: XCTestCase {
    func testALaunchedAppsWindowsAreClaimedForTheAgentWorkspace() throws {
        let src = try HandsSourceTests.code("Sources/BaneySpaces/Deck/DeckController.swift")
        let launch = try XCTUnwrap(src.range(of: "NSWorkspace.shared.openApplication(at: url, configuration: cfg)"))
        let rest = String(src[launch.upperBound...])
        let block = String(rest.prefix(while: { _ in true }).prefix(900))
        // Old behavior: only a New Window press 1.5 s later, so the app's own launch window stayed put.
        XCTAssertTrue(block.contains("h.claim(app.processIdentifier, n, true, nil)"), "every window the launch opens is claimed")
        XCTAssertTrue(block.contains("AgentActivity.shared.mark(pid: app.processIdentifier"), "the launch activation is never followed")
        let claim = try XCTUnwrap(block.range(of: "h.claim(app.processIdentifier, n, true, nil)"))
        let press = try XCTUnwrap(block.range(of: "newWindow(app)"))
        XCTAssertTrue(claim.lowerBound < press.lowerBound, "claimed before anything else happens")
    }

    func testNewProcessClaimsTakeEveryWindowOfTheLaunch() throws {
        let spaces = try HandsSourceTests.code("Sources/BaneySpaces/Spaces.swift")
        XCTAssertTrue(spaces.contains("func claimNextWindow(of pid: pid_t, for n: Int, within: TimeInterval = 8, newProcess: Bool = false"))
    }

    func testTheLedgerNamesIt() throws {
        let text = try String(contentsOf: HandsSourceTests.root.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        XCTAssertTrue(text.contains("agent open` leaves the app's launch window on your workspace"))
    }

    func testTheProbeCountsAWindowOnAnyOtherWorkspaceAsAFailure() throws {
        let text = try String(contentsOf: HandsSourceTests.root.appendingPathComponent("scripts/agent-hands-probe.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains("stray window"))
    }
}

final class HandsWireTests: XCTestCase {
    func testNoOtherMachineMayUseTheHands() {
        XCTAssertFalse(Remote.allows(Wire.Request(op: .hands, text: "{}")))
    }
}

/// The apps' hands live in the app target, which tests can't import, so these read the source.
final class HandsSourceTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Code only: comments may name the banned calls.
    static func code(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.components(separatedBy: "//")[0] }.joined(separator: "\n")
    }

    static func handsFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Sources/BaneySpaces/Hands").path)
            .filter { $0.hasSuffix(".swift") }.map { "Sources/BaneySpaces/Hands/" + $0 }
    }

    func testAgentActionsNeverActivateRaiseOrPostGlobalInput() throws {
        let banned = ["activate(", "activateIgnoringOtherApps", "SetFrontProcess", "CGEventPost", "CGEventTapPost", "CGWarpMouse",
                      "CGEvent(", "AXRaise", "kAXRaiseAction", "NSApp.activate", "makeKeyAndOrderFront", "orderFrontRegardless",
                      "AXUIElementPerformAction", "CGSSetWorkspace", "CGSManagedDisplaySetCurrentSpace", "osascript", "Process()"]
        let files = try Self.handsFiles()
        XCTAssertGreaterThanOrEqual(files.count, 4)
        for f in files {
            let text = try Self.code(f)
            for b in banned { XCTAssertFalse(text.contains(b), "\(f) must not use \(b)") }
        }
    }

    func testTheEngineIsOnlyCalledHeadlessAndOnlyThroughTheAllowedEntryPoints() throws {
        let allowed: Set<String> = ["ad_init", "ad_adapter_create", "ad_check_permissions", "ad_snapshot_window", "ad_get_ref",
                                    "ad_execute_by_ref_timeout", "ad_adapter_create_with_session", "ad_free_string", "ad_last_error_message", "ad_last_error_suggestion"]
        var calls = 0
        for f in try Self.handsFiles() {
            let text = try Self.code(f)
            let re = try NSRegularExpression(pattern: #"\bad_[a-z0-9_]+\("#)
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let name = String(text[Range(m.range, in: text)!].dropLast())
                XCTAssertTrue(allowed.contains(name), "\(f) calls \(name), which is not on the hands' allowed list")
            }
            calls += text.components(separatedBy: "ad_execute_by_ref_timeout(").count - 1
            for policy in ["HEADED", "FOCUS_FALLBACK", "ad_execute_by_ref(", "ad_execute_action"] {
                XCTAssertFalse(text.contains(policy), "\(f) must not name \(policy)")
            }
        }
        XCTAssertEqual(calls, 1, "one place acts, so one place to check")
        let engine = try Self.code("Sources/BaneySpaces/Hands/HandsEngine.swift")
        XCTAssertTrue(engine.contains("ad_execute_by_ref_timeout(adapter, r, &action, Self.headlessPolicy, 5000, &out)"))
        XCTAssertTrue(engine.contains("static let headlessPolicy: Int32 = 0"))
    }

    func testEveryActionMarksTheFocusGuardOnBothSides() throws {
        let router = try Self.code("Sources/BaneySpaces/Hands/HandsRouter.swift")
        let before = router.range(of: "AgentActivity.shared.mark(pid: w.pid)")!
        let act = router.range(of: "HandsEngine.shared.act(")!
        XCTAssertTrue(before.lowerBound < act.lowerBound, "marked before the action")
        XCTAssertGreaterThanOrEqual(router.components(separatedBy: "AgentActivity.shared.mark(pid: w.pid)").count - 1, 3)
    }

    func testTheFocusLogicHonorsTheGuard() throws {
        let spaces = try Self.code("Sources/BaneySpaces/Spaces.swift")
        XCTAssertEqual(spaces.components(separatedBy: "AgentActivity.shared.caused(pid:").count - 1, 2, "app activation and focus-moved-within")
    }

    func testEveryActionReportsItsTargetBeforeDispatch() throws {
        let router = try Self.code("Sources/BaneySpaces/Hands/HandsRouter.swift")
        let report = try XCTUnwrap(router.range(of: "HandsEvents.willAct("))
        let act = try XCTUnwrap(router.range(of: "HandsEngine.shared.act("))
        XCTAssertTrue(report.lowerBound < act.lowerBound)
        XCTAssertEqual(router.components(separatedBy: "HandsEngine.shared.act(").count - 1, 1, "one place dispatches, so one place reports")
    }

    func testEveryActionChecksTheScopeAgain() throws {
        let router = try Self.code("Sources/BaneySpaces/Hands/HandsRouter.swift")
        XCTAssertTrue(router.contains("let d = decide(w, agent)"))
        let resolve = router.range(of: "private func resolve(")!
        let act = router.range(of: "private func act(")!
        XCTAssertTrue(resolve.lowerBound < act.lowerBound)
        XCTAssertTrue(router.contains("switch resolve(ref)"), "acting starts from a resolved, scope-checked ref")
    }

    func testKeepUsableNoLongerStartsWithCua() throws {
        let keys = try Self.code("Sources/BaneySpaces/Keys.swift")
        XCTAssertTrue(keys.contains("private static let initial: [String] = []"))
        for f in ["Sources/BaneySpaces/Keys.swift", "Sources/BaneySpaces/AppDelegate.swift", "Sources/BaneySpaces/Spaces.swift", "Sources/BaneySpaces/Deck/DeckController.swift"] {
            let text = try String(contentsOf: Self.root.appendingPathComponent(f), encoding: .utf8)
            XCTAssertFalse(text.lowercased().contains("cua-driver"), f)
        }
    }
}
