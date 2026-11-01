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
        XCTAssertEqual(try parse("open TextEdit notes.txt").get().args["targets"], .array(["notes.txt"]))
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
        for v in ["windows", "snapshot", "find", "get", "click", "type", "set-value", "press", "scroll", "select", "toggle", "shot", "open"] {
            XCTAssertTrue(names.contains(v), v)
        }
        XCTAssertFalse(names.contains("lend"))
        XCTAssertFalse(names.contains("return"))
    }

    func testLendAndReturnAreNotAgentToolsAndAnswerNeedsLend() {
        for line in ["lend Excel", "return Excel", "lend"] {
            guard case .failure(let e) = parse(line) else { return XCTFail(line) }
            XCTAssertEqual(e.code, .needsLend)
            XCTAssertEqual(e.retry, .never)
            XCTAssertTrue(e.suggestion.contains("Donovan"))
        }
        guard case .failure(let viaTool) = HandsParse.call(name: "lend", arguments: ["app": "Excel"]) else { return XCTFail() }
        XCTAssertEqual(viaTool.code, .needsLend)
        XCTAssertTrue(viaTool.suggestion.contains("agent lend Excel"))
    }

    func testOpenTargetsStayWholeWhenTheyHaveSpaces() throws {
        let r = try HandsParse.command(["open", "TextEdit", "/Users/me/Library/My Notes/a b.txt", "c.txt"]).get()
        XCTAssertEqual(r.args["targets"], .array(["/Users/me/Library/My Notes/a b.txt", "c.txt"]))
        let viaTool = try HandsParse.call(name: "open", arguments: ["app": "TextEdit", "targets": .array(["x y.txt"])]).get()
        XCTAssertEqual(viaTool.args["targets"], .array(["x y.txt"]))
        guard case .failure = HandsParse.call(name: "open", arguments: ["app": "TextEdit", "targets": "x y.txt"]) else { return XCTFail("a string is not a list") }
    }
}

