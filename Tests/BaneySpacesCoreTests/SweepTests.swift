@testable import BaneySpacesCore
import XCTest

final class SweepTests: XCTestCase {
    func testNothingWorkingLeavesEveryAppAloneUntilTheSlowPass() {
        for role in Role.allCases {
            XCTAssertFalse(Sweep.reads(role: role, agentWorking: false, lastRead: 100, now: 100 + Sweep.tick))
            XCTAssertFalse(Sweep.reads(role: role, agentWorking: false, lastRead: 100, now: 100 + Sweep.everything - Sweep.tick))
            XCTAssertTrue(Sweep.reads(role: role, agentWorking: false, lastRead: 100, now: 100 + Sweep.everything))
        }
    }

    func testAWorkingAgentKeepsTerminalsReadButNotTheBrowser() {
        XCTAssertTrue(Sweep.reads(role: .terminal, agentWorking: true, lastRead: 100, now: 100 + Sweep.tick))
        XCTAssertFalse(Sweep.reads(role: .browser, agentWorking: true, lastRead: 100, now: 100 + Sweep.tick))
    }

    func testEachAppGoesByItsOwnAgentsAndAFailingScriptWaitsForTheSlowPass() {
        let apps: [(id: Int, role: Role, lastRead: TimeInterval, agentWorking: Bool, lastOK: Bool)] = [
            (1, .terminal, 100, true, true), (2, .terminal, 100, false, true), (3, .browser, 100, true, true),
            (4, .browser, 100 - Sweep.everything, false, true),
        ]
        // Only the terminal with its own agent at work, and the one past the slow pass.
        XCTAssertEqual(Sweep.due(apps, now: 100 + Sweep.tick), [1, 4])
        // A script was tried a moment ago and failed: it waits like any other read.
        XCTAssertEqual(Sweep.due([(5, .terminal, 100, false, false)], now: 100 + Sweep.tick), [])
        // Even with its own agent at work, a terminal whose last script failed waits for the slow pass.
        XCTAssertEqual(Sweep.due([(6, .terminal, 100, true, false)], now: 100 + Sweep.tick), [])
        XCTAssertEqual(Sweep.due([(6, .terminal, 100, true, false)], now: 100 + Sweep.everything), [6])
        // Never tried (no permission yet): due.
        XCTAssertEqual(Sweep.due([(7, .browser, Date.distantPast.timeIntervalSinceReferenceDate, false, true)], now: 100), [7])
        XCTAssertTrue(Sweep.backingOff(lastTried: 100, lastOK: false, now: 101))
        XCTAssertFalse(Sweep.backingOff(lastTried: 100, lastOK: true, now: 101))
    }

    func testAHookReadsOnlyTheAppItCameFromAndNeverTheBrowser() {
        let apps: [(id: Int, bundleID: String, role: Role, ttys: Set<String>)] = [
            (1, "com.mitchellh.ghostty", .terminal, ["/dev/ttys001"]), (2, "com.apple.Terminal", .terminal, ["/dev/ttys009"]),
            (3, "com.example.browser", .browser, []),
        ]
        XCTAssertEqual(Sweep.forHook(apps, eventApp: "com.mitchellh.ghostty"), [1])
        // An agent in an app with no script (T3 Code) needs no script read at all.
        XCTAssertEqual(Sweep.forHook(apps, eventApp: "com.t3tools.t3code"), [])
        // Unknown app: every terminal, still not the browser.
        XCTAssertEqual(Sweep.forHook(apps, eventApp: ""), [1, 2])
        // The terminal it runs in says which app, whatever the app field says.
        XCTAssertEqual(Sweep.forHook(apps, eventApp: "com.mitchellh.ghostty", tty: "/dev/ttys009"), [2])
        // A tty no row has yet: back to the app.
        XCTAssertEqual(Sweep.forHook(apps, eventApp: "com.mitchellh.ghostty", tty: "/dev/ttys042"), [1])
    }

    func testTheSlowPassIsntPushedATickLate() {
        let due = Sweep.everything - Sweep.tick / 2
        XCTAssertTrue(Sweep.reads(role: .browser, agentWorking: false, lastRead: 0, now: due))
        XCTAssertFalse(Sweep.reads(role: .browser, agentWorking: false, lastRead: 0, now: due - 0.1))
    }

    func testTheEngineSweepsThroughThisDecision() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BaneySpaces/Deck/Engine.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("Sweep.due("), "Engine's timer must decide through Sweep.due")
        XCTAssertTrue(src.contains("lastRead: $0.value.scriptTriedAt"), "freshness is the last time a script was tried")
        XCTAssertTrue(src.contains("Sweep.forHook(apps, eventApp: e.app, tty: e.tty)"), "a hook reads through Sweep.forHook")
        XCTAssertTrue(src.contains("agentWorking: $0.value.items.contains { working.contains($0.id) }"), "each app goes by its own rows")
        XCTAssertFalse(src.contains("for (pid, t) in tracked where t.spec.adapter != .windows { refresh(pid) }"), "a hook must not read every scripted app")
        XCTAssertTrue(src.contains("withTimeInterval: Sweep.tick"), "one timer at Sweep.tick, not a faster one")
    }
}
