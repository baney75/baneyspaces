import Darwin
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
        guard case .denied(let onAgentWorkspace) = ScopeGuard.check(win(9), agentWorkspace: 9, lends: book(), now: now, inUse: true) else { return XCTFail("his hands are on it, wherever it lives") }
        XCTAssertEqual(onAgentWorkspace.code, .inUse)
        XCTAssertEqual(ScopeGuard.check(win(9), agentWorkspace: 9, lends: book(), now: now, inUse: false), .onAgentWorkspace)
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
    func testOnlyAVerifiedAllowlistMayBeStartedAndEverythingElseIsNeedsSandbox() {
        for ok in ["com.apple.TextEdit", "com.apple.calculator", "com.apple.Preview"] {
            XCTAssertNil(AgentAppPolicy.refusal(app: "A", bundle: ok), ok)
        }
        XCTAssertEqual(AgentAppPolicy.refusal(app: "Finder", bundle: "com.apple.finder")?.code, .needsSandbox, "Finder shows his folders; agents use files directly")
        let refused = ["com.google.Chrome", "org.mozilla.firefox", "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac",
                       "com.apple.Safari", "com.1password.1password", "com.agilebits.onepassword7", "com.apple.Passwords", "com.bitwarden.desktop",
                       "com.apple.keychainaccess", "com.apple.systempreferences", "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
                       "com.apple.Notes", "com.apple.mail", "com.apple.MobileSMS", "com.apple.iCal", "com.apple.Photos",
                       "com.microsoft.Excel", "com.microsoft.Word", "com.example.NeverChecked"]
        for b in refused {
            let e = AgentAppPolicy.refusal(app: "X", bundle: b)
            XCTAssertEqual(e?.code, .needsSandbox, b)
            XCTAssertEqual(e?.retry, .never, b)
            XCTAssertFalse(e?.suggestion.isEmpty ?? true, b)
        }
        XCTAssertTrue(AgentAppPolicy.needsSeparateInstance(bundle: "com.apple.TextEdit"))
        XCTAssertFalse(AgentAppPolicy.needsSeparateInstance(bundle: "com.apple.finder"), "Finder can't run twice")
        XCTAssertEqual(AgentAppPolicy.documentRequired, ["com.apple.TextEdit", "com.apple.Preview"])
    }

    func testTheOpenGateAppliesToEveryCaller() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gate-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("probe")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        if case .failure(let e) = AgentOpenGate.check(app: "Safari", bundle: "com.apple.Safari", targets: ["https://mail.example.com"], handoff: root) { XCTAssertEqual(e.code, .needsSandbox) } else { XCTFail() }
        if case .failure(let e) = AgentOpenGate.check(app: "TextEdit", bundle: "com.apple.TextEdit", targets: ["https://example.com"], handoff: root) { XCTAssertEqual(e.code, .notSupported) } else { XCTFail() }
        if case .failure(let e) = AgentOpenGate.check(app: "TextEdit", bundle: "com.apple.TextEdit", targets: ["/etc/hosts"], handoff: root) { XCTAssertEqual(e.code, .badArguments) } else { XCTFail() }
        if case .failure(let e) = AgentOpenGate.check(app: "Finder", bundle: "com.apple.finder", targets: [folder.path], handoff: root) { XCTAssertEqual(e.code, .needsSandbox, "not even on a handoff folder") } else { XCTFail() }
        // TextEdit and Preview start only with a document from the handoff folder: with none they show an Open panel.
        for (app, bundle) in [("TextEdit", "com.apple.TextEdit"), ("Preview", "com.apple.Preview")] {
            if case .failure(let e) = AgentOpenGate.check(app: app, bundle: bundle, targets: [], handoff: root) { XCTAssertEqual(e.code, .badArguments) } else { XCTFail(app) }
        }
        let doc = root.appendingPathComponent("a.txt")
        FileManager.default.createFile(atPath: doc.path, contents: Data("x".utf8))
        guard case .success(let files) = AgentOpenGate.check(app: "TextEdit", bundle: "com.apple.TextEdit", targets: [doc.path], handoff: root) else { return XCTFail() }
        XCTAssertEqual(files.count, 1)
        guard case .success(let none) = AgentOpenGate.check(app: "Calculator", bundle: "com.apple.calculator", targets: [], handoff: root) else { return XCTFail() }
        XCTAssertEqual(none, [], "Calculator needs no document")
    }

    func testRefmapIdentityDetectsARetargetedRef() throws {
        func refmap(pid: Int, window: String, instance: String = "i1") -> Data {
            Data(#"{"inner":{"@e1":{"pid":\#(pid),"source_window_id":"\#(window)","process_instance":"\#(instance)","role":"button"},"@e2":{"pid":\#(pid),"source_window_id":"\#(window)","process_instance":"\#(instance)"}},"counter":2}"#.utf8)
        }
        let sealed = try XCTUnwrap(RefmapIdentity.table(from: refmap(pid: 7, window: "w-9")))
        XCTAssertTrue(RefmapIdentity.allTarget(sealed, window: 9, pid: 7))
        XCTAssertFalse(RefmapIdentity.allTarget(sealed, window: 10, pid: 7))
        XCTAssertEqual(RefmapIdentity.key(forRef: "@s8f3k2p9:e1"), "@e1")
        XCTAssertTrue(RefmapIdentity.intact(sealed: sealed, current: refmap(pid: 7, window: "w-9"), ref: "@sX:e1"))
        XCTAssertFalse(RefmapIdentity.intact(sealed: sealed, current: refmap(pid: 8, window: "w-9"), ref: "@sX:e1"), "another process")
        XCTAssertFalse(RefmapIdentity.intact(sealed: sealed, current: refmap(pid: 7, window: "w-4211"), ref: "@sX:e1"), "another window")
        XCTAssertFalse(RefmapIdentity.intact(sealed: sealed, current: refmap(pid: 7, window: "w-9", instance: "i2"), ref: "@sX:e1"), "a restarted process")
        XCTAssertFalse(RefmapIdentity.intact(sealed: sealed, current: Data("garbage".utf8), ref: "@sX:e1"))
        XCTAssertFalse(RefmapIdentity.intact(sealed: sealed, current: refmap(pid: 7, window: "w-9"), ref: "@sX:e99"), "a ref that wasn't sealed")
    }

    func testOnlyHardwareEventsCountAsTheUsersClick() {
        XCTAssertTrue(UserEventSource.isGenuine(sourcePID: 0, sourceState: 1, age: 0.1))
        XCTAssertFalse(UserEventSource.isGenuine(sourcePID: 4242, sourceState: 1, age: 0.1), "posted by a program")
        XCTAssertFalse(UserEventSource.isGenuine(sourcePID: 0, sourceState: -1, age: 0.1), "private source")
        XCTAssertFalse(UserEventSource.isGenuine(sourcePID: 0, sourceState: 0, age: 0.1), "combined session source")
        XCTAssertFalse(UserEventSource.isGenuine(sourcePID: 0, sourceState: 1, age: 5), "an old event isn't the answer")
        XCTAssertFalse(UserEventSource.isGenuine(sourcePID: 0, sourceState: 1, age: -1))
    }

    func testIntegerArgumentsOutOfRangeAreNotNumbers() {
        XCTAssertNil(JSONValue.double(1e100).int)
        XCTAssertNil(JSONValue.double(.nan).int)
        XCTAssertEqual(JSONValue.double(42).int, 42)
        guard case .failure(let e) = HandsParse.call(name: "shot", arguments: ["window": .double(1e100)]) else { return XCTFail() }
        XCTAssertEqual(e.code, .badArguments)
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

    func testADocumentOutsideTheHandoffFolderIsRecognized() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("doc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inside = root.appendingPathComponent("a.txt")
        XCTAssertTrue(HandoffPath.contains(document: inside.absoluteString, in: root), "a file URL")
        XCTAssertTrue(HandoffPath.contains(document: inside.path, in: root), "a path")
        XCTAssertFalse(HandoffPath.contains(document: "file:///Users/someone/Documents/taxes.pdf", in: root))
        XCTAssertFalse(HandoffPath.contains(document: root.path + "/../elsewhere.txt", in: root))
        XCTAssertFalse(HandoffPath.contains(document: root.path, in: root), "the folder itself isn't a document in it")
    }

    func testOpenAndSavePanelsAreRecognized() {
        XCTAssertTrue(PanelDetector.isOpenOrSavePanel(identifier: "open-panel", subrole: nil, title: nil))
        XCTAssertTrue(PanelDetector.isOpenOrSavePanel(identifier: "save-panel", subrole: nil, title: "x"))
        XCTAssertTrue(PanelDetector.isOpenOrSavePanel(identifier: nil, subrole: "AXDialog", title: "Open"))
        XCTAssertTrue(PanelDetector.isOpenOrSavePanel(identifier: nil, subrole: "AXSystemDialog", title: "Save As"))
        XCTAssertFalse(PanelDetector.isOpenOrSavePanel(identifier: nil, subrole: "AXStandardWindow", title: "Untitled"))
        XCTAssertFalse(PanelDetector.isOpenOrSavePanel(identifier: nil, subrole: "AXDialog", title: "Fonts"))
    }

    func testAgentOwnedProcessesAreTheSameProcessNotJustTheSamePid() {
        var set = AgentOwnedSet()
        set.add(100, startedAt: 5000.25)
        XCTAssertTrue(set.contains(100, startedAt: 5000.25))
        XCTAssertFalse(set.contains(100, startedAt: 9000), "macOS reused the pid for another process")
        XCTAssertFalse(set.contains(100, startedAt: nil))
        XCTAssertFalse(set.contains(101, startedAt: 5000.25))
        set.remove(100)
        XCTAssertFalse(set.contains(100, startedAt: 5000.25), "dropped when it quits")
    }

    func testTheConsentAnswerMustBeAClickOnTheButtonAfterItWasEnabled() {
        XCTAssertTrue(ConsentClick.valid(kind: .mouseUp, eventTime: 12, buttonEnabledAt: 11, insideButton: true, keyIsActivation: false))
        XCTAssertFalse(ConsentClick.valid(kind: .mouseUp, eventTime: 10.5, buttonEnabledAt: 11, insideButton: true, keyIsActivation: false), "a click meant for what was under the pointer")
        XCTAssertFalse(ConsentClick.valid(kind: .mouseUp, eventTime: 12, buttonEnabledAt: 11, insideButton: false, keyIsActivation: false), "somewhere else on the sheet")
        XCTAssertFalse(ConsentClick.valid(kind: .other, eventTime: 12, buttonEnabledAt: 11, insideButton: true, keyIsActivation: true), "a mouse move lying around")
        XCTAssertTrue(ConsentClick.valid(kind: .keyDown, eventTime: 12, buttonEnabledAt: 11, insideButton: false, keyIsActivation: true))
        XCTAssertFalse(ConsentClick.valid(kind: .keyDown, eventTime: 12, buttonEnabledAt: 11, insideButton: false, keyIsActivation: false))
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
        g.markLaunch(bundle: "com.apple.TextEdit", excluding: [4], now: t, for: 10)
        XCTAssertTrue(g.caused(pid: 9, window: 1, bundle: "com.apple.TextEdit", now: t.addingTimeInterval(9)), "before there is a pid")
        XCTAssertFalse(g.caused(pid: 4, window: 1, bundle: "com.apple.TextEdit", now: t.addingTimeInterval(1)), "Donovan's own running copy is never ignored")
        XCTAssertFalse(g.caused(pid: 9, window: 1, bundle: "com.apple.TextEdit", now: t.addingTimeInterval(11)))
        g.markLaunch(bundle: "com.apple.Preview", excluding: [], now: t, for: 10)
        g.clearLaunch(bundle: "com.apple.Preview")
        XCTAssertFalse(g.caused(pid: 9, window: 1, bundle: "com.apple.Preview", now: t), "cleared once the launch's own process is known")
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

/// A fake engine that counts its dispatches.
final class EngineRetryTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1000)

    func run(_ script: [Result<Int, HandsError>], stop: HandsError? = nil, cancelAfter: Int = .max) -> (Result<Int, HandsError>, Int) {
        var calls = 0
        let r = EngineRetry.run(attempt: { defer { calls += 1 }; return script[min(calls, script.count - 1)] },
                                stop: { stop }, cancelled: { calls >= cancelAfter },
                                giveUp: t0.addingTimeInterval(5), now: { self.t0 }, pause: {})
        return (r, calls)
    }

    func timeout(_ retry: HandsRetry) -> HandsError { HandsError(.timeout, "slow", suggestion: "x", retry: retry) }

    func testATimeoutThatMayHaveLandedIsDispatchedExactlyOnce() {
        for unsafe in [HandsRetry.never, .afterSnapshot] {
            let (r, calls) = run([.failure(timeout(unsafe)), .success(1)])
            XCTAssertEqual(calls, 1, "an unsafe or unknown disposition is never dispatched again")
            guard case .failure(let e) = r else { return XCTFail() }
            XCTAssertEqual(e.code, .timeout)
            XCTAssertEqual(e.retry, unsafe)
        }
    }

    func testOnlyAFailureTheEngineCallsSafeIsRepeated() {
        let (r, calls) = run([.failure(timeout(.safe)), .failure(timeout(.safe)), .success(7)])
        XCTAssertEqual(calls, 3)
        guard case .success(7) = r else { return XCTFail() }
        // A different error, even a safe one, is final.
        let other = HandsError(.notSupported, "no", suggestion: "x", retry: .safe)
        XCTAssertEqual(run([.failure(other), .success(1)]).1, 1)
    }

    func testTheLoopStopsWhenTheCallerLeftOrTheScopeChanged() {
        XCTAssertEqual(run([.failure(timeout(.safe))], cancelAfter: 1).1, 1, "the caller gave up: no second dispatch")
        let gone = HandsError(.outsideAgentWorkspace, "moved", suggestion: "x")
        let (r, calls) = run([.failure(timeout(.safe)), .success(1)], stop: gone)
        XCTAssertEqual(calls, 1)
        guard case .failure(let e) = r else { return XCTFail() }
        XCTAssertEqual(e.code, .outsideAgentWorkspace)
    }

    func testTheLoopGivesUpAtItsDeadline() {
        var calls = 0
        var now = t0
        _ = EngineRetry.run(attempt: { calls += 1; return Result<Int, HandsError>.failure(self.timeout(.safe)) }, stop: { nil }, cancelled: { false },
                            giveUp: t0.addingTimeInterval(1), now: { now }, pause: { now = now.addingTimeInterval(0.4) })
        XCTAssertEqual(calls, 4, "0, 0.4, 0.8, then 1.2 s is past the deadline")
    }
}

/// Sheets are children of their document window, so a window with one attached is off limits.
final class AttachedSheetTests: XCTestCase {
    func window(children: [AXNodeInfo]) -> AXNodeInfo { AXNodeInfo(role: "AXWindow", subrole: "AXStandardWindow", identifier: nil, title: "Untitled", children: children) }

    func testAPlainDocumentWindowIsFine() {
        let tree = window(children: [AXNodeInfo(role: "AXScrollArea", children: [AXNodeInfo(role: "AXTextArea")]), AXNodeInfo(role: "AXToolbar")])
        XCTAssertFalse(PanelDetector.windowIsOffLimits(tree))
    }

    func testAnAttachedSheetMakesTheWholeWindowOffLimits() {
        XCTAssertTrue(PanelDetector.windowIsOffLimits(window(children: [AXNodeInfo(role: "AXScrollArea"), AXNodeInfo(role: "AXSheet", title: "Save")])))
        XCTAssertTrue(PanelDetector.windowIsOffLimits(window(children: [AXNodeInfo(role: "AXGroup", children: [AXNodeInfo(role: "AXSheet")])])), "a sheet below a group")
        XCTAssertTrue(PanelDetector.windowIsOffLimits(window(children: [AXNodeInfo(role: "AXGroup", identifier: "save-panel")])), "a panel descendant")
    }

    func testAPanelWindowItselfIsOffLimits() {
        XCTAssertTrue(PanelDetector.windowIsOffLimits(AXNodeInfo(role: "AXWindow", subrole: "AXDialog", identifier: "open-panel", title: "Open")))
        XCTAssertFalse(PanelDetector.windowIsOffLimits(AXNodeInfo(role: "AXWindow", subrole: "AXFloatingWindow", title: "Fonts")))
    }

    func testTheInspectionReadsOneLevelDownWithAShortTimeout() throws {
        let spaces = try HandsSourceTests.code("Sources/BaneySpaces/Spaces.swift")
        let inspect = try XCTUnwrap(HandsSourceTests.block(after: "func handsInspect(", in: spaces))
        XCTAssertTrue(inspect.contains("AXUIElementSetMessagingTimeout(e, 0.25)"))
        XCTAssertTrue(inspect.contains("PanelDetector.windowIsOffLimits(info(e, children: true))"))
    }
}

final class UserUseAfterAgentActivationTests: XCTestCase {
    func testAnAgentsActivationDoesNotMakeItHisAppAndDoesNotLoseTheLeftOne() {
        var u = UserUse()
        let t = Date(timeIntervalSince1970: 100)
        u.activated(1, now: t)                       // he is in the lent app
        u.activated(2, now: t.addingTimeInterval(5), byAgent: true)   // an agent's action brings its own app forward
        XCTAssertTrue(u.inUse(1, frontNow: 2, now: t.addingTimeInterval(20)), "he left it 15 s ago")
        XCTAssertFalse(u.inUse(1, frontNow: 2, now: t.addingTimeInterval(40)), "and 35 s ago he didn't")
        XCTAssertFalse(u.inUse(2, frontNow: 1, now: t.addingTimeInterval(6)), "not recorded as his")
    }

    func testAnyActionOnAProcessMakesItsActivationTheAgents() {
        var g = FocusGuard()
        let t = Date(timeIntervalSince1970: 50)
        let token = g.begin(pid: 5, window: 11)
        XCTAssertFalse(g.caused(pid: 5, window: nil, bundle: nil, now: t), "per-window rule unchanged")
        XCTAssertTrue(g.causedByAnyAction(pid: 5, bundle: nil, now: t))
        g.end(token, now: t)
        XCTAssertTrue(g.causedByAnyAction(pid: 5, bundle: nil, now: t.addingTimeInterval(1)))
        XCTAssertFalse(g.causedByAnyAction(pid: 5, bundle: nil, now: t.addingTimeInterval(2)))
        XCTAssertFalse(g.causedByAnyAction(pid: 6, bundle: nil, now: t))
    }
}

final class FinalRoundSourceTests: XCTestCase {
    func testTakingBackIsNeverThrottled() throws {
        let consent = try HandsSourceTests.code("Sources/BaneySpaces/LendConsent.swift")
        XCTAssertTrue(consent.contains("takeBack || Date().timeIntervalSince(lastShown) >= pause"))
        XCTAssertTrue(consent.contains("if takeBack { return false }"), "a refused take-back isn't counted")
        XCTAssertTrue(consent.contains("\"Keep Lent\""))
    }

    func testRemoteOpenStillReachesTheDeckOp() throws {
        let main = try HandsSourceTests.code("Sources/baneyspaces-cli/main.swift")
        XCTAssertTrue(main.contains("!(remoteHost != nil && rest.first == \"open\")"))
        XCTAssertTrue(Remote.allows(Wire.Request(op: .agent, text: "open", args: ["TextEdit"])))
    }

    func testAgentOnRefusesAWorkspaceInUse() throws {
        let deck = try HandsSourceTests.code("Sources/BaneySpaces/Deck/DeckController.swift")
        let on = try XCTUnwrap(HandsSourceTests.between("let n = args.first.flatMap(Int.init)", "case \"off\":", in: deck))
        XCTAssertTrue(on.contains("h.occupied(n)"))
        XCTAssertTrue(on.range(of: "h.occupied(n)")!.lowerBound < on.range(of: "h.setWorkspace(n)")!.lowerBound)
    }

    func testThePressToolDoesNotPromiseWhatItCannotDo() {
        let press = HandsTools.tool(verb: "press")
        XCTAssertTrue(press?.summary.contains("not_supported") ?? false)
    }
}

final class HandsWireTests: XCTestCase {
    func testNoOtherMachineMayUseTheHands() {
        XCTAssertFalse(Remote.allows(Wire.Request(op: .hands, text: "{}")))
        XCTAssertFalse(Remote.allows(Wire.Request(op: .agent, text: "lend-ask", args: ["Excel"])))
        XCTAssertFalse(Remote.allows(Wire.Request(op: .agent, text: "move", args: ["1"])))
    }

    /// Any process of the user can write a line to the socket. Decoded the way the server decodes it, a raw
    /// lend, return or grant is refused before anything runs; a request to be asked is not a lend.
    func testARawLendRequestIsRejectedAtTheSocket() throws {
        for line in [#"{"op":"agent","text":"lend","args":["Excel","8h",""]}"#, #"{"op":"agent","text":"return","args":[]}"#,
                     #"{"op":"agent","text":"LEND","args":["Excel"]}"#, #"{"op":"agent","text":"grant","args":["Excel"]}"#] {
            let req = try JSONDecoder().decode(Wire.Request.self, from: Data(line.utf8))
            let why = try XCTUnwrap(SocketPolicy.refusal(for: req), line)
            XCTAssertTrue(why.contains("Donovan"))
        }
        let ask = try JSONDecoder().decode(Wire.Request.self, from: Data(#"{"op":"agent","text":"lend-ask","args":["Excel"]}"#.utf8))
        XCTAssertNil(SocketPolicy.refusal(for: ask), "asking opens a sheet; it grants nothing")
        XCTAssertNil(SocketPolicy.refusal(for: Wire.Request(op: .ping)))
    }

    func testOverARealSocketTheServersFirstStepRefusesALend() throws {
        // The same steps as the server's `serve`: read a line, decode, screen it with SocketPolicy.
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(getpid())-\(UUID().uuidString.prefix(6)).sock").path
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = try XCTUnwrap(Wire.address(path: path))
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listener, 1), 0)
        defer { close(listener); unlink(path) }
        let served = expectation(description: "served")
        DispatchQueue.global().async {
            let client = Darwin.accept(listener, nil, nil)
            defer { close(client); served.fulfill() }
            guard let line = Wire.readLine(client), let req = try? JSONDecoder().decode(Wire.Request.self, from: line) else { return }
            let reply = SocketPolicy.refusal(for: req).map { Wire.Reply(ok: false, error: $0) } ?? Wire.Reply(ok: true)
            var data = (try? JSONEncoder().encode(reply)) ?? Data()
            data.append(0x0A)
            _ = Wire.writeAll(client, data)
        }
        let reply = try XCTUnwrap(Wire.call(Wire.Request(op: .agent, text: "lend", args: ["Excel", "8h", ""]), timeout: 3, path: path))
        XCTAssertFalse(reply.ok)
        XCTAssertTrue(reply.error?.contains("Donovan") ?? false)
        wait(for: [served], timeout: 3)
    }

    func testAnAgentMayMoveOnlyWindowsOfProcessesStartedForAgents() {
        XCTAssertTrue(SocketPolicy.mayMove(windowPid: 10, startedForAgents: [10, 11]))
        XCTAssertFalse(SocketPolicy.mayMove(windowPid: 12, startedForAgents: [10, 11]), "Donovan's Mail window")
        XCTAssertFalse(SocketPolicy.mayMove(windowPid: nil, startedForAgents: [10]))
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

    /// The text from `start` up to `end`.
    static func between(_ start: String, _ end: String, in text: String) -> String? {
        guard let a = text.range(of: start), let b = text[a.upperBound...].range(of: end) else { return nil }
        return String(text[a.lowerBound..<b.lowerBound])
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
        // Single shot: the engine's own 5 s wait would run with no scope check. The wait is ours, checked each attempt.
        XCTAssertTrue(engine.contains("ad_execute_by_ref_timeout(adapter, r, &action, Self.headlessPolicy, 0, &out)"))
        XCTAssertTrue(engine.contains("stop: check, cancelled: cancelled"), "the scope and the caller's wait are checked between attempts")
        XCTAssertTrue(engine.contains("EngineRetry.run("))
        XCTAssertFalse(engine.contains("ad_snapshot_window(adapter, a,"), "the exact window id alone, never the app's shared name")
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

    func testScopeIsCheckedAtResolveAndAtTheMomentEveryEngineCallExecutes() throws {
        let router = try Self.code("Sources/BaneySpaces/Hands/HandsRouter.swift")
        XCTAssertTrue(router.contains("let d = decide(w, agent)"), "resolve checks")
        XCTAssertTrue(router.contains("if case .denied(let e) = decide(now, agent) { return e }"), "gate checks the live window")
        XCTAssertTrue(router.contains("{ [self] in gate(w) ?? ref.flatMap { refProblem($0) } }"), "the check closure is scope, then the ref's identity")
        // Every engine call the router makes hands the engine a check; none is made bare.
        let calls = router.components(separatedBy: "HandsEngine.shared.").dropFirst()
        XCTAssertGreaterThanOrEqual(calls.count, 6)
        for c in calls where !c.hasPrefix("permissionProblem") {
            XCTAssertTrue(c.prefix(260).contains("check: check(w"), "an engine call without a check: \(c.prefix(80))")
        }
        // ...and the engine runs it on the queue, right before the work, not when the call was enqueued.
        let engine = try Self.code("Sources/BaneySpaces/Hands/HandsEngine.swift")
        let run = try XCTUnwrap(Self.block(after: "private func run(window", in: engine))
        let check = try XCTUnwrap(run.range(of: "if let e = check()"))
        let work = try XCTUnwrap(run.range(of: "box.set(work { box.isCancelled })"))
        let queued = try XCTUnwrap(run.range(of: "queue(for: w.pid).async"))
        XCTAssertTrue(queued.lowerBound < check.lowerBound && check.lowerBound < work.lowerBound)
        XCTAssertTrue(run.contains("if box.isCancelled { return }"), "a call whose caller timed out is dropped unrun")
        XCTAssertTrue(run.contains("defer { AgentActivity.shared.end(token); done.signal() }"), "the focus guard lasts until the work really ends")
        for name in ["func snapshot(window", "func get(window", "func act(window"] {
            let sig = try XCTUnwrap(engine.range(of: name))
            XCTAssertTrue(engine[sig.upperBound...].prefix(260).contains("check: @escaping Check"), "\(name) requires a check")
        }
    }

    func testTheSocketCannotLendAndLendingNeedsARealClick() throws {
        let server = try Self.code("Sources/BaneySpaces/Deck/Server.swift")
        let serve = try XCTUnwrap(Self.block(after: "private func serve(_ client: Int32)", in: server))
        let policy = try XCTUnwrap(serve.range(of: "SocketPolicy.refusal(for: req)"))
        let dispatch = try XCTUnwrap(serve.range(of: "handleHands(req)"))
        XCTAssertTrue(policy.lowerBound < dispatch.lowerBound, "screened before anything runs")
        let deck = try Self.code("Sources/BaneySpaces/Deck/DeckController.swift")
        XCTAssertFalse(deck.contains("case \"lend\":"), "no lend case on the socket")
        XCTAssertFalse(deck.contains("case \"return\":"))
        XCTAssertFalse(deck.contains("userLend") || deck.contains("userReturn"))
        XCTAssertTrue(deck.contains("case \"lend-ask\":"))
        let router = try Self.code("Sources/BaneySpaces/Hands/HandsRouter.swift")
        let ask = try XCTUnwrap(Self.block(after: "func askToLend(", in: router))
        let sheet = try XCTUnwrap(ask.range(of: "host.askToLend(name, Int(seconds / 60), false)"))
        XCTAssertTrue(sheet.lowerBound < ask.range(of: "lends.lend(")!.lowerBound, "nothing is lent before the sheet is answered")
        XCTAssertFalse(router.contains("func userLend"), "no lend entry point that skips the sheet")
        let consent = try Self.code("Sources/BaneySpaces/LendConsent.swift")
        XCTAssertTrue(consent.contains("UserEventSource.isGenuine("), "the answer must be a hardware event")
        XCTAssertTrue(consent.contains("eventSourceUnixProcessID") && consent.contains("eventSourceStateID"))
        XCTAssertTrue(consent.contains("alert.addButton(withTitle: takeBack ? \"Keep Lent\" : \"Don't Lend\")"), "the default button refuses")
        XCTAssertTrue(consent.contains("pause"), "sheets are rate limited")
        XCTAssertTrue(consent.contains("button.isEnabled = false"), "Lend is disabled for the first second")
        XCTAssertTrue(consent.contains("ConsentClick.valid("))
        XCTAssertTrue(consent.contains("maxRefusals"), "asking stops after repeated refusals")
        let cli = try Self.code("Sources/baneyspaces-cli/Agent.swift")
        XCTAssertFalse(cli.contains("isatty"), "no terminal check: a program can fake one")
        XCTAssertTrue(cli.contains("text: \"lend-ask\""))
    }

    func testMovingAWindowToTheAgentWorkspaceNeedsAnAgentsOwnProcess() throws {
        let deck = try Self.code("Sources/BaneySpaces/Deck/DeckController.swift")
        let move = try XCTUnwrap(Self.between("case \"move\":", "default:\n            return .init(ok: false, error: \"usage", in: deck))
        XCTAssertTrue(move.contains("SocketPolicy.mayMove(windowPid: h.pidOf(id), startedForAgents: AgentOwned.shared.pids)"))
        XCTAssertTrue(move.contains("needs_lend"))
        XCTAssertTrue(move.range(of: "mayMove")!.lowerBound < move.range(of: "h.move(id, n)")!.lowerBound)
        XCTAssertTrue(deck.contains("AgentOwned.shared.add(app.processIdentifier)"))
        XCTAssertTrue(deck.contains("AgentOwned.shared.add(pid)"), "agent run terminals count")
    }

    func testHandsRequestsNeverRunOnTheMainThread() throws {
        let deck = try Self.code("Sources/BaneySpaces/Deck/DeckController.swift")
        let handle = try XCTUnwrap(Self.block(after: "func handle(_ r: Wire.Request)", in: deck))
        let hands = try XCTUnwrap(handle.range(of: "case .hands:"))
        XCTAssertFalse(handle[hands.upperBound...].prefix(200).contains("hands.handleWire"))
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
        XCTAssertTrue(engine.contains("queue(for: w.pid).async"))
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

    func testRefsLiveInAFolderBaneySpacesOwnsThatIsNewEveryLaunch() throws {
        let engine = try Self.code("Sources/BaneySpaces/Hands/HandsEngine.swift")
        XCTAssertTrue(engine.contains("static let stateRoot: URL = home.appendingPathComponent(UUID().uuidString"))
        XCTAssertTrue(engine.contains("setenv(\"AGENT_DESKTOP_HOME\", stateRoot.path, 1)"))
        XCTAssertTrue(engine.contains(".posixPermissions: 0o700"))
        XCTAssertTrue(engine.contains("name != \"handoff\" && name != \"shots\""), "old launches' refs are removed at start")
        let router = try Self.code("Sources/BaneySpaces/Hands/HandsRouter.swift")
        XCTAssertTrue(router.contains("HandsEngine.stateRoot.appendingPathComponent(\"snapshots/"))
    }

    func testAShotIsCheckedAfterEnumerationBeforeCaptureAndBeforePublishing() throws {
        let shot = try Self.code("Sources/BaneySpaces/Hands/WindowShot.swift")
        XCTAssertEqual(shot.components(separatedBy: "if let e = check() { return outcome.set(.failure(e)) }").count - 1, 3)
        XCTAssertEqual(shot.components(separatedBy: "if outcome.isCancelled { return }").count - 1, 3, "a capture whose caller gave up is dropped")
        XCTAssertTrue(shot.contains("outcome.cancel()"))
        let router = try Self.code("Sources/BaneySpaces/Hands/HandsRouter.swift")
        XCTAssertTrue(router.contains("WindowShot.capture(window: w.id, named: req.string(\"out\"), check: check(w))"))
    }

    func testEveryWindowOfAnAgentProcessIsInspectedOnEveryUse() throws {
        let router = try Self.code("Sources/BaneySpaces/Hands/HandsRouter.swift")
        let gate = try XCTUnwrap(Self.block(after: "private func gate(", in: router))
        XCTAssertTrue(gate.contains("inspectProblem(now)"))
        let inspect = try XCTUnwrap(Self.block(after: "private func inspectProblem(", in: router))
        XCTAssertTrue(inspect.contains("seen.panel") && inspect.contains("HandoffPath.contains(document: doc, in: Self.handoffFolder)"))
        XCTAssertTrue(inspect.contains("refused.insert(w.id)"))
        XCTAssertTrue(router.contains(".filter { inspectProblem($0.window) == nil }"), "the windows list hides them too")
    }

    func testOnlyDonovanLends() throws {
        let router = try Self.code("Sources/BaneySpaces/Hands/HandsRouter.swift")
        let dispatch = try XCTUnwrap(Self.block(after: "func handle(", in: router))
        XCTAssertFalse(dispatch.contains("\"lend\""), "no agent verb lends")
        XCTAssertTrue(dispatch.contains("HandsTools.userOnly.contains(req.verb)"))
        let cli = try Self.code("Sources/baneyspaces-cli/Agent.swift")
        let mcpCommand = try XCTUnwrap(Self.block(after: "enum MCPCommand", in: cli))
        XCTAssertFalse(mcpCommand.contains("op: .agent"), "the MCP server sends no deck op: it can't lend or return")
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
        XCTAssertTrue(launch.contains("AgentActivity.shared.markLaunch(pid: app.processIdentifier, for: 8)"))
        XCTAssertTrue(launch.contains("guard !before.contains(app.processIdentifier) else { return }"), "a launch that ran inside Donovan's copy is left alone")
        let claim = try XCTUnwrap(launch.range(of: "h.claim("))
        let press = try XCTUnwrap(launch.range(of: "newWindow(app)"))
        XCTAssertTrue(claim.lowerBound < press.lowerBound, "claimed before anything else happens")
        XCTAssertTrue(src.contains("AgentActivity.shared.markLaunch(bundle: bundle"), "marked by bundle before there is a pid")
        // Both ways of launching (with files, and without) mark the bundle before launching and claim the process
        // that launch hands back, never a launch notification: that could be Donovan opening his own copy.
        let open = try XCTUnwrap(HandsSourceTests.between("case \"open\":", "case \"lend-ask\":", in: src))
        XCTAssertFalse(open.contains("didLaunchApplicationNotification"), "no claim by bundle id")
        XCTAssertEqual(open.components(separatedBy: "finished(app)").count - 1, 2, "openApplication and open(files) both claim their own result")
        XCTAssertTrue(open.contains("claimLaunch(app)"))
        XCTAssertTrue(open.range(of: "AgentActivity.shared.markLaunch(bundle: bundle, excluding: before, for: 10)")!.lowerBound < open.range(of: "NSWorkspace.shared.openApplication")!.lowerBound, "marked first, without Donovan's running copies")
        XCTAssertTrue(open.contains("AgentActivity.shared.clearLaunch(bundle: bundle)"))
        XCTAssertFalse(open.contains("folderOnly"), "no Finder branch")
        // Never Donovan's documents: a new instance told not to restore, not a window made inside his copy.
        XCTAssertTrue(open.contains("cfg.createsNewApplicationInstance = true"))
        XCTAssertTrue(open.contains("cfg.arguments = [\"-ApplePersistenceIgnoreState\", \"YES\"]"))
        XCTAssertTrue(open.contains("AgentOpenGate.check("), "the gate is in the op itself, so the socket can't skip it")
    }

    func testEveryLaterWindowOfAnAgentProcessGoesToTheAgentWorkspaceToo() throws {
        let spaces = try HandsSourceTests.code("Sources/BaneySpaces/Spaces.swift")
        XCTAssertTrue(spaces.contains("claimed: AgentOwned.shared.pids.contains(w.pid) ? agent : nil"), "a standing rule for the life of the process")
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
        XCTAssertTrue(text.contains("restored"), "the probe fails on a window of the opened apps that isn't the handoff document")
        XCTAssertFalse(text.contains("\"Notes\""), "never Notes or any once-per-user app")
    }
}
