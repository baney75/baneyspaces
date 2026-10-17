import XCTest
@testable import BaneySpacesCore

final class DockTilesTests: XCTestCase {
    func testShowsUsedWorkspacesInOrderPlusTheCurrentOne() {
        let tiles = DockTiles.make(current: 5, windows: [4: ["helium", "helium"], 1: ["claude"], 2: ["ghostty"], 7: []])
        XCTAssertEqual(tiles.map(\.workspace), [1, 2, 4, 5])
        XCTAssertEqual(tiles.map(\.isCurrent), [false, false, false, true])
        XCTAssertTrue(tiles[3].apps.isEmpty)
    }

    func testGroupsWindowsByAppInFirstSeenOrder() {
        let tile = DockTiles.make(current: 1, windows: [1: ["claude", "terminal", "claude"]])[0]
        XCTAssertEqual(tile.apps, [.init(key: "claude", windows: 2), .init(key: "terminal", windows: 1)])
        XCTAssertEqual(tile.windowCount, 3)
    }

    func testEverythingEmptyStillShowsWhereYouAre() {
        XCTAssertEqual(DockTiles.make(current: 3, windows: [:]).map(\.workspace), [3])
    }
}

final class DockAgentTests: XCTestCase {
    private func agent(_ window: WindowID, on workspace: Int = 0, _ state: DockAgent.State = .working, task: String = "Fix the build") -> DockAgent {
        DockAgent(window: window, workspace: workspace, state: state, name: "Claude", task: task)
    }

    func testAnAgentGoesWhereItsWindowIs() {
        // The Deck says workspace 3, but the window has since moved to 1.
        let placed = DockTiles.place([agent(41612, on: 3)], windows: [1: [22225, 41612], 3: [9]], current: 2)
        XCTAssertEqual(placed.keys.sorted(), [1])
    }

    func testAnAgentWithNoKnownWindowFallsBackToTheDecksWorkspace() {
        let placed = DockTiles.place([agent(0, on: 4), agent(777, on: 0)], windows: [1: [5]], current: 2)
        XCTAssertEqual(placed[4]?.count, 1)
        // 0 is the Deck's word for the workspace you're on.
        XCTAssertEqual(placed[2]?.count, 1)
    }

    func testSummarySaysWhoIsDoingWhat() {
        XCTAssertEqual(agent(1, task: "Ghostty to t3code migration").summary, "Claude working: Ghostty to t3code migration")
        XCTAssertEqual(agent(1, .done, task: "").summary, "Claude finished")
        // A long title is cut short: the label is one line.
        let long = agent(1, task: String(repeating: "word ", count: 30)).summary
        XCTAssertLessThanOrEqual(long.count, "Claude working: ".count + DockAgent.taskLimit)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    /// 10-16: the dock showed only working and finished. A permission prompt looked like a
    /// finish, and an API error looked like nothing.
    func testEachStateTheDeckKnowsGetsItsOwnBadge() {
        typealias S = DockAgent.State
        XCTAssertEqual(S.of(activity: .working, unseen: false, notice: ""), .working)
        XCTAssertEqual(S.of(activity: .waiting, unseen: true, notice: "Claude needs your permission to use Bash"), .asking)
        // Asking waits on you even after you've looked.
        XCTAssertEqual(S.of(activity: .waiting, unseen: false, notice: "Claude needs your permission to use Bash"), .asking)
        XCTAssertEqual(S.of(activity: .waiting, unseen: false, notice: AgentEvent.failedMessage), .failed)
        XCTAssertEqual(S.of(activity: .waiting, unseen: true, notice: ""), .done)
        XCTAssertNil(S.of(activity: .waiting, unseen: false, notice: ""))
        XCTAssertNil(S.of(activity: .shell, unseen: false, notice: ""))
        XCTAssertEqual([S.working, .done, .failed, .asking].max { $0.urgency < $1.urgency }, .asking)
        XCTAssertEqual(agent(1, .asking, task: "").summary, "Claude needs you")
    }

    func testAnAgentsAppIsNeverHiddenBehindPlusN() {
        // Workspace 1 on 2026-10-16: five apps, Claude working in Helium's spot past the third.
        let keys = ["tailscale", "silas", "ghostty", "obsidian", "helium"]
        XCTAssertEqual(DockTiles.agentsInView(keys, flagged: ["helium"], shown: 3),
                       ["tailscale", "silas", "helium", "ghostty", "obsidian"])
        // Already in view: nothing moves.
        XCTAssertEqual(DockTiles.agentsInView(keys, flagged: ["ghostty"], shown: 3), keys)
        // Four apps fit without a "+N".
        XCTAssertEqual(DockTiles.agentsInView(Array(keys.prefix(4)), flagged: ["obsidian"], shown: 3), Array(keys.prefix(4)))
        // More agents than slots: the first ones found fill the view.
        XCTAssertEqual(DockTiles.agentsInView(keys, flagged: ["silas", "obsidian", "helium", "tailscale"], shown: 3).prefix(3),
                       ["tailscale", "silas", "obsidian"])
    }
}