final class ScopeGuardTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func win(_ ws: Int?, id: UInt32 = 7, pid: Int32 = 100, app: String = "TextEdit", bundle: String = "com.apple.TextEdit") -> HandsWindow {
        HandsWindow(id: id, pid: pid, app: app, bundle: bundle, title: "t", workspace: ws)
    }
    func book(windows: [UInt32] = [7], pid: Int32 = 100, for t: TimeInterval = 600, session: String = "sess") -> LendBook {
        var b = LendBook()
        b.lend(app: "TextEdit", bundle: "com.apple.TextEdit", pid: pid, windows: windows, session: session, now: now, for: t)
        return b
    }

    func testTheAgentWorkspaceIsAllowed() {
        XCTAssertEqual(ScopeGuard.check(win(9), agentWorkspace: 9, lends: LendBook(), now: now), .onAgentWorkspace)
    }

    func testAUsersWorkspaceIsRefusedWithASuggestionThatAgentsCantLend() throws {
        guard case .denied(let e) = ScopeGuard.check(win(2), agentWorkspace: 9, lends: LendBook(), now: now) else { return XCTFail() }
        XCTAssertEqual(e.code, .outsideAgentWorkspace)
        XCTAssertEqual(e.retry, .never)
        XCTAssertTrue(e.suggestion.contains("agent open TextEdit"))
        XCTAssertTrue(e.suggestion.contains("ask Donovan to lend"))
    }

    func testAWindowBaneySpacesDoesNotPlaceIsRefused() {
        XCTAssertFalse(ScopeGuard.check(win(nil), agentWorkspace: 9, lends: LendBook(), now: now).allowed)
    }

    func testWithNoAgentWorkspaceNothingIsAllowedUnlessLent() {
        guard case .denied(let e) = ScopeGuard.check(win(2), agentWorkspace: nil, lends: LendBook(), now: now) else { return XCTFail() }
        XCTAssertEqual(e.code, .agentWorkspaceOff)
        XCTAssertEqual(ScopeGuard.check(win(2), agentWorkspace: nil, lends: book(), now: now), .lent)
    }

    func testALendNamesTheProcessAndTheWindowsNotTheApp() {
        let b = book()
        XCTAssertEqual(ScopeGuard.check(win(2), agentWorkspace: 9, lends: b, now: now), .lent)
        XCTAssertFalse(ScopeGuard.check(win(2, pid: 101), agentWorkspace: 9, lends: b, now: now).allowed, "a second instance isn't the lent one")
        XCTAssertFalse(ScopeGuard.check(win(2, id: 8), agentWorkspace: 9, lends: b, now: now).allowed, "a window opened after the lend isn't lent")
        XCTAssertFalse(ScopeGuard.check(win(2, id: 9, pid: 5, app: "Notes", bundle: "com.apple.Notes"), agentWorkspace: 9, lends: b, now: now).allowed)
    }

    func testALentAppTheUserIsUsingIsRefusedWithInUse() {
        guard case .denied(let e) = ScopeGuard.check(win(2), agentWorkspace: 9, lends: book(), now: now, inUse: true) else { return XCTFail() }
        XCTAssertEqual(e.code, .inUse)
        XCTAssertEqual(e.retry, .safe)
        XCTAssertEqual(ScopeGuard.check(win(9), agentWorkspace: 9, lends: book(), now: now, inUse: true), .onAgentWorkspace, "agent workspace windows are never the user's")
    }

    func testLendsEndByReturnTimeoutOrSession() {
        let b = book()
        XCTAssertFalse(ScopeGuard.check(win(2), agentWorkspace: 9, lends: b, now: now.addingTimeInterval(601)).allowed, "timed out without anyone returning it")
        var returned = b
        XCTAssertTrue(returned.giveBack("textedit"))
        XCTAssertFalse(ScopeGuard.check(win(2), agentWorkspace: 9, lends: returned, now: now).allowed)
        var ended = b
        XCTAssertEqual(ended.endSession("sess").map(\.app), ["TextEdit"])
        var other = b
        XCTAssertTrue(other.endSession("someone else").isEmpty)
        XCTAssertTrue(other.endSession("").isEmpty)
    }

    func testExpiryIsReportedByTheFirstCallerOnly() {
        var b = book()
        XCTAssertEqual(b.active(now: now.addingTimeInterval(601)).count, 0, "reading never changes the book")
        XCTAssertEqual(b.entries.count, 1)
        XCTAssertEqual(b.expire(now: now.addingTimeInterval(601)).count, 1)
        XCTAssertEqual(b.expire(now: now.addingTimeInterval(602)).count, 0, "the second path finds nothing to announce")
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

final class PolicyTests: XCTestCase {
    func testOncePerUserAppsAreRefusedForTheSandbox() {
        for b in ["com.apple.Safari", "com.apple.Notes", "com.apple.mail", "com.apple.MobileSMS", "com.apple.iCal", "com.apple.Photos"] {
            XCTAssertTrue(OncePerUserApps.refuses(bundle: b, running: false), b)
        }
        XCTAssertFalse(OncePerUserApps.refuses(bundle: "com.apple.TextEdit", running: true))
        XCTAssertTrue(OncePerUserApps.refuses(bundle: "com.microsoft.Excel", running: true))
        XCTAssertFalse(OncePerUserApps.refuses(bundle: "com.microsoft.Excel", running: false))
        XCTAssertEqual(OncePerUserApps.error(app: "Notes").code, .needsSandbox)
    }

    func testOnlyFilesInsideTheHandoffFolderResolve() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-\(UUID().uuidString)")
        let inside = root.appendingPathComponent("My Notes")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let file = inside.appendingPathComponent("a b.txt")
        FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNotNil(HandoffPath.resolve(file.path, in: root))
        XCTAssertNotNil(HandoffPath.resolve("My Notes/a b.txt", in: root), "relative to the folder")
        XCTAssertNil(HandoffPath.resolve("/etc/hosts", in: root))
        XCTAssertNil(HandoffPath.resolve(root.path + "/../../etc/hosts", in: root))
        XCTAssertNil(HandoffPath.resolve(root.path + "/missing.txt", in: root))
        let link = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        XCTAssertNil(HandoffPath.resolve(link.path, in: root), "a symlink out of the folder doesn't count")
    }

    func testShotNamesAreAPlainFileName() {
        XCTAssertTrue(HandoffPath.isPlainFileName("page.png"))
        for bad in ["", "../x.png", "/tmp/x.png", ".hidden", "a/b.png", String(repeating: "a", count: 200)] {
            XCTAssertFalse(HandoffPath.isPlainFileName(bad), bad)
        }
    }

    func testTypingIsVerifiedByTheChangeNotJustTheText() {
        XCTAssertTrue(ValueCheck.typed(before: "", after: "ab", text: "ab"))
        XCTAssertTrue(ValueCheck.typed(before: "ab", after: "abab", text: "ab"), "typing text already there still changes the value")
        XCTAssertFalse(ValueCheck.typed(before: "ab", after: "ab", text: "ab"), "unchanged is not typed, even though it contains the text")
        XCTAssertFalse(ValueCheck.typed(before: "x", after: "y", text: "ab"))
        XCTAssertEqual(ValueCheck.set(before: "a", after: "b", expected: "b").verified, true)
        XCTAssertEqual(ValueCheck.set(before: "a", after: "b", expected: "b").changed, true)
        XCTAssertEqual(ValueCheck.set(before: "a", after: "a", expected: "b").verified, false)
    }

    func testTheUserUsingAnAppIsTrackedForThirtySeconds() {
        var u = UserUse()
        let t = Date(timeIntervalSince1970: 100)
        u.activated(1, now: t)
        XCTAssertTrue(u.inUse(1, frontNow: 1, now: t))
        u.activated(2, now: t.addingTimeInterval(5))
        XCTAssertTrue(u.inUse(1, frontNow: 2, now: t.addingTimeInterval(20)), "left 15 s ago")
        XCTAssertFalse(u.inUse(1, frontNow: 2, now: t.addingTimeInterval(36)))
        XCTAssertFalse(u.inUse(3, frontNow: 2, now: t))
        XCTAssertTrue(u.inUse(3, frontNow: 3, now: t), "front now counts even before an activation was seen")
    }
}

