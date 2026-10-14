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
