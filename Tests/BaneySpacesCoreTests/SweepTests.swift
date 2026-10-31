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

    func testTheEngineSweepsThroughThisDecision() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BaneySpaces/Deck/Engine.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("Sweep.reads("), "Engine's timer must decide through Sweep.reads")
        XCTAssertTrue(src.contains("withTimeInterval: Sweep.tick"), "one timer at Sweep.tick, not a faster one")
    }
}