final class FocusGuardTests: XCTestCase {
    let t = Date(timeIntervalSince1970: 50)

    func testTheMarkHoldsForTheWholeActionAndATailAfterIt() {
        var g = FocusGuard()
        let token = g.begin(pid: 5, window: 11)
        XCTAssertTrue(g.caused(pid: 5, window: 11, bundle: nil, now: t.addingTimeInterval(60)), "a slow action is covered however long it takes")
        g.end(token, now: t.addingTimeInterval(60))
        XCTAssertTrue(g.caused(pid: 5, window: 11, bundle: nil, now: t.addingTimeInterval(61.4)))
        XCTAssertFalse(g.caused(pid: 5, window: 11, bundle: nil, now: t.addingTimeInterval(61.6)))
        XCTAssertEqual(FocusGuard.tail, 1.5)
    }

    func testTheMarkIsForOneWindowOfOneProcess() {
        var g = FocusGuard()
        _ = g.begin(pid: 5, window: 11)
        XCTAssertFalse(g.caused(pid: 5, window: 12, bundle: nil, now: t), "the user's own window of the same app is never ignored")
        XCTAssertFalse(g.caused(pid: 6, window: 11, bundle: nil, now: t), "another process with that window number isn't it")
        XCTAssertFalse(g.caused(pid: 5, window: nil, bundle: nil, now: t))
    }

    func testALaunchedAppIsTheAgentsWholeProcessOrBundleForAWhile() {
        var g = FocusGuard()
        g.markLaunch(bundle: "com.apple.TextEdit", now: t, for: 10)
        XCTAssertTrue(g.caused(pid: 9, window: 1, bundle: "com.apple.TextEdit", now: t.addingTimeInterval(9)), "before there is a pid")
        XCTAssertFalse(g.caused(pid: 9, window: 1, bundle: "com.apple.TextEdit", now: t.addingTimeInterval(11)))
        g.markLaunch(pid: 9, now: t, for: 6)
        XCTAssertTrue(g.caused(pid: 9, window: 77, bundle: nil, now: t.addingTimeInterval(5)))
        g.prune(now: t.addingTimeInterval(20))
        XCTAssertEqual(g.activeCount, 0)
    }

    func testTheSharedGuardFollowsItsClock() {
        var now = Date(timeIntervalSince1970: 10)
        let a = AgentActivity(clock: { now })
        XCTAssertFalse(a.caused(pid: 3, window: 4))
        let token = a.begin(pid: 3, window: 4)
        XCTAssertTrue(a.caused(pid: 3, window: 4))
        a.end(token)
        now = now.addingTimeInterval(1.4)
        XCTAssertTrue(a.caused(pid: 3, window: 4))
        now = now.addingTimeInterval(0.2)
        XCTAssertFalse(a.caused(pid: 3, window: 4))
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
        for n in ["windows", "snapshot", "find", "get", "click", "type", "set_value", "press", "scroll", "select", "toggle", "shot", "open"] {
            XCTAssertTrue(names.contains(n), n)
        }
        XCTAssertFalse(names.contains("lend"), "lending is not an agent tool")
        XCTAssertFalse(names.contains("return"))
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
        let open = try XCTUnwrap(tools.first { $0["name"]?.string == "open" })
        XCTAssertEqual(open["inputSchema"]?["properties"]?["targets"]?["type"]?.string, "array")
        XCTAssertEqual(open["annotations"]?["readOnlyHint"]?.bool, false)
        let shot = try XCTUnwrap(tools.first { $0["name"]?.string == "shot" })
        XCTAssertEqual(shot["annotations"]?["readOnlyHint"]?.bool, false, "a shot writes a file")
    }

