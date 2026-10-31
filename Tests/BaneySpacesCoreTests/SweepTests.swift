@testable import BaneySpacesCore
import XCTest

final class SweepTests: XCTestCase {
    func testNothingWorkingLeavesEveryAppAloneUntilTheSlowPass() {
        for role in Role.allCases {
            XCTAssertFalse(Sweep.reads(role: role, agentWorking: false, lastRead: 100, now: 100 + Sweep.tick))
            XCTAssertFalse(Sweep.reads(role: role, agentWorking: false, lastRead: 100, now: 100 + Sweep.everything - 1))
            XCTAssertTrue(Sweep.reads(role: role, agentWorking: false, lastRead: 100, now: 100 + Sweep.everything))
        }
    }

    func testAWorkingAgentKeepsTerminalsReadButNotTheBrowser() {
        XCTAssertTrue(Sweep.reads(role: .terminal, agentWorking: true, lastRead: 100, now: 100 + Sweep.tick))
        XCTAssertFalse(Sweep.reads(role: .browser, agentWorking: true, lastRead: 100, now: 100 + Sweep.tick))
    }

    func testAnAppThatAnsweredOnlyThroughAccessibilityStaysDue() {
        let apps: [(id: Int, role: Role, lastRead: TimeInterval)] = [
            (1, .terminal, 100), (2, .browser, 100), (3, .browser, 100 - Sweep.everything),
        ]
        XCTAssertEqual(Sweep.due(apps, agentWorking: false, now: 100 + Sweep.tick), [3])
        XCTAssertEqual(Sweep.due(apps, agentWorking: true, now: 100 + Sweep.tick), [1, 3])
        // Never answered by script: distantPast keeps it due on every tick, as before this change.
        XCTAssertEqual(Sweep.due([(7, .browser, Date.distantPast.timeIntervalSinceReferenceDate)], agentWorking: false, now: 100), [7])
    }

    func testAHookReadsOnlyTheAppItCameFromAndNeverTheBrowser() {
        let apps: [(id: Int, bundleID: String, role: Role)] = [
            (1, "com.mitchellh.ghostty", .terminal), (2, "com.apple.Terminal", .terminal), (3, "com.example.browser", .browser),
        ]
        XCTAssertEqual(Sweep.forHook(apps, eventApp: "com.mitchellh.ghostty"), [1])
        // An agent in an app with no script (T3 Code) needs no script read at all.
        XCTAssertEqual(Sweep.forHook(apps, eventApp: "com.t3tools.t3code"), [])
        // Unknown app: every terminal, still not the browser.
        XCTAssertEqual(Sweep.forHook(apps, eventApp: ""), [1, 2])
    }

    func testTheEngineSweepsThroughThisDecision() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BaneySpaces/Deck/Engine.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("Sweep.due("), "Engine's timer must decide through Sweep.due")
        XCTAssertTrue(src.contains("lastRead: $0.value.scriptedAt"), "freshness is the last read a script answered")
        XCTAssertTrue(src.contains("Sweep.forHook(apps, eventApp: e.app)"), "a hook reads through Sweep.forHook")
        XCTAssertFalse(src.contains("for (pid, t) in tracked where t.spec.adapter != .windows { refresh(pid) }"), "a hook must not read every scripted app")
        XCTAssertTrue(src.contains("withTimeInterval: Sweep.tick"), "one timer at Sweep.tick, not a faster one")
    }
}
