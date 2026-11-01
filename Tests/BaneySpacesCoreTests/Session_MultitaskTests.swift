import XCTest
@testable import BaneySpacesCore

final class SessionRankTests: XCTestCase {
    func testUsesTheLauncherMatcher() {
        XCTAssertEqual(SessionRank.rank("hel", ["shell", "Helium"]) { [$0] }.first, "Helium")
        XCTAssertEqual(SessionRank.rank("", ["b", "a"]) { [$0] }, ["b", "a"])
        XCTAssertEqual(SessionRank.rank("zzz", ["b", "a"]) { [$0] }, [])
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
    func ev(_ session: String, _ state: AgentEvent.State, at: Double, message: String = "", started: Bool = false) -> AgentEvent {
        AgentEvent(agent: "claude", session: session, cwd: "/p/" + session, tty: "", app: t3, state: state, message: message, at: at, started: started)
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

    /// The merge Engine runs for a shared window: resolve, take the activity, feed Attention.
    private func mergeRow(_ a: inout AgentSessions, _ shown: inout ShownSessions, _ att: inout Attention, _ rows: [Item], now: Double) {
        let bound = a.resolve(rows, now: now)
        att.update(rows.map { r in
            let e = bound[r.id]
            let act = e.map { AgentSessions.activity(r, $0, now: now) } ?? r.activity
            return (r.id, shown.attention(r.id, e, AgentSessions.forAttention(act, e)))
        }, focused: nil)
    }

    func testShowingAnIdleSessionAfterAStaleOneIsNotAFinish() {
        var a = AgentSessions(), shown = ShownSessions(), att = Attention()
        a.apply(ev("a", .working, at: 10))
        mergeRow(&a, &shown, &att, [window], now: 11)
        mergeRow(&a, &shown, &att, [window], now: AgentSessions.stale + 20)
        XCTAssertEqual(a.resolve([window], now: AgentSessions.stale + 20)["win:1"]?.session, "a")
        a.apply(ev("b", .idle, at: AgentSessions.stale + 30))
        mergeRow(&a, &shown, &att, [window], now: AgentSessions.stale + 31)
        XCTAssertEqual(a.resolve([window], now: AgentSessions.stale + 31)["win:1"]?.session, "b", "the stale one gave way")
        XCTAssertEqual(att.unseen, [], "a session switch alone never flags a finish")
        mergeRow(&a, &shown, &att, [window], now: AgentSessions.stale + 40)
        XCTAssertEqual(att.unseen, [])
    }

    func testTheSameSessionStoppingIsStillAFinish() {
        var a = AgentSessions(), shown = ShownSessions(), att = Attention()
        a.apply(ev("a", .working, at: 10))
        mergeRow(&a, &shown, &att, [window], now: 11)
        a.apply(ev("a", .waiting, at: 20))
        mergeRow(&a, &shown, &att, [window], now: 21)
        XCTAssertEqual(att.unseen, ["win:1"])
    }

    func testASessionTakingTheWindowWhileWorkingStillFinishesLater() {
        var a = AgentSessions(), shown = ShownSessions(), att = Attention()
        a.apply(ev("a", .working, at: 10))
        mergeRow(&a, &shown, &att, [window], now: 11)
        a.apply(ev("b", .working, at: 20))
        mergeRow(&a, &shown, &att, [window], now: 21)
        a.apply(ev("b", .waiting, at: 22))
        mergeRow(&a, &shown, &att, [window], now: 23)
        XCTAssertEqual(a.resolve([window], now: 23)["win:1"]?.session, "a", "a is still fresh work")
        // b is no longer the one shown, so a is: the row is still working. Stop a too.
        a.apply(ev("a", .waiting, at: 24))
        mergeRow(&a, &shown, &att, [window], now: 25)
        XCTAssertEqual(att.unseen, ["win:1"])
    }

    func testASessionBindsToTheOnlyWindowOfItsApp() {
        var a = AgentSessions()
        a.apply(ev("a", .working, at: 1))
        var only = window; only.focused = true
        XCTAssertEqual(a.resolve([only], now: 2)["win:1"]?.session, "a")
        XCTAssertEqual(a.binding["claude:a"], "win:1", "one window: the binding stays, as before")
    }

    func testASessionIsNotPinnedToTheWindowThatWasFocusedWhenItFirstReported() {
        var a = AgentSessions()
        func win(_ n: Int, focused: Bool) -> Item {
            Item(id: "win:\(n)", bundleID: t3, appName: "T3 Code", role: .agent, kind: .window, group: "win:\(n)", title: "T3 Code", focused: focused)
        }
        a.apply(ev("a", .working, at: 1))
        XCTAssertEqual(Array(a.resolve([win(1, focused: true), win(2, focused: false)], now: 2).keys), ["win:1"])
        XCTAssertNil(a.binding["claude:a"], "focus among several windows isn't evidence enough to bind")
        XCTAssertEqual(Array(a.resolve([win(1, focused: false), win(2, focused: true)], now: 3).keys), ["win:1"],
                       "no new report: focus moving doesn't move it")
        a.apply(ev("a", .working, at: 3.5, started: true))
        XCTAssertEqual(Array(a.resolve([win(1, focused: false), win(2, focused: true)], now: 4).keys), ["win:2"],
                       "its next report lands on the window in front")
        XCTAssertEqual(Array(a.resolve([win(1, focused: false), win(2, focused: false)], now: 4.5).keys), ["win:2"],
                       "with none in front it stays where it last showed instead of vanishing")
        XCTAssertEqual(a.resolve([win(1, focused: false)], now: 5)["win:1"]?.session, "a", "the other closed: now the app's only window")
        XCTAssertEqual(a.binding["claude:a"], "win:1")
    }

    private func win(_ n: Int, focused: Bool) -> Item {
        Item(id: "win:\(n)", bundleID: t3, appName: "T3 Code", role: .agent, kind: .window, group: "win:\(n)", title: "T3 Code", focused: focused)
    }
    private func rows(_ a: inout AgentSessions, _ items: [Item], now: Double) -> [String] {
        a.resolve(items, now: now).keys.sorted()
    }

    func testAQuestionOnAWindowItFollowedFocusToIsNotAnswered() {
        var a = AgentSessions()
        a.apply(ev("q", .waiting, at: 1, message: "Claude needs your permission to use Bash"))
        a.apply(ev("w", .working, at: 0))
        XCTAssertEqual(a.resolve([win(1, focused: true), win(2, focused: false)], now: 2)["win:1"]?.session, "q")
        XCTAssertEqual(a.followed, ["win:1"], "focus put it there; nobody chose it")
        // Had the question counted as seen, work would outrank it now.
        XCTAssertEqual(a.resolve([win(1, focused: true), win(2, focused: false)], now: 3)["win:1"]?.session, "q")
        // The only window of the app is a real binding, so looking at it does answer.
        var b = AgentSessions()
        b.apply(ev("q", .waiting, at: 1, message: "?")); b.apply(ev("w", .working, at: 0))
        _ = b.resolve([win(1, focused: true)], now: 2)
        XCTAssertEqual(b.followed, [])
        XCTAssertEqual(b.resolve([win(1, focused: false)], now: 3)["win:1"]?.session, "w", "looked at, so work shows again")
    }

    func testABindingFromOneWindowIsDroppedWhenASecondOpens() {
        var a = AgentSessions()
        a.apply(ev("a", .working, at: 1))
        _ = a.resolve([win(1, focused: true)], now: 2)
        XCTAssertEqual(a.binding["claude:a"], "win:1")
        XCTAssertEqual(rows(&a, [win(1, focused: false), win(2, focused: true)], now: 3), ["win:1"],
                       "a second window opened and took focus; the session hasn't reported again, so it stays")
        XCTAssertNil(a.binding["claude:a"])
        a.apply(ev("a", .working, at: 4, started: true))
        XCTAssertEqual(rows(&a, [win(1, focused: false), win(2, focused: true)], now: 5), ["win:2"], "its next work report follows focus")
    }

    func testAStopOrQuestionDoesNotMoveASessionToTheWindowInFront() {
        var a = AgentSessions()
        a.apply(ev("a", .working, at: 1))
        XCTAssertEqual(rows(&a, [win(1, focused: true), win(2, focused: false)], now: 2), ["win:1"])
        a.apply(ev("a", .waiting, at: 3))
        XCTAssertEqual(rows(&a, [win(1, focused: false), win(2, focused: true)], now: 4), ["win:1"], "a stop from another window's session stays put")
        a.apply(ev("a", .waiting, at: 5, message: "Claude needs your permission to use Bash"))
        XCTAssertEqual(rows(&a, [win(1, focused: false), win(2, focused: true)], now: 6), ["win:1"], "so does a question")
        a.apply(ev("a", .working, at: 7, started: true))
        XCTAssertEqual(rows(&a, [win(1, focused: false), win(2, focused: true)], now: 8), ["win:2"], "work started from the window in front moves it")
    }

    func testASessionThatStayedOnItsWindowCountsAsLookedAt() {
        var a = AgentSessions()
        a.apply(ev("a", .working, at: 1))
        _ = a.resolve([win(1, focused: true)], now: 2)
        XCTAssertEqual(a.binding["claude:a"], "win:1", "the app's only window: a real binding")
        a.apply(ev("a", .waiting, at: 3, message: "Claude needs your permission to use Bash"))
        a.apply(ev("w", .working, at: 0))
        XCTAssertEqual(a.resolve([win(1, focused: true), win(2, focused: false)], now: 4)["win:1"]?.session, "a")
        XCTAssertEqual(a.followed, [], "it was already there; focus didn't put it there")
        XCTAssertEqual(a.resolve([win(1, focused: false), win(2, focused: false)], now: 5)["win:1"]?.session, "w",
                       "you looked at the question, so work shows again")
    }

    func testAFollowingSessionStaysUntilItReportsAgain() {
        var a = AgentSessions()
        a.apply(ev("a", .working, at: 1))
        XCTAssertEqual(rows(&a, [win(1, focused: true), win(2, focused: false)], now: 2), ["win:1"])
        XCTAssertEqual(a.resolve([win(1, focused: false), win(2, focused: true)], now: 3).keys.sorted(), ["win:1"],
                       "focus moved, the session didn't report: it stays")
        a.apply(ev("a", .working, at: 4, started: true))
        XCTAssertEqual(a.resolve([win(1, focused: false), win(2, focused: true)], now: 5).keys.sorted(), ["win:2"], "a new report follows focus")
    }

    func testAQuestionOnASessionFocusPlacedStaysUnansweredAcrossResolves() {
        var a = AgentSessions()
        a.apply(ev("q", .waiting, at: 1, message: "Claude needs your permission to use Bash"))
        a.apply(ev("w", .working, at: 0))
        let two = [win(1, focused: true), win(2, focused: false)]
        XCTAssertEqual(a.resolve(two, now: 2)["win:1"]?.session, "q")
        XCTAssertEqual(a.resolve(two, now: 3)["win:1"]?.session, "q", "no new report, window in front: still focus's placement")
        XCTAssertEqual(a.followed, ["win:1"])
        XCTAssertEqual(a.resolve(two, now: 4)["win:1"]?.session, "q", "its question wasn't marked answered by being in front")
    }

    func testOnlyAPromptSubmitMovesASessionByFocus() throws {
        func hook(_ name: String, at: Double) throws -> AgentEvent {
            let e = AgentEvent.hook(["hook_event_name": name, "session_id": "a", "cwd": "/p/a"], agent: "claude", tty: "", app: t3, at: at)
            return try XCTUnwrap(e)
        }
        XCTAssertTrue(try hook("UserPromptSubmit", at: 1).started)
        XCTAssertFalse(try hook("PostToolUse", at: 1).started)
        XCTAssertFalse(try hook("PreToolUse", at: 1).started)
        var a = AgentSessions()
        a.apply(try hook("UserPromptSubmit", at: 1))
        XCTAssertEqual(rows(&a, [win(1, focused: true), win(2, focused: false)], now: 2), ["win:1"])
        a.apply(try hook("PostToolUse", at: 3))
        XCTAssertEqual(rows(&a, [win(1, focused: false), win(2, focused: true)], now: 4), ["win:1"], "a tool call isn't typing in the window in front")
        a.apply(try hook("UserPromptSubmit", at: 5))
        XCTAssertEqual(rows(&a, [win(1, focused: false), win(2, focused: true)], now: 6), ["win:2"])
    }

    func testAReportFromBeforeStartedExistedStillDecodes() throws {
        let old = #"{"agent":"claude","session":"s","cwd":"/p","tty":"","app":"","state":"working","message":"","at":1}"#
        let e = try JSONDecoder().decode(AgentEvent.self, from: Data(old.utf8))
        XCTAssertFalse(e.started)
        let round = try JSONDecoder().decode(AgentEvent.self, from: JSONEncoder().encode(ev("a", .working, at: 2, started: true)))
        XCTAssertTrue(round.started)
    }

    func testAPromptStaysPendingThroughALaterToolCall() {
        var a = AgentSessions()
        a.apply(ev("a", .working, at: 1))
        XCTAssertEqual(rows(&a, [win(1, focused: true), win(2, focused: false)], now: 2), ["win:1"])
        a.apply(ev("a", .working, at: 3, started: true))
        a.apply(ev("a", .working, at: 3.2))   // PostToolUse lands before anything resolves
        XCTAssertEqual(rows(&a, [win(1, focused: false), win(2, focused: true)], now: 3.3), ["win:2"], "the prompt still moves it")
        a.apply(ev("a", .working, at: 4))
        XCTAssertEqual(rows(&a, [win(1, focused: true), win(2, focused: false)], now: 4.1), ["win:2"], "and is used up once it has")
    }

    func testAPromptSubmittedWithItsWindowInFrontIsEvidenceNotFocusLuck() {
        var a = AgentSessions()
        a.apply(ev("a", .working, at: 1, started: true))
        XCTAssertEqual(rows(&a, [win(1, focused: true), win(2, focused: false)], now: 2), ["win:1"])
        XCTAssertEqual(a.followed, [], "you typed the prompt there")
        var b = AgentSessions()
        b.apply(ev("a", .working, at: 1))
        XCTAssertEqual(rows(&b, [win(1, focused: true), win(2, focused: false)], now: 2), ["win:1"])
        XCTAssertEqual(b.followed, ["win:1"], "without a prompt, focus is all there is")
    }

    func testAPromptWithNoWindowInFrontWaitsForFocus() {
        var a = AgentSessions()
        a.apply(ev("a", .working, at: 1))
        XCTAssertEqual(rows(&a, [win(1, focused: true), win(2, focused: false)], now: 2), ["win:1"])
        a.apply(ev("a", .working, at: 3, started: true))
        XCTAssertEqual(rows(&a, [win(1, focused: false), win(2, focused: false)], now: 4), ["win:1"], "no focus: it stays")
        XCTAssertEqual(rows(&a, [win(1, focused: false), win(2, focused: true)], now: 5), ["win:2"], "the prompt wasn't used up")
    }

    func testAPromptWhenASecondWindowOpensWaitsForFocusToo() {
        var a = AgentSessions()
        a.apply(ev("a", .working, at: 1))
        _ = a.resolve([win(1, focused: true)], now: 2)
        XCTAssertEqual(a.binding["claude:a"], "win:1")
        a.apply(ev("a", .working, at: 3, started: true))
        XCTAssertEqual(rows(&a, [win(1, focused: false), win(2, focused: false)], now: 4), ["win:1"])
        XCTAssertEqual(rows(&a, [win(1, focused: false), win(2, focused: true)], now: 5), ["win:2"])
    }

    func testAnOldPromptDoesNotMoveASessionWhenFocusChangesLater() {
        var a = AgentSessions()
        a.apply(ev("a", .working, at: 1))
        XCTAssertEqual(rows(&a, [win(1, focused: true), win(2, focused: false)], now: 2), ["win:1"])
        a.apply(ev("a", .working, at: 3, started: true))
        // No window in front for a while, then you click the other one, long after the prompt.
        XCTAssertEqual(rows(&a, [win(1, focused: false), win(2, focused: false)], now: 4), ["win:1"])
        let later = 3 + AgentSessions.promptLife + 10
        XCTAssertEqual(rows(&a, [win(1, focused: false), win(2, focused: true)], now: later), ["win:1"], "the prompt has run out")
    }

    func testASubagentsPromptIsNotTyped() throws {
        func hook(_ extra: [String: Any]) throws -> AgentEvent {
            var json: [String: Any] = ["hook_event_name": "UserPromptSubmit", "session_id": "a", "cwd": "/p/a"]
            for (k, v) in extra { json[k] = v }
            return try XCTUnwrap(AgentEvent.hook(json, agent: "claude", tty: "", app: t3, at: 1))
        }
        XCTAssertTrue(try hook([:]).started)
        XCTAssertFalse(try hook(["subagentType": "general-purpose"]).started)
    }

    func testOnlyAWorkingReportCanCarryAPrompt() {
        var a = AgentSessions()
        a.apply(ev("a", .working, at: 1))
        XCTAssertEqual(rows(&a, [win(1, focused: true), win(2, focused: false)], now: 2), ["win:1"])
        a.apply(ev("a", .waiting, at: 3, started: true))
        XCTAssertEqual(rows(&a, [win(1, focused: false), win(2, focused: true)], now: 4), ["win:1"], "a stop isn't a prompt, whatever it says")
    }

    func testAPromptIsTimedFromWhenItArrivedNotFromTheSendersClock() {
        // A remote machine's clock a day behind: its prompt still places the session. (Only the
        // prompt's life runs from arrival; staleness and expiry still go by the sender's `at`.)
        var a = AgentSessions()
        a.apply(ev("a", .working, at: 1))
        XCTAssertEqual(rows(&a, [win(1, focused: true), win(2, focused: false)], now: 2), ["win:1"])
        a.apply(ev("a", .working, at: 3 - 86_400, started: true), receivedAt: 3)
        XCTAssertEqual(rows(&a, [win(1, focused: false), win(2, focused: true)], now: 4), ["win:2"], "a slow sender clock doesn't cut the prompt short")
        // And one a day ahead can't stretch it.
        var b = AgentSessions()
        b.apply(ev("a", .working, at: 1))
        XCTAssertEqual(rows(&b, [win(1, focused: true), win(2, focused: false)], now: 2), ["win:1"])
        b.apply(ev("a", .working, at: 3 + 86_400, started: true), receivedAt: 3)
        XCTAssertEqual(rows(&b, [win(1, focused: false), win(2, focused: false)], now: 4), ["win:1"])
        XCTAssertEqual(rows(&b, [win(1, focused: false), win(2, focused: true)], now: 3 + AgentSessions.promptLife + 10), ["win:1"],
                       "a fast sender clock doesn't stretch it")
    }

    func testAPromptPendingWhileNoWindowIsInFrontLeavesAFollowedSessionFollowed() {
        var a = AgentSessions()
        a.apply(ev("q", .waiting, at: 1, message: "Claude needs your permission to use Bash"))
        XCTAssertEqual(rows(&a, [win(1, focused: true), win(2, focused: false)], now: 2), ["win:1"])
        XCTAssertEqual(a.followed, ["win:1"])
        a.apply(ev("q", .waiting, at: 3, message: "Claude needs your permission to use Bash", started: false))
        a.apply(ev("w", .working, at: 3.1, started: true))
        // A prompt is pending (w's), nothing is in front: the question must not count as seen.
        _ = a.resolve([win(1, focused: false), win(2, focused: false)], now: 4)
        XCTAssertEqual(a.followed, ["win:1"], "placed by focus before, and nothing since says otherwise")
    }

    func testAGroksSubagentPromptIsNotTypedInItsRealShape() throws {
        // Grok sends Claude's event names in `hook_event_name` and camelCase keys elsewhere (see the
        // SessionEnd case above).
        let json: [String: Any] = ["hook_event_name": "UserPromptSubmit", "sessionId": "g1", "cwd": "/p", "subagentType": "explore"]
        let e = try XCTUnwrap(AgentEvent.hook(json, agent: "grok", tty: "", app: t3, at: 1))
        XCTAssertFalse(e.started)
        var own = json; own["subagentType"] = nil
        XCTAssertTrue(try XCTUnwrap(AgentEvent.hook(own, agent: "grok", tty: "", app: t3, at: 1)).started)
    }

    func testEventStampsAreCheckedAgainstTheLocalClock() {
        let now = 1_761_864_000.0
        XCTAssertNil(AgentEvent.stampProblem(at: now - 1, started: true, now: now))
        XCTAssertNil(AgentEvent.stampProblem(at: now - 3600, started: false, now: now), "an old stop is fine")
        XCTAssertNotNil(AgentEvent.stampProblem(at: now - 3600, started: true, now: now), "a prompt an hour old places nothing")
        XCTAssertNotNil(AgentEvent.stampProblem(at: now - AgentSessions.promptLife - 1, started: true, now: now))
        XCTAssertNotNil(AgentEvent.stampProblem(at: .infinity, started: false, now: now))
        XCTAssertNotNil(AgentEvent.stampProblem(at: .nan, started: false, now: now))
        XCTAssertNotNil(AgentEvent.stampProblem(at: 1e300, started: false, now: now))
        XCTAssertNotNil(AgentEvent.stampProblem(at: now + 7 * 3600, started: false, now: now))
        XCTAssertNotNil(AgentEvent.stampProblem(at: now - 7 * 3600, started: false, now: now))
    }

    func testTheSameSessionOnAnotherRowIsNotASwitch() {
        // The row-keyed switch check already treats a session arriving on a row that showed nothing as no switch.
        var shown = ShownSessions()
        let a = ev("a", .working, at: 1)
        _ = shown.attention("win:1", a, .working)
        XCTAssertEqual(shown.attention("win:2", a, .waiting), .waiting)
    }

    func testASessionThatTookTheWindowWorkingAndThenStoppedIsAFinishEvenWithTheOldOneStale() {
        var a = AgentSessions(), shown = ShownSessions(), att = Attention()
        a.apply(ev("a", .working, at: 0))
        mergeRow(&a, &shown, &att, [window], now: 1)
        a.apply(ev("b", .working, at: 100))
        mergeRow(&a, &shown, &att, [window], now: 101)
        XCTAssertEqual(att.unseen, [])
        a.apply(ev("b", .waiting, at: AgentSessions.stale + 50))
        let now = AgentSessions.stale + 51
        let shownNow = a.resolve([window], now: now)["win:1"]
        XCTAssertEqual(shownNow?.session, "b")
        XCTAssertEqual(shownNow?.state, .waiting, "b's stop is what the row shows")
        mergeRow(&a, &shown, &att, [window], now: now)
        XCTAssertEqual(att.unseen, ["win:1"], "flagged at the merge where b stops")
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

final class ClaudeDeskTests: XCTestCase {
    func testReadsTheFileClaudeDeskWrites() {
        // claude-desk writes `printf '%s\n'` of the script's lines.
        XCTAssertEqual(ClaudeDesk.parse("tab-1\nterm-a\nterm-b\n"), ["tab-1", "term-a", "term-b"])
        XCTAssertEqual(ClaudeDesk.parse("\n  tab-1 \n\n"), ["tab-1"])
        XCTAssertEqual(ClaudeDesk.parse(""), [])
    }

    func testOnlyTheEventThatOpensThePaneCanStillLandOne() {
        XCTAssertTrue(ClaudeDesk.paneMayLand(progress: "tok\ncreating", token: "tok"))
        // Stopped before the pane-opening event: nothing opened, nothing to recover.
        XCTAssertFalse(ClaudeDesk.paneMayLand(progress: "tok\nstarted", token: "tok"))
        // The pane opened and a later read timed out: it exists but isn't in the state yet.
        XCTAssertTrue(ClaudeDesk.paneMayLand(progress: "tok\ndone", token: "tok"))
        XCTAssertFalse(ClaudeDesk.paneMayLand(progress: "other\ndone", token: "tok"))
        // Another press's progress, or none.
        XCTAssertFalse(ClaudeDesk.paneMayLand(progress: "other\ncreating", token: "tok"))
        XCTAssertFalse(ClaudeDesk.paneMayLand(progress: "", token: "tok"))
        XCTAssertFalse(ClaudeDesk.paneMayLand(progress: "\ncreating", token: ""))
    }

    func testAPressWaitsWhileATimedOutTileMayStillLand() {
        var gate = TileGate()
        XCTAssertFalse(gate.blocks(now: 0))
        gate.timedOut(at: 100)
        XCTAssertTrue(gate.blocks(now: 100))
        XCTAssertTrue(gate.blocks(now: 100 + TileGate.limit - 1))
        XCTAssertFalse(gate.blocks(now: 100 + TileGate.limit), "35 s is the longest a press waits")
        // frontTab answered: the pane exists, so the next press goes ahead at once.
        gate.timedOut(at: 200)
        gate.settled()
        XCTAssertFalse(gate.blocks(now: 201))
        XCTAssertEqual(TileGate.limit, 35)
    }

    func testATimedOutTileIsRecoveredFromTheStatesOwnTab() {
        // The first window opened late: no state, so the front tab it names becomes the state.
        XCTAssertEqual(ClaudeDesk.recovered(prior: [], front: ["tab-1", "a"]), ["tab-1", "a"])
        // The state's tab is gone: the tab `frontTab` fell back to starts the state over, but only
        // with the one terminal a tab `claudeTile` just opened has.
        XCTAssertEqual(ClaudeDesk.recovered(prior: ["tab-1", "a"], front: ["tab-2", "e"]), ["tab-2", "e"])
        XCTAssertEqual(ClaudeDesk.recovered(prior: ["tab-1", "a"], front: ["tab-2", "e", "f"]), [])
        XCTAssertEqual(ClaudeDesk.recovered(prior: [], front: ["tab-2", "e", "f"]), [])
        XCTAssertEqual(ClaudeDesk.recovered(prior: [], front: ["tab-2"]), [])
        // The fifth press opened a new tab: the state becomes that tab, not the full one.
        XCTAssertEqual(ClaudeDesk.recovered(prior: ["tab-1", "a", "b", "c", "d"], front: ["tab-2", "e"]), ["tab-2", "e"])
        // A user's multi-pane tab in front is not adopted.
        XCTAssertEqual(ClaudeDesk.recovered(prior: ["tab-1", "a", "b", "c", "d"], front: ["tab-3", "p", "q"]), [])
        // Exactly one terminal the state doesn't know: the pane that opened late, appended after the
        // old ones in their order, whatever order Ghostty lists them in.
        XCTAssertEqual(ClaudeDesk.recovered(prior: ["tab-1", "a", "b"], front: ["tab-1", "c", "b", "a"]), ["tab-1", "a", "b", "c"])
        // One late pane and a closed one.
        XCTAssertEqual(ClaudeDesk.recovered(prior: ["tab-1", "a", "b"], front: ["tab-1", "b", "c"]), ["tab-1", "b", "c"])
        // None unknown: the state minus the terminals that closed.
        XCTAssertEqual(ClaudeDesk.recovered(prior: ["tab-1", "a", "b"], front: ["tab-1", "b"]), ["tab-1", "b"])
        XCTAssertEqual(ClaudeDesk.recovered(prior: ["tab-1", "a", "b"], front: ["tab-1", "b", "a"]), ["tab-1", "a", "b"])
        // More than one unknown: not ours to guess, the state stays.
        XCTAssertEqual(ClaudeDesk.recovered(prior: ["tab-1", "a"], front: ["tab-1", "a", "x", "y"]), ["tab-1", "a"])
        XCTAssertEqual(ClaudeDesk.recovered(prior: ["tab-1", "a", "b"], front: ["tab-1", "x", "y"]), ["tab-1", "a", "b"])
        // Ghostty has no window: nothing to write.
        XCTAssertEqual(ClaudeDesk.recovered(prior: ["tab-1", "a"], front: []), [])
        XCTAssertEqual(ClaudeDesk.timedOut, -1712)
    }

    func testTheTileScriptFocusesEvenWhenEqualizeFailsAndTheCallerRecoversATimeout() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let scripts = try String(contentsOf: root.appendingPathComponent("Sources/BaneySpaces/Session/Scripts.swift"), encoding: .utf8)
        let tile = try XCTUnwrap(scripts.range(of: "on claudeTile").map { String(scripts[$0.lowerBound...]) })
        // `equalize_splits` and `focus` each sit in a try block of their own.
        let lines = tile.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let eq = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("perform action \"equalize_splits\"") })
        XCTAssertEqual(lines[eq - 1], "try")
        XCTAssertEqual(lines[eq + 1], "end try", "equalize must be alone in its try")
        let focus = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("focus newTerm") })
        XCTAssertEqual(lines[focus - 1], "try")
        XCTAssertEqual(lines[focus + 1], "end try", "focus must be alone in its try")
        let front = try XCTUnwrap(scripts.range(of: "on frontTab(prior)").map { String(scripts[$0.lowerBound...].prefix(2400)) })
        XCTAssertTrue(front.contains("with timeout of 30 seconds"), "frontTab waits as long as the tile does")
        XCTAssertTrue(front.contains("if (id of x) is priorTab"), "frontTab looks up the state's own tab by ID")
        // It follows claudeTile's branch: a new tab when 0 or 4+ of the known terminals are left.
        XCTAssertTrue(front.contains("if liveCount is 0 or liveCount ≥ 4 then"))
        XCTAssertTrue(tile.contains("if n is 0 or n ≥ 4 then"), "the branch frontTab mirrors")
        XCTAssertTrue(front.contains("set t to selected tab of priorWin"))
        // No short probe before frontTab: it would queue behind the slow tile and time out when it matters.
        XCTAssertFalse(scripts.contains("windowCount"))
        // The new tab never appeared: nothing is adopted.
        XCTAssertTrue(front.contains("if (id of t) is priorTab then return \"\""))
        // Progress is recorded for the caller: only "creating" or "done" can have a pane owed to the state.
        XCTAssertTrue(tile.contains("property tileToken") || scripts.contains("property tileToken"))
        XCTAssertEqual(tile.components(separatedBy: "set my tileStep to \"creating\"").count - 1, 3, "each of the three ways to open a pane")
        XCTAssertEqual(tile.components(separatedBy: "set my tileStep to \"done\"").count - 1, 3)
        let controller = try String(contentsOf: root.appendingPathComponent("Sources/BaneySpaces/Session/SessionController.swift"), encoding: .utf8)
        XCTAssertTrue(controller.contains("r.error == ClaudeDesk.timedOut"), "a timeout reads the front tab")
        XCTAssertFalse(controller.contains("windowCount"))
        XCTAssertTrue(controller.contains("ClaudeDesk.paneMayLand(progress:"), "recovery only when a pane may still land")
        XCTAssertTrue(controller.contains("tileGate.blocks("), "a press waits while a timed-out tile may be landing")
        XCTAssertTrue(controller.contains("self?.tileGate.timedOut(at: landing)"))
        XCTAssertTrue(controller.contains("script.run(\"frontTab\", [prior.joined(separator: \"\\n\")])"))
    }

    func testRunsClaudeTheWayClaudeDeskDoes() {
        XCTAssertEqual(ClaudeDesk.paneCommand, "/bin/zsh -lic 'claude; exec /bin/zsh -l'",
                       "-i loads .zshrc, whose PATH and keys Claude's tools need")
    }
}