    func testAnAgentCallingLendGetsNeedsLendAndNothingReachesTheApp() throws {
        var called = false
        let s = server { _ in called = true; return .success(.null) }
        let r = reply(s, #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"lend","arguments":{"app":"Excel","session":"other"}}}"#)
        XCTAssertFalse(called)
        XCTAssertEqual(r?["result"]?["isError"]?.bool, true)
        let text = try XCTUnwrap(r?["result"]?["content"]?.array?.first?["text"]?.string)
        XCTAssertEqual(HandsEnvelope.decode(text)?.error?.code, .needsLend)
    }

    func testASessionArgumentIsNotHonored() throws {
        var seen: HandsRequest?
        let s = server { seen = $0; return .success(.null) }
        _ = reply(s, #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"click","arguments":{"ref":"@s1:e1","session":"someone else"}}}"#)
        XCTAssertNil(seen, "an unknown argument is refused")
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

    /// The text from `marker` to the brace that closes the block it opens.
    static func block(after marker: String, in text: String) -> String? {
        guard let start = text.range(of: marker), let open = text[start.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var i = open
        while i < text.endIndex {
            if text[i] == "{" { depth += 1 } else if text[i] == "}" { depth -= 1; if depth == 0 { return String(text[open...i]) } }
            i = text.index(after: i)
        }
        return nil
    }

    static func handsFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Sources/BaneySpaces/Hands").path)
            .filter { $0.hasSuffix(".swift") }.map { "Sources/BaneySpaces/Hands/" + $0 }
    }

    func testBlockHelperFindsTheMatchingBrace() {
        XCTAssertEqual(Self.block(after: "f()", in: "x f() { a { b } c } d"), "{ a { b } c }")
        XCTAssertNil(Self.block(after: "g()", in: "f() { }"))
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

    func testTheEngineIsOnlyCalledStrictlyHeadlessAndOnlyThroughTheAllowedEntryPoints() throws {
        let allowed: Set<String> = ["ad_init", "ad_adapter_create", "ad_adapter_create_with_session", "ad_adapter_destroy", "ad_snapshot_window", "ad_get_ref",
                                    "ad_execute_by_ref_timeout", "ad_free_string", "ad_last_error_message", "ad_last_error_suggestion"]
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
        // The policy is one constant, passed as is, and no function takes a policy from its caller.
        XCTAssertTrue(engine.contains("ad_execute_by_ref_timeout(adapter, r, &action, Self.headlessPolicy, 5000, &out)"))
        XCTAssertTrue(engine.contains("static let headlessPolicy: Int32 = 0"))
        XCTAssertFalse(engine.contains("policy:"), "no caller can pass a policy")
        let act = try XCTUnwrap(Self.block(after: "func act(", in: engine))
        XCTAssertFalse(act.contains("policy"), "act has no policy parameter to override")
    }

    func testNoKeyActionCanReachTheEngine() throws {
        // PressKey is the one action the engine gives a focus permission of its own under Headless.
        let engine = try Self.code("Sources/BaneySpaces/Hands/HandsEngine.swift")
        let kinds = try XCTUnwrap(Self.block(after: "enum Kind: Int32", in: engine))
        XCTAssertFalse(kinds.lowercased().contains("press") || kinds.contains("14") || kinds.lowercased().contains("key"), "no key kind in the engine's kinds")
        let router = try Self.code("Sources/BaneySpaces/Hands/HandsRouter.swift")
        let press = try XCTUnwrap(Self.block(after: "private func press(", in: router))
        XCTAssertFalse(press.contains("HandsEngine"), "press answers not_supported without an engine call")
        XCTAssertTrue(press.contains(".notSupported"))
    }

    func testEveryActionHoldsTheFocusGuardForItsWholeRun() throws {
        let router = try Self.code("Sources/BaneySpaces/Hands/HandsRouter.swift")
        let act = try XCTUnwrap(Self.block(after: "private func act(", in: router))
        let begin = try XCTUnwrap(act.range(of: "AgentActivity.shared.begin(pid: w.pid, window: w.id)"))
        let end = try XCTUnwrap(act.range(of: "defer { AgentActivity.shared.end(token) }"))
        let engine = try XCTUnwrap(act.range(of: "HandsEngine.shared.act("))
        let firstRead = try XCTUnwrap(act.range(of: "valueOf(w, ref)"))
        XCTAssertTrue(begin.lowerBound < firstRead.lowerBound, "the mark starts before the first engine call, queue wait included")
        XCTAssertTrue(begin.lowerBound < end.lowerBound && end.lowerBound < engine.lowerBound, "released by defer, so every exit ends it")
        XCTAssertFalse(router.contains("mark(pid: w.pid)"), "no fixed-length mark")
    }

    func testTheFocusLogicAsksPerWindowAndNeverIgnoresTheUsersOwnWindows() throws {
        let spaces = try Self.code("Sources/BaneySpaces/Spaces.swift")
        XCTAssertEqual(spaces.components(separatedBy: "AgentActivity.shared.caused(pid: pid, window: w.id").count - 1, 2, "app activation and focus-moved-within")
        XCTAssertFalse(spaces.contains("caused(pid: pid)"), "never by process alone")
    }

    func testScopeIsCheckedAtResolveAndRightBeforeEveryEngineCall() throws {
        let router = try Self.code("Sources/BaneySpaces/Hands/HandsRouter.swift")
        XCTAssertTrue(router.contains("let d = decide(w, agent)"), "resolve checks")
        XCTAssertTrue(router.contains("if case .denied(let e) = decide(now, agent) { return e }"), "gate checks the live window")
        for (marker, call) in [("private func read(", "HandsEngine.shared.snapshot("), ("private func act(", "HandsEngine.shared.act("),
                               ("private func get(", "HandsEngine.shared.get(")] {
            let body = try XCTUnwrap(Self.block(after: marker, in: router), marker)
            let gate = try XCTUnwrap(body.range(of: "gate(w)"), "\(marker) gates")
            let engine = try XCTUnwrap(body.range(of: call), marker)
            XCTAssertTrue(gate.lowerBound < engine.lowerBound, "\(marker): gate first")
        }
        let act = try XCTUnwrap(Self.block(after: "private func act(", in: router))
        let lastGate = try XCTUnwrap(act.range(of: "if let e = gate(w) { return .failure(e) }", options: .backwards))
        XCTAssertTrue(lastGate.lowerBound < act.range(of: "HandsEngine.shared.act(")!.lowerBound, "the last check is immediately before dispatch")
    }

    func testARefIsBoundToItsSnapshotsWindowAndProcess() throws {
        let router = try Self.code("Sources/BaneySpaces/Hands/HandsRouter.swift")
        let resolve = try XCTUnwrap(Self.block(after: "private func resolve(", in: router))
        XCTAssertTrue(resolve.contains("w.pid == snap.pid"))
        XCTAssertTrue(resolve.contains("$0.id == snap.window"))
        XCTAssertTrue(resolve.contains(".staleRef"))
    }

    func testEveryActionReportsItsTargetBeforeDispatch() throws {
        let router = try Self.code("Sources/BaneySpaces/Hands/HandsRouter.swift")
        let report = try XCTUnwrap(router.range(of: "HandsEvents.willAct("))
        let act = try XCTUnwrap(router.range(of: "HandsEngine.shared.act("))
        XCTAssertTrue(report.lowerBound < act.lowerBound)
        XCTAssertEqual(router.components(separatedBy: "HandsEngine.shared.act(").count - 1, 1, "one place dispatches, so one place reports")
    }

    func testEngineCallsHaveABudgetAndAProcessQueue() throws {
        let engine = try Self.code("Sources/BaneySpaces/Hands/HandsEngine.swift")
        XCTAssertTrue(engine.contains("done.wait(timeout: .now() + budget) == .timedOut"))
        XCTAssertTrue(engine.contains("queue(for: pid).async"))
        XCTAssertFalse(engine.contains("queue.sync"), "no single queue that one slow app can hold")
        let server = try Self.code("Sources/BaneySpaces/Deck/Server.swift")
        XCTAssertTrue(server.contains("req.op == .hands ? handleHands(req)"), "hands requests don't go through the main thread")
    }

    func testShotsGoOnlyToTheShotsFolderAtomically() throws {
        let shot = try Self.code("Sources/BaneySpaces/Hands/WindowShot.swift")
        XCTAssertTrue(shot.contains("isPlainFileName"))
        XCTAssertTrue(shot.contains("moveItem(at: tmp, to: file)"))
        XCTAssertTrue(shot.contains("done.wait(timeout: .now() + budget)"))
        XCTAssertFalse(shot.contains("expandingTildeInPath"))
    }

    func testOnlyDonovanLends() throws {
        let router = try Self.code("Sources/BaneySpaces/Hands/HandsRouter.swift")
        let dispatch = try XCTUnwrap(Self.block(after: "func handle(", in: router))
        XCTAssertFalse(dispatch.contains("\"lend\""), "no agent verb lends")
        XCTAssertTrue(dispatch.contains("HandsTools.userOnly.contains(req.verb)"))
        let cli = try Self.code("Sources/baneyspaces-cli/Agent.swift")
        XCTAssertTrue(cli.contains("isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1"))
        XCTAssertTrue(cli.contains("caseInsensitiveCompare(app) == .orderedSame"), "a lend asks him to type the app's name")
        let mcp = try Self.code("Sources/baneyspaces-cli/Agent.swift")
        XCTAssertFalse(mcp.contains("\"return\", args"), "the MCP server lends and returns nothing")
    }

    func testKeepUsableNoLongerStartsWithCua() throws {
        let keys = try Self.code("Sources/BaneySpaces/Keys.swift")
        XCTAssertTrue(keys.contains("private static let initial: [String] = []"))
        for f in ["Sources/BaneySpaces/Keys.swift", "Sources/BaneySpaces/AppDelegate.swift", "Sources/BaneySpaces/Spaces.swift", "Sources/BaneySpaces/Deck/DeckController.swift"] {
            let text = try String(contentsOf: Self.root.appendingPathComponent(f), encoding: .utf8)
            XCTAssertFalse(text.lowercased().contains("cua-driver"), f)
        }
    }

    func testTheEngineLibraryIsFoundThroughRpath() throws {
        let build = try String(contentsOf: Self.root.appendingPathComponent("scripts/build-engine.sh"), encoding: .utf8)
        XCTAssertTrue(build.contains("install_name_tool -id @rpath/libagent_desktop_ffi.dylib"))
        XCTAssertTrue(build.contains("otool -D"))
        let bundle = try String(contentsOf: Self.root.appendingPathComponent("scripts/bundle.sh"), encoding: .utf8)
        XCTAssertTrue(bundle.contains("otool -L"))
        XCTAssertTrue(bundle.contains("@executable_path/../Frameworks"))
        let package = try String(contentsOf: Self.root.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertTrue(package.contains("@executable_path/../Frameworks"))
    }
}

/// Regression (2026-10-31): `agent open TextEdit` left the app's launch window on the user's workspace.
final class AgentOpenLaunchTests: XCTestCase {
    func testALaunchedAppsWindowsAreClaimedAtTheFirstSightingOfTheLaunch() throws {
        let src = try HandsSourceTests.code("Sources/BaneySpaces/Deck/DeckController.swift")
        let launch = try XCTUnwrap(HandsSourceTests.block(after: "func claimLaunch(", in: src))
        // Old behavior: only a New Window press 1.5 s later, so the app's own launch window stayed put.
        XCTAssertTrue(launch.contains("h.claim(app.processIdentifier, n, true, nil)"), "every window the launch opens is claimed")
        XCTAssertTrue(launch.contains("AgentActivity.shared.markLaunch(pid: app.processIdentifier"))
        let claim = try XCTUnwrap(launch.range(of: "h.claim("))
        let press = try XCTUnwrap(launch.range(of: "newWindow(app)"))
        XCTAssertTrue(claim.lowerBound < press.lowerBound, "claimed before anything else happens")
        // The launch can be seen before the completion handler runs (an app that activates itself first).
        XCTAssertTrue(src.contains("NSWorkspace.didLaunchApplicationNotification"))
        XCTAssertTrue(src.contains("AgentActivity.shared.markLaunch(bundle: bundle"), "marked by bundle before there is a pid")
        let handler = try XCTUnwrap(HandsSourceTests.block(after: "NSWorkspace.shared.openApplication(at: url, configuration: cfg)", in: src))
        XCTAssertTrue(handler.contains("claimLaunch(app)"))
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
        XCTAssertTrue(text.contains("mutating actions succeeded"), "too few successful edits is a failure, reads don't stand in")
        XCTAssertFalse(text.contains("\"Notes\""), "never Notes or any once-per-user app")
    }
}
