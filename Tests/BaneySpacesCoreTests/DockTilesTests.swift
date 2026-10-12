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
