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

    func testALookedAtQuestionStopsOutrankingWork() {
        var a = AgentSessions()
        a.apply(ev("a", .working, at: 10))
        a.apply(ev("c", .waiting, at: 20, message: "Claude needs your permission to use Bash"))
        var looking = window; looking.focused = true
        XCTAssertEqual(a.resolve([looking], now: 21)["win:1"]?.session, "c")
        XCTAssertEqual(a.resolve([window], now: 22)["win:1"]?.session, "a", "you looked at the question; the work shows again")
    }

    func testAnUnansweredQuestionNeverAgesOut() {
        var a = AgentSessions()
        a.apply(ev("c", .waiting, at: 0, message: "Claude needs your permission to use Bash"))
        a.apply(ev("a", .working, at: AgentSessions.stale + 100))
        XCTAssertEqual(a.resolve([window], now: AgentSessions.stale + 101)["win:1"]?.session, "c")
    }

    func testATerminalsWindowHoldsOneSession() {
        var a = AgentSessions()
        let term = { (n: Int) in Item(id: "win:\(n)", bundleID: "com.apple.Terminal", appName: "Terminal", role: .terminal, kind: .window,
                                      group: "win:\(n)", title: "zsh") }
        a.apply(AgentEvent(agent: "claude", session: "x", cwd: "/x", tty: "", app: "com.apple.Terminal", state: .working, at: 1))
        a.apply(AgentEvent(agent: "claude", session: "y", cwd: "/y", tty: "", app: "com.apple.Terminal", state: .waiting, at: 2))
        let r = a.resolve([term(1)], now: 3)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(a.binding.count, 1, "a second session doesn't share one terminal window")
    }

    func testAStaleReportOnAWindowStopsCountingAsWork() {
        let e = ev("a", .working, at: 0)
        XCTAssertEqual(AgentSessions.activity(window, e, now: 60), .working)
        XCTAssertEqual(AgentSessions.activity(window, e, now: AgentSessions.stale + 1), .shell,
                       "no badge, and not a false finish either")
        let plain = Item(id: "g", bundleID: "com.mitchellh.ghostty", appName: "Ghostty", role: .terminal, kind: .terminal,
                         group: "w", title: "zsh", activity: .shell)
        XCTAssertEqual(AgentSessions.activity(plain, e, now: AgentSessions.stale + 1), .shell, "a title without a glyph says nothing either")
    }

    func testAnIdleTitleWinsOnlyOnceItStaysIdle() {
        let idle = Item(id: "g", bundleID: "com.mitchellh.ghostty", appName: "Ghostty", role: .terminal, kind: .terminal,
                        group: "w", title: "✳ fix it", activity: .waiting)
        let e = AgentEvent(agent: "claude", session: "s", cwd: "", tty: "", app: "", state: .working, at: 0)
        var titles = IdleTitles()
        titles.update([idle], now: 30)
        XCTAssertEqual(AgentSessions.activity(idle, e, now: 30, idleSince: titles.since("g")), .working,
                       "one idle read long after the report: the title may not have caught up")
        titles.update([idle], now: 36)
        XCTAssertEqual(titles.since("g"), 30)
        XCTAssertEqual(AgentSessions.activity(idle, e, now: 36, idleSince: titles.since("g")), .waiting,
                       "Esc sends no hook; Claude's title has said it stopped for over 5 s")
        var busy = idle; busy.activity = .working
        titles.update([busy], now: 40)
        XCTAssertNil(titles.since("g"))
        XCTAssertEqual(AgentSessions.activity(busy, e, now: 3600), .working, "a terminal still spinning keeps working")
    }

    func testAnIncompatibleTerminalIsNeverPicked() {
        var a = AgentSessions()
        a.apply(AgentEvent(agent: "claude", session: "s", cwd: "/elsewhere", tty: "", app: "com.mitchellh.ghostty", state: .working, at: 0))
        let t = Item(id: "g", bundleID: "com.mitchellh.ghostty", appName: "Ghostty", role: .terminal, kind: .terminal, group: "w",
                     title: "◐ x", directory: "/p", activity: .working)
        XCTAssertTrue(a.resolve([t], now: 1).isEmpty)
        XCTAssertTrue(a.resolve([t], now: 2).isEmpty, "the pick rule and the keep rule agree")
    }

    func testWorkThatWentStaleThenFinishedIsAFinish() {
        let e = ev("a", .working, at: 0)
        var att = Attention()
        att.update([("win:1", AgentSessions.forAttention(AgentSessions.activity(window, e, now: 10), e))], focused: nil)
        att.update([("win:1", AgentSessions.forAttention(AgentSessions.activity(window, e, now: AgentSessions.stale + 1), e))], focused: nil)
        let stop = ev("a", .waiting, at: AgentSessions.stale + 60)
        att.update([("win:1", AgentSessions.forAttention(AgentSessions.activity(window, stop, now: AgentSessions.stale + 61), stop))], focused: nil)
        XCTAssertEqual(att.unseen, ["win:1"])
    }

    func testAQuestionSeenOnASharedWindowStaysSeen() {
        var q = AnsweredQuestions()
        let c = ev("c", .waiting, at: 1, message: "c?"), d = ev("d", .waiting, at: 2, message: "d?")
        _ = q.notice(for: "win:1", c, focused: true)
        _ = q.notice(for: "win:1", d, focused: true)
        XCTAssertEqual(q.notice(for: "win:1", c, focused: false), "", "seeing d doesn't bring c's question back")
        XCTAssertEqual(q.notice(for: "win:1", d, focused: false), "")
    }

    func testAnotherSessionTakingTheWindowIsNotAFinish() {
        var a = AgentSessions(), shown = ShownSessions(), att = Attention()
        func merge(_ now: Double) {
            let e = a.resolve([window], now: now)["win:1"]
            let act = e.map { AgentSessions.activity(window, $0, now: now) } ?? .shell
            att.update([("win:1", shown.attention("win:1", e, AgentSessions.forAttention(act, e)))], focused: nil)
        }
        a.apply(ev("b", .waiting, at: 5))
        a.apply(ev("a", .working, at: 10))
        merge(11)
        merge(AgentSessions.stale + 20)
        XCTAssertEqual(a.resolve([window], now: AgentSessions.stale + 20)["win:1"]?.session, "a", "a's stale report is still the latest")
        a.apply(ev("c", .waiting, at: AgentSessions.stale + 30))
        merge(AgentSessions.stale + 31)
        XCTAssertEqual(att.unseen, [], "the window turning to c, which stopped on its own, isn't a finish anyone saw")
        a.apply(ev("c", .working, at: AgentSessions.stale + 40)); merge(AgentSessions.stale + 41)
        a.apply(ev("c", .waiting, at: AgentSessions.stale + 50)); merge(AgentSessions.stale + 51)
        XCTAssertEqual(att.unseen, ["win:1"], "c working then stopping is")
    }

    func testAStopOnlyTheTitleSawIsNotAFinish() {
        let late = AgentEvent(agent: "claude", session: "s", cwd: "", tty: "", app: "", state: .working, at: 0)
        XCTAssertEqual(AgentSessions.forAttention(.waiting, late), .shell, "a background agent's late hook won't flag the row again")
        XCTAssertEqual(AgentSessions.forAttention(.waiting, AgentEvent(agent: "claude", session: "s", cwd: "", tty: "", app: "", state: .waiting, at: 0)), .waiting)
    }

    func testOnlyAnAgentAppsWindowIsShared() {
        var a = AgentSessions()
        let other = Item(id: "win:7", bundleID: "com.example.Notes", appName: "Notes", role: .other, kind: .window, group: "win:7",
                         title: "Notes", focused: true)
        a.apply(AgentEvent(agent: "claude", session: "x", cwd: "", tty: "", app: "com.example.Notes", state: .working, at: 1))
        a.apply(AgentEvent(agent: "claude", session: "y", cwd: "", tty: "", app: "com.example.Notes", state: .waiting, at: 2))
        _ = a.resolve([other], now: 3)
        XCTAssertEqual(a.binding.count, 1, "a plain app's window holds one session")
    }

    func testExpireSaysWhetherItForgot() {
        var a = AgentSessions()
        a.apply(ev("a", .working, at: 0))
        XCTAssertFalse(a.expire(now: 10))
        XCTAssertTrue(a.expire(now: 7 * 3600))
    }
}
