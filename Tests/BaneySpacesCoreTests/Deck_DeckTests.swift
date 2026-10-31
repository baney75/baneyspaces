import CoreGraphics
import XCTest
@testable import BaneySpacesCore

final class CatalogTests: XCTestCase {
    func testWrapsTerminalsAgentsAndOnlyTheDefaultBrowser() {
        let ids = Set(Catalog.wrapped(defaultBrowser: "net.imput.helium").map(\.bundleID))
        XCTAssertTrue(ids.isSuperset(of: ["com.mitchellh.ghostty", "com.apple.Terminal", "com.googlecode.iterm2",
                                          "com.anthropic.claudefordesktop", "com.openai.codex", "com.t3tools.t3code", "net.imput.helium"]))
        XCTAssertFalse(ids.contains("com.google.Chrome"), "a second browser shouldn't crowd the list")
    }

    func testUnknownDefaultBrowserStillJoins() {
        let specs = Catalog.wrapped(defaultBrowser: "org.example.Browser")
        let b = specs.first { $0.bundleID == "org.example.Browser" }
        XCTAssertEqual(b?.role, .browser)
        XCTAssertEqual(b?.adapter, .windows)
    }

    func testConfigAddsAndExcludes() {
        let extra = AppSpec(bundleID: "com.example.Notes", name: "Notes", role: .other, adapter: .windows)
        let ids = Catalog.wrapped(defaultBrowser: nil, extra: [extra], excluded: ["com.apple.Terminal"]).map(\.bundleID)
        XCTAssertTrue(ids.contains("com.example.Notes"))
        XCTAssertFalse(ids.contains("com.apple.Terminal"))
    }
}

final class AgentEventTests: XCTestCase {
    func testClaudeHookEvents() {
        func ev(_ name: String, _ extra: [String: Any] = [:]) -> AgentEvent? {
            var j: [String: Any] = ["hook_event_name": name, "session_id": "s1", "cwd": "/p"]
            j.merge(extra) { $1 }
            return AgentEvent.claude(j, tty: "/dev/ttys001", at: 1)
        }
        XCTAssertEqual(ev("UserPromptSubmit")?.state, .working)
        XCTAssertEqual(ev("PostToolUse")?.state, .working)
        XCTAssertEqual(ev("Stop")?.state, .waiting)
        XCTAssertEqual(ev("SessionStart")?.state, .idle)
        XCTAssertEqual(ev("SessionEnd")?.state, .end)
        XCTAssertEqual(ev("Notification", ["message": "Claude needs your permission to use Bash"])?.message,
                       "Claude needs your permission to use Bash")
        XCTAssertEqual(ev("Stop", ["message": "ignored"])?.message, "")
        // A minute after it finishes, Claude says it's waiting for input: nothing new, so no event,
        // which would otherwise wipe a permission question it's reminding you of (r1 F2).
        XCTAssertNil(ev("Notification", ["message": "Claude is waiting for your input", "notification_type": "idle_prompt"]))
        XCTAssertNil(ev("Notification", ["message": "Claude is waiting for your input"]))
        XCTAssertNil(ev("Notification", ["message": "Signed in", "notification_type": "auth_success"]))
        XCTAssertEqual(ev("Notification", ["message": "Claude needs your permission to use Bash", "notification_type": "permission_prompt"])?.state, .waiting)
        XCTAssertEqual(ev("Notification", ["message": "Pick one", "notification_type": "elicitation_dialog"])?.message, "Pick one")
        XCTAssertEqual(ev("StopFailure")?.message, AgentEvent.failedMessage)
        XCTAssertNil(ev("PreCompact"))
        XCTAssertNil(AgentEvent.claude(["session_id": "x"], tty: "", at: 0))
    }
}

final class AgentSessionsTests: XCTestCase {
    func term(_ id: String, dir: String, tty: String = "", title: String = "x") -> Item {
        Item(id: id, bundleID: "b", appName: "A", role: .terminal, kind: .terminal, group: "g", title: title, directory: dir, tty: tty,
             activity: Activity.of(title: title))
    }
    func event(_ s: String, cwd: String, tty: String = "", state: AgentEvent.State = .working, at: Double = 1) -> AgentEvent {
        AgentEvent(agent: "claude", session: s, cwd: cwd, tty: tty, state: state, at: at)
    }

