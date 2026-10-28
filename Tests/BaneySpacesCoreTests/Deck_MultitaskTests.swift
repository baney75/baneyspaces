import XCTest
@testable import BaneySpacesCore

final class DeckHistoryTests: XCTestCase {
    func testBackForwardSkipsClosedRowsAndNewVisitDropsForward() {
        var h = DeckHistory()
        for id in ["a", "b", "c"] { h.visit(id) }
        XCTAssertEqual(h.back(alive: ["a", "c"]), "a", "b closed, so back skips it")
        h.visit("a")
        XCTAssertEqual(h.forward(alive: ["a", "b", "c"]), "b")
        h.visit("b")
        h.visit("d")
        XCTAssertNil(h.forward(alive: ["a", "b", "c", "d"]), "a new visit after going back drops the forward rows")
        XCTAssertEqual(h.back(alive: ["a", "b", "c", "d"]), "b")
    }

    func testRevisitMovesToTheEnd() {
        var h = DeckHistory()
        for id in ["a", "b", "a"] { h.visit(id) }
        XCTAssertEqual(h.stack, ["b", "a"])
    }
}

final class DeckRankTests: XCTestCase {
    func testUsesTheLauncherMatcher() {
        XCTAssertEqual(DeckRank.rank("hel", ["shell", "Helium"]) { [$0] }.first, "Helium")
        XCTAssertEqual(DeckRank.rank("", ["b", "a"]) { [$0] }, ["b", "a"])
        XCTAssertEqual(DeckRank.rank("zzz", ["b", "a"]) { [$0] }, [])
    }
}

final class GrokTests: XCTestCase {
    func testGrokBotIsWrapped() {
        XCTAssertTrue(Catalog.wrapped(defaultBrowser: nil).contains { $0.bundleID == "com.anysphere.sand" && $0.role == .agent })
    }

    func testGrokPayloadsUseCamelCaseIDs() {
        let stop = AgentEvent.hook(["hook_event_name": "Stop", "hookEventName": "stop", "sessionId": "g1", "cwd": "/p"],
                                   agent: "grok", tty: "", app: "com.anysphere.sand", at: 1)
        XCTAssertEqual(stop?.session, "g1")
        XCTAssertEqual(stop?.state, .waiting)
        XCTAssertNil(AgentEvent.hook(["hook_event_name": "SessionEnd", "sessionId": "g1", "subagentType": "explore"], agent: "grok", tty: "", at: 1),
                     "a subagent ending isn't the session ending")
        XCTAssertEqual(AgentEvent.hook(["hook_event_name": "StopFailure", "sessionId": "g1"], agent: "grok", tty: "", at: 1)?.message,
                       "Stopped on an API error")
    }

    func testAppSessionBindsToItsWindow() {
        var a = AgentSessions()
        a.apply(AgentEvent(agent: "grok", session: "g", cwd: "/p", tty: "", app: "com.anysphere.sand", state: .working, at: 1))
        let w = Item(id: "win:9", bundleID: "com.anysphere.sand", appName: "Grok Bot", role: .agent, kind: .window, group: "win:9", title: "Grok")
        let t = Item(id: "ghostty:x", bundleID: "com.mitchellh.ghostty", appName: "Ghostty", role: .terminal, kind: .terminal, group: "g",
                     title: "zsh", directory: "/p")
        XCTAssertEqual(Array(a.resolve([t, w]).keys), ["win:9"], "a Grok Bot session isn't the Ghostty shell in the same folder")
    }

    func testAppHintSeparatesTerminalsInOneFolder() {
        var a = AgentSessions()
        a.apply(AgentEvent(agent: "claude", session: "s", cwd: "/p", tty: "", app: "com.mitchellh.ghostty", state: .working, at: 1))
        let g = Item(id: "ghostty:x", bundleID: "com.mitchellh.ghostty", appName: "Ghostty", role: .terminal, kind: .terminal, group: "g", title: "zsh", directory: "/p")
        let t = Item(id: "tab:t", bundleID: "com.apple.Terminal", appName: "Terminal", role: .terminal, kind: .terminal, group: "t", title: "zsh", directory: "/p")
        XCTAssertEqual(Array(a.resolve([t, g]).keys), ["ghostty:x"])
    }

    func testGrokAndOldGhostdeckHooksCountAsOurs() {
        XCTAssertTrue(HookSettings.isOurs(command: "'/u/.local/bin/baneyspaces' hook grok 2>/dev/null || true"))
        XCTAssertTrue(HookSettings.isOurs(command: "'/u/.local/bin/ghostdeck' hook claude"))
        XCTAssertFalse(HookSettings.isOurs(command: "python3 stop_gate.py"))
    }
}

final class CorrelationTests: XCTestCase {
    func g(_ id: String, _ title: String) -> Item {
        Item(id: id, bundleID: "com.mitchellh.ghostty", appName: "Ghostty", role: .terminal, kind: .terminal, group: "w", title: title,
             activity: Activity.of(title: title))
    }
    func ev(_ state: AgentEvent.State, at: Double) -> AgentEvent {
        AgentEvent(agent: "claude", session: "s", cwd: "/Users/me/p", tty: "/dev/ttys9", app: "com.mitchellh.ghostty", state: state, at: at)
    }

