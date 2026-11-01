import XCTest
@testable import BaneySpacesCore

final class DockAppOrderTests: XCTestCase {
    /// Workspace 1 on 2026-11-01, 4:15 PM, in its windows' order.
    private let space1 = ["word", "obsidian", "t3", "silas", "grok"]

    func testTheAppUsedLastComesFirst() {
        var used = AppActivations()
        used.note("obsidian", on: 1, at: 10)
        used.note("grok", on: 1, at: 30)
        used.note("word", on: 1, at: 20)
        XCTAssertEqual(DockAppOrder.sort(space1, activatedAt: used.on(1)), ["grok", "word", "obsidian", "t3", "silas"])
    }

    func testTheOrderChangesWhenAnotherAppComesForward() {
        var used = AppActivations()
        used.note("grok", on: 1, at: 30)
        used.note("silas", on: 1, at: 20)
        XCTAssertEqual(DockAppOrder.sort(space1, activatedAt: used.on(1)).prefix(2), ["grok", "silas"])
        used.note("silas", on: 1, at: 40)
        XCTAssertEqual(DockAppOrder.sort(space1, activatedAt: used.on(1)).prefix(2), ["silas", "grok"])
        // Coming forward again, Grok Bot takes the front back.
        used.note("grok", on: 1, at: 50)
        XCTAssertEqual(DockAppOrder.sort(space1, activatedAt: used.on(1)).prefix(2), ["grok", "silas"])
    }

    /// The tile showed Word, Obsidian, T3 and "+2" with Grok Bot hidden in the list, though it was in front.
    func testTheTileAndItsPlusNListShareOneOrder() {
        var used = AppActivations()
        used.note("silas", on: 1, at: 10)
        used.note("grok", on: 1, at: 20)
        let tile = DockTiles.make(current: 1, windows: [1: space1 + ["grok"]], activatedAt: used.all)[0]
        let keys = tile.apps.map(\.key)
        XCTAssertEqual(keys, ["grok", "silas", "word", "obsidian", "t3"])
        XCTAssertEqual(tile.apps.first, .init(key: "grok", windows: 2))
        let shown = 3
        XCTAssertEqual(DockLabel.hidden(keys.count, shown: shown), 2)
        // The icons are the head of the order and the "+N" list is the rest, in the same order.
        XCTAssertEqual(Array(keys.prefix(shown)), ["grok", "silas", "word"])
        XCTAssertEqual(Array(keys.dropFirst(shown)), ["obsidian", "t3"])
        // An agent's app still moves into view after the sort.
        XCTAssertEqual(DockTiles.agentsInView(keys, flagged: ["t3"], shown: shown), ["grok", "silas", "t3", "word", "obsidian"])
    }

    /// Apps never used on the workspace keep their windows' order, after the ones that were.
    func testAppsNeverUsedThereKeepTheirWindowOrder() {
        XCTAssertEqual(DockAppOrder.sort(space1, activatedAt: [:]), space1)
        XCTAssertEqual(DockTiles.make(current: 1, windows: [1: space1]).first?.apps.map(\.key), space1)
        var used = AppActivations()
        used.note("t3", on: 1, at: 5)
        XCTAssertEqual(DockAppOrder.sort(space1, activatedAt: used.on(1)), ["t3", "word", "obsidian", "silas", "grok"])
        // Two used at the same moment keep their windows' order too.
        XCTAssertEqual(DockAppOrder.sort(space1, activatedAt: ["grok": 5, "obsidian": 5]), ["obsidian", "grok", "word", "t3", "silas"])
    }

    func testUsingAnAppOnOneWorkspaceLeavesAnotherAlone() {
        var used = AppActivations()
        used.note("ghostty", on: 2, at: 1)
        used.note("helium", on: 2, at: 2)
        used.note("ghostty", on: 1, at: 3)
        let tiles = DockTiles.make(current: 1, windows: [1: ["helium", "ghostty"], 2: ["ghostty", "helium"]], activatedAt: used.all)
        XCTAssertEqual(tiles.map { $0.apps.map(\.key) }, [["ghostty", "helium"], ["helium", "ghostty"]])
    }

    func testAnAppThatQuitLosesItsPlace() {
        var used = AppActivations()
        used.note("4242", on: 1, at: 9)
        used.note("4242", on: 3, at: 9)
        used.forget("4242")
        XCTAssertTrue(used.on(1).isEmpty)
        XCTAssertTrue(used.on(3).isEmpty)
    }
}

/// The dock and ⌘Tab's workspace cards read the same order from `Spaces.activations`.
final class DockAppOrderWiringTests: XCTestCase {
    func testTheDockAndTheSwitcherSortWithTheSameActivations() throws {
        let dock = try Repo.code("Sources/BaneySpaces/WorkspaceDock.swift")
        XCTAssertTrue(dock.contains("activatedAt: spaces.activations.all"), "the dock's tiles must sort by when each app was used")
        let switcher = try Repo.code("Sources/BaneySpaces/WorkspaceSwitcher.swift")
        XCTAssertTrue(switcher.contains("DockAppOrder.sort(keys, activatedAt: spaces.activations.on(n))"), "⌘Tab's cards must use the dock's order")
        let spaces = try Repo.code("Sources/BaneySpaces/Spaces.swift")
        XCTAssertTrue(spaces.contains("activations.note("), "focus must stamp the app")
        let delegate = try Repo.code("Sources/BaneySpaces/AppDelegate.swift")
        XCTAssertTrue(delegate.contains("self.dock.reload()"), "an activation must reorder a dock in view")
    }
}