    func testTTYIsExact() {
        var a = AgentSessions()
        a.apply(event("s", cwd: "/p", tty: "/dev/ttys2"))
        let r = a.resolve([term("one", dir: "/p", tty: "/dev/ttys1"), term("two", dir: "/p", tty: "/dev/ttys2")])
        XCTAssertEqual(Array(r.keys), ["two"])
    }

    func testOnlyTerminalInTheFolderBinds() {
        var a = AgentSessions()
        a.apply(event("s", cwd: "/p"))
        XCTAssertEqual(Array(a.resolve([term("one", dir: "/p"), term("two", dir: "/q")]).keys), ["one"])
    }

    func testSharedFolderPicksTheTitleThatAgrees() {
        var a = AgentSessions()
        a.apply(event("s", cwd: "/p", state: .working))
        let r = a.resolve([term("one", dir: "/p", title: "✳ idle claude"), term("two", dir: "/p", title: "◐ busy claude")])
        XCTAssertEqual(Array(r.keys), ["two"])
    }

    func testAmbiguousStaysUnboundAndBindingSticks() {
        var a = AgentSessions()
        a.apply(event("s", cwd: "/p"))
        let both = [term("one", dir: "/p"), term("two", dir: "/p")]
        XCTAssertTrue(a.resolve(both).isEmpty, "two shells in one folder: don't guess")
        var b = AgentSessions()
        b.apply(event("s", cwd: "/p"))
        _ = b.resolve([term("one", dir: "/p")])
        // A second terminal opens in the same folder: the session stays where it was.
        b.apply(event("s", cwd: "/p", state: .waiting, at: 2))
        XCTAssertEqual(b.resolve(both)["one"]?.state, .waiting)
    }

    func testTwoSessionsDontShareARow() {
        var a = AgentSessions()
        a.apply(event("s1", cwd: "/p", at: 2))
        a.apply(event("s2", cwd: "/p", at: 1))
        let r = a.resolve([term("one", dir: "/p")])
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r["one"]?.session, "s1", "the most recent session wins the only row")
    }

    func testEndAndExpiry() {
        var a = AgentSessions()
        a.apply(event("s", cwd: "/p"))
        a.apply(event("s", cwd: "/p", state: .end))
        XCTAssertTrue(a.sessions.isEmpty)
        a.apply(event("old", cwd: "/p", at: 0))
        a.expire(now: 7 * 3600)
        XCTAssertTrue(a.sessions.isEmpty)
    }
}

final class AttentionRowsTests: XCTestCase {
    func testWorkingToWaitingWhileAwayIsUnseen() {
        var a = Attention()
        a.update([("x", .working), ("y", .working)], focused: nil)
        a.update([("x", .waiting), ("y", .waiting)], focused: "y")
        XCTAssertEqual(a.unseen, ["x"])
        a.update([("x", .working), ("y", .waiting)], focused: nil)
        XCTAssertEqual(a.unseen, [], "started again: no longer waiting on you")
    }

    func testFlagSticksUntilLookedAt() {
        var a = Attention()
        a.update([("x", .shell)], focused: nil)
        a.flag("x")
        a.update([("x", .shell)], focused: nil)
        XCTAssertEqual(a.unseen, ["x"])
        a.update([("x", .shell)], focused: "x")
        XCTAssertEqual(a.unseen, [])
    }
}

final class WindowMatchTests: XCTestCase {
    func testPairsByTitleThenInOrder() {
        let m = WindowMatch.pair(scripted: [("a", "same"), ("b", "same"), ("c", "unique")],
                                 native: [(10, "unique"), (11, "same"), (12, "same")])
        XCTAssertEqual(m, ["a": 11, "b": 12, "c": 10])
    }

    func testChromiumSuffixesStillPair() {
        let m = WindowMatch.pair(scripted: [("1", "Ukraine drone bomber game - Claude"), ("2", "Customize - Claude")],
                                 native: [(10, "Ukraine drone bomber game - Claude - High memory usage - 1.0 GB - Helium"),
                                          (11, "Customize - Claude - Part of group Claude - Helium")])
        XCTAssertEqual(m, ["1": 10, "2": 11])
    }

    func testOneLeftoverEachPairs() {
        XCTAssertEqual(WindowMatch.pair(scripted: [("a", "◐ busy")], native: [(10, "◓ busy")]), ["a": 10])
    }
}

