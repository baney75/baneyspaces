import XCTest
@testable import BaneySpacesCore

final class AgentWorkspaceTests: XCTestCase {
    func testOffMeansNoRules() {
        XCTAssertNil(AgentWorkspace.number(setting: 0))
        XCTAssertEqual(AgentWorkspace.number(setting: 9), 9)
        XCTAssertTrue(AgentWorkspace.mayFollow(to: 9, current: 1, agent: nil))
        XCTAssertTrue(AgentWorkspace.parkedApps(owners: [1: 10], home: [1: 9], agent: nil).isEmpty)
    }

    func testAppsOnTheAgentWorkspaceAreParkedNotHidden() {
        let owners: [WindowID: Int32] = [1: 10, 2: 20, 3: 20]
        let home: [WindowID: Int] = [1: 1, 2: 9, 3: 1]
        XCTAssertEqual(AgentWorkspace.parkedApps(owners: owners, home: home, agent: 9), [20],
                       "Helium with one window on 9 and one on 1: parked, so its window on 9 stays drivable")
    }

    func testFocusNeverPullsYouOntoTheAgentWorkspace() {
        XCTAssertFalse(AgentWorkspace.mayFollow(to: 9, current: 1, agent: 9))
        XCTAssertTrue(AgentWorkspace.mayFollow(to: 3, current: 1, agent: 9))
        XCTAssertTrue(AgentWorkspace.mayFollow(to: 9, current: 9, agent: 9))
        XCTAssertTrue(AgentWorkspace.mayFollow(to: 1, current: 9, agent: 9), "leaving the agent workspace is always fine")
    }

    func testNewWindows() {
        // An agent asked for this window.
        XCTAssertEqual(AgentWorkspace.homeForNewWindow(appFront: true, appWorkspaces: [], claimed: 9, current: 1, agent: 9), 9)
        // A background window from an app that lives on the agent workspace: an agent opened it.
        XCTAssertEqual(AgentWorkspace.homeForNewWindow(appFront: false, appWorkspaces: [1, 9], claimed: nil, current: 1, agent: 9), 9)
        // You clicked a link: the app came forward, so the window is yours.
        XCTAssertNil(AgentWorkspace.homeForNewWindow(appFront: true, appWorkspaces: [1, 9], claimed: nil, current: 1, agent: 9))
        // Nothing to do with agents.
        XCTAssertNil(AgentWorkspace.homeForNewWindow(appFront: false, appWorkspaces: [1], claimed: nil, current: 1, agent: 9))
        XCTAssertNil(AgentWorkspace.homeForNewWindow(appFront: false, appWorkspaces: [9], claimed: nil, current: 9, agent: 9),
                     "on the agent workspace already: it lands there anyway")
    }
}