    func testGhosttyWithoutFoldersBindsByTitleOverEvents() {
        var a = AgentSessions()
        a.apply(ev(.working, at: 0))
        XCTAssertTrue(a.resolve([g("A", "◐ one"), g("B", "◓ two"), g("C", "✳ three")], now: 0.1).isEmpty, "too soon: titles haven't caught up")
        XCTAssertTrue(a.resolve([g("A", "◐ one"), g("B", "◓ two"), g("C", "✳ three")], now: 1).isEmpty, "A or B: don't guess")
        a.apply(ev(.waiting, at: 2))
        let r = a.resolve([g("A", "✳ one"), g("B", "◓ two"), g("C", "✳ three")], now: 3)
        XCTAssertEqual(Array(r.keys), ["A"], "working then waiting: only A did both")
        // Sticks while the row lives, whatever its title says next.
        a.apply(ev(.working, at: 4))
        XCTAssertEqual(a.resolve([g("A", "✳ one"), g("B", "◓ two")], now: 4.1)["A"]?.state, .working)
    }

    func testAShellNeverBindsByTitle() {
        var a = AgentSessions()
        a.apply(ev(.working, at: 0))
        XCTAssertTrue(a.resolve([g("A", "zsh"), g("B", "vim notes")], now: 1).isEmpty)
    }

    func testAFreshAgreeingSetReplacesAStaleOne() {
        var a = AgentSessions()
        a.apply(ev(.working, at: 0))
        _ = a.resolve([g("A", "◐ one"), g("B", "◓ two")], now: 1)
        // Both closed and a new tab took over: an empty intersection starts over instead of sticking at nothing.
        a.apply(ev(.waiting, at: 2))
        XCTAssertEqual(Array(a.resolve([g("C", "✳ new")], now: 3).keys), ["C"])
    }
}

/// The dock's spinner stuck on T3 Code (Donovan, 2026-10-28): every Claude session inside T3
/// reports the same app, the first to claim its one window kept it, and a turn stopped from T3
/// sends no hook.
final class SharedWindowTests: XCTestCase {
    let t3 = "com.t3tools.t3code"
    var window: Item { Item(id: "win:1", bundleID: t3, appName: "T3 Code", role: .agent, kind: .window, group: "win:1", title: "T3 Code") }
    func ev(_ session: String, _ state: AgentEvent.State, at: Double, message: String = "") -> AgentEvent {
        AgentEvent(agent: "claude", session: session, cwd: "/p/" + session, tty: "", app: t3, state: state, message: message, at: at)
    }

    func testEverySessionInTheAppReportsToItsWindow() {
        var a = AgentSessions()
        a.apply(ev("old", .working, at: 0))
        XCTAssertEqual(a.resolve([window], now: 1)["win:1"]?.state, .working)
        // The old turn was stopped from T3 (no hook); a newer session finishes.
        a.apply(ev("new", .working, at: 2000))
        a.apply(ev("new", .waiting, at: 2100))
        XCTAssertEqual(a.resolve([window], now: 2101)["win:1"]?.session, "new",
                       "a session silent past `stale` no longer holds the window")
    }

    func testFreshWorkOutranksANewerFinish() {
        var a = AgentSessions()
        a.apply(ev("a", .working, at: 10))
        a.apply(ev("b", .waiting, at: 20))
        XCTAssertEqual(a.resolve([window], now: 21)["win:1"]?.session, "a", "one still working keeps the spinner")
        a.apply(ev("c", .waiting, at: 30, message: "Claude needs your permission to use Bash"))
        XCTAssertEqual(a.resolve([window], now: 31)["win:1"]?.session, "c", "a question beats work")
    }

    func testAStaleReportOnAWindowStopsCountingAsWork() {
        let e = ev("a", .working, at: 0)
        XCTAssertEqual(AgentSessions.activity(window, e, now: 60), .working)
        XCTAssertEqual(AgentSessions.activity(window, e, now: AgentSessions.stale + 1), .shell,
                       "no badge, and not a false finish either")
    }

    func testAnIdleTitleWinsOverALateWorkingReport() {
        let idle = Item(id: "g", bundleID: "com.mitchellh.ghostty", appName: "Ghostty", role: .terminal, kind: .terminal,
                        group: "w", title: "✳ fix it", activity: .waiting)
        let e = AgentEvent(agent: "claude", session: "s", cwd: "", tty: "", app: "", state: .working, at: 0)
        XCTAssertEqual(AgentSessions.activity(idle, e, now: 1), .working, "the title may not have caught up yet")
        XCTAssertEqual(AgentSessions.activity(idle, e, now: 6), .waiting, "Esc sends no hook; Claude's title says it stopped")
        var busy = idle; busy.activity = .working
        XCTAssertEqual(AgentSessions.activity(busy, e, now: 3600), .working, "a terminal still spinning keeps working")
    }
}