final class ScriptedSnapshotTests: XCTestCase {
    let fs = String(Snapshot.fieldSeparator), rs = String(Snapshot.recordSeparator)

    func testBrowserTabsAndPrivateWindows() {
        let raw = [["W", "1", "Docs", "2", "normal"], ["T", "1", "11", "1", "GitHub", "https://github.com/x"],
                   ["T", "1", "12", "2", "Docs", "https://docs.example.com/a"], ["W", "2", "Secret", "1", "incognito"]]
            .map { $0.joined(separator: fs) }.joined(separator: rs)
        let s = ScriptedSnapshot.parse(raw)
        XCTAssertEqual(s.windows.count, 2)
        XCTAssertTrue(s.windows[1].isPrivate)
        XCTAssertEqual(s.tabs.map(\.selected), [false, true])
        let spec = AppSpec(bundleID: "net.imput.helium", name: "Helium", role: .browser, adapter: .chromium)
        let items = Build.scripted(spec, s, numbers: ["1": 100, "2": 200], front: true, frontWindowNumber: 100)
        XCTAssertEqual(items.map(\.title), ["GitHub", "Docs", "Private window"])
        XCTAssertEqual(items.map(\.focused), [false, true, false])
        XCTAssertEqual(items[0].detail, "github.com/x")
    }

    func testTerminalSessionsCarryTheirTTY() {
        let raw = ["W\(fs)7\(fs)zsh", "S\(fs)7\(fs)/dev/ttys003\(fs)1\(fs)zsh\(fs)/dev/ttys003\(fs)true"].joined(separator: rs)
        let s = ScriptedSnapshot.parse(raw)
        let spec = AppSpec(bundleID: "com.apple.Terminal", name: "Terminal", role: .terminal, adapter: .terminalApp)
        let items = Build.scripted(spec, s, numbers: ["7": 5], front: true, frontWindowNumber: 5)
        XCTAssertEqual(items.first?.tty, "/dev/ttys003")
        XCTAssertEqual(items.first?.detail, "ttys003")
        XCTAssertEqual(items.first?.focused, true)
    }
}

final class BuildTests: XCTestCase {
    func testGhosttySplitsNestUnderTheirTab() {
        let fs = String(Snapshot.fieldSeparator), rs = String(Snapshot.recordSeparator)
        let rows = [["W", "w1", "◐ two"], ["w1", "t1", "1", "true", "false", "a", "one", "/x"],
                    ["w1", "t1", "1", "true", "true", "b", "◐ two", "/x"], ["w1", "t2", "2", "false", "true", "c", "three", "/y"]]
        let raw = "w1" + rs + rows.map { $0.joined(separator: fs) }.joined(separator: rs)
        let snap = Snapshot.parse(raw)
        XCTAssertEqual(snap.windowTitles.map(\.title), ["◐ two"])
        let spec = Catalog.known[0]
        let items = Build.ghostty(spec, snap, numbers: ["w1": 42], front: true)
        XCTAssertEqual(items.map(\.nested), [false, true, false])
        XCTAssertEqual(items.map(\.windowNumber), [42, 42, 42])
        XCTAssertEqual(items.first { $0.focused }?.id, "ghostty:b")
        XCTAssertEqual(Build.ghostty(spec, snap, numbers: [:], front: false).filter(\.focused).count, 0)
    }
}

final class HookSettingsTests: XCTestCase {
    let mine: [String: Any] = [
        "model": "opus",
        "hooks": [
            "Stop": [["hooks": [["type": "command", "command": "python3 stop_gate.py"]]]],
            "PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "python3 bash_guard.py"]]]],
        ],
    ]

    func testInstallKeepsEveryOtherHookAndIsIdempotent() {
        let cmd = "'/Users/me/.local/bin/ghostdeck' hook claude 2>/dev/null || true"
        let once = HookSettings.adding(mine, command: cmd)
        let twice = HookSettings.adding(once, command: cmd)
        XCTAssertEqual(HookSettings.installed(twice), HookSettings.events)
        let stop = (twice["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
        XCTAssertEqual(stop.count, 2, "the user's Stop hook plus exactly one of ours")
        XCTAssertEqual(((stop[0]["hooks"] as! [[String: Any]])[0]["command"] as! String), "python3 stop_gate.py")
        XCTAssertEqual(twice["model"] as? String, "opus")
    }

    func testUninstallRestoresTheOriginal() {
        let back = HookSettings.removing(HookSettings.adding(mine, command: "'/x/ghostdeck' hook claude 2>/dev/null || true"))
        XCTAssertEqual(NSDictionary(dictionary: back), NSDictionary(dictionary: mine))
        XCTAssertEqual(HookSettings.installed(back), [])
    }
}

final class WireTests: XCTestCase {
    func testRequestRoundTrip() throws {
        let ev = AgentEvent(agent: "claude", session: "s", cwd: "/p", tty: "/dev/ttys1", state: .waiting, message: "m", at: 3)
        let r = Wire.Request(op: .event, event: ev)
        XCTAssertEqual(try JSONDecoder().decode(Wire.Request.self, from: JSONEncoder().encode(r)), r)
    }

    func testCallWithNoServerReturnsNilQuickly() {
        let start = Date()
        XCTAssertNil(Wire.call(Wire.Request(op: .ping), timeout: 0.3, path: NSTemporaryDirectory() + "no-such-ghostdeck.sock"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }
}

final class ItemCodingTests: XCTestCase {
    func testReplyWithItemsRoundTrips() throws {
        var i = Item(id: "ghostty:a", bundleID: "b", appName: "Ghostty", role: .terminal, kind: .terminal, windowNumber: 4, group: "g", title: "◐ x")
        i.workspace = 3
        i.activity = .working
        let r = Wire.Reply(ok: true, items: [i])
        XCTAssertEqual(try JSONDecoder().decode(Wire.Reply.self, from: JSONEncoder().encode(r)), r)
    }
}

final class AnsweredQuestionsTests: XCTestCase {
    private func ev(_ state: AgentEvent.State, _ message: String, at: Double) -> AgentEvent {
        AgentEvent(agent: "claude", session: "s", cwd: "/p", tty: "", state: state, message: message, at: at)
    }

    func testAQuestionShowsUntilYouLookAtItThenStaysGone() {
        var a = AnsweredQuestions()
        let ask = ev(.waiting, "Claude needs your permission to use Bash", at: 10)
        XCTAssertEqual(a.notice(for: "t1", ask, focused: false), ask.message)
        XCTAssertEqual(a.notice(for: "t1", ask, focused: true), "")
        // You looked and left without answering (or pressed Esc, which sends no hook): still gone.
        XCTAssertEqual(a.notice(for: "t1", ask, focused: false), "")
        // A new question asks again.
        let next = ev(.waiting, "Claude needs your permission to use Edit", at: 20)
        XCTAssertEqual(a.notice(for: "t1", next, focused: false), next.message)
        XCTAssertEqual(a.notice(for: "t1", ev(.working, "", at: 30), focused: false), "")
    }

    func testForgetsRowsThatAreGone() {
        var a = AnsweredQuestions()
        let ask = ev(.waiting, "?", at: 1)
        _ = a.notice(for: "t1", ask, focused: true)
        a.keep([])
        XCTAssertEqual(a.notice(for: "t1", ask, focused: false), "?")
    }

    func testANewTerminalOpensOnlyWhereAFrontTerminalWas() {
        func row(_ id: String, app: String, kind: Item.Kind, dir: String, focused: Bool) -> Item {
            Item(id: id, bundleID: app, appName: app, role: kind == .terminal ? .terminal : .browser, kind: kind,
                 group: "g", title: id, directory: dir, focused: focused)
        }
        let ghostty = "com.mitchellh.ghostty", browser = "com.example.browser"
        let items = [row("t1", app: ghostty, kind: .terminal, dir: "/work", focused: true),
                     row("tab", app: browser, kind: .tab, dir: "/elsewhere", focused: true)]
        XCTAssertEqual(Item.workingFolder(items, front: ghostty), "/work")
        // The browser in front: its focused tab isn't a place to work, and Ghostty's isn't in front.
        XCTAssertNil(Item.workingFolder(items, front: browser))
        XCTAssertNil(Item.workingFolder(items, front: nil))
        XCTAssertNil(Item.workingFolder([row("t2", app: ghostty, kind: .terminal, dir: "", focused: true)], front: ghostty))
    }
}
