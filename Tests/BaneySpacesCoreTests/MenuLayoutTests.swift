import BaneySpacesCore
import XCTest

/// Donovan, 2026-10-14: the menu bar menu and the dock's right-click menus were "way too
/// cluttered". These hold the trimmed shape.
final class MenuLayoutTests: XCTestCase {
    func testListsOnlyWorkspacesInUseThenOneEmpty() {
        let rows = MenuLayout.rows(current: 1, apps: [1: ["Helium", "Ghostty"], 2: ["Grok Bot"]])
        XCTAssertEqual(rows.map(\.workspace), [1, 2, 3])
        XCTAssertEqual(rows.map(\.title), ["Workspace 1  ·  Helium, Ghostty", "Workspace 2  ·  Grok Bot", "Empty Workspace 3"])
        XCTAssertEqual(rows.map(\.isCurrent), [true, false, false])
    }

    func testCurrentWorkspaceShowsEvenWhenEmpty() {
        let rows = MenuLayout.rows(current: 5, apps: [1: ["Helium"]])
        XCTAssertEqual(rows.map(\.workspace), [1, 5, 2])
        XCTAssertEqual(rows[1].title, "Workspace 5")
        XCTAssertTrue(rows[1].isCurrent)
        // The empty row is another workspace than the one you're on.
        XCTAssertEqual(rows[2].title, "Empty Workspace 2")
    }

    func testLongAppListShortensAndKeepsTheFullListForTheTooltip() {
        let names = ["Helium", "Ghostty", "Obsidian", "T3 Code (Nightly)", "iPhone Mirroring"]
        let row = MenuLayout.rows(current: 1, apps: [1: names])[0]
        XCTAssertEqual(row.title, "Workspace 1  ·  Helium, Ghostty, Obsidian +2")
        XCTAssertEqual(row.fullList, names.joined(separator: ", "))
        XCTAssertNil(MenuLayout.rows(current: 1, apps: [1: ["A", "B", "C"]])[0].fullList)
    }

    func testEveryWorkspaceInUseLeavesNoEmptyRow() {
        var apps: [Int: [String]] = [:]
        for n in 1...9 { apps[n] = ["App \(n)"] }
        let rows = MenuLayout.rows(current: 4, apps: apps)
        XCTAssertEqual(rows.count, 9)
        XCTAssertFalse(rows.contains { $0.title.hasPrefix("Empty") })
    }

    /// The app target can't be imported by tests, so these read its source (code only, comments stripped).
    private func code(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").map { $0.components(separatedBy: "//")[0] }.joined(separator: "\n")
    }

    func testMenuBarMenuDropsTheHintRowAndFoldsTheSwitchesAway() throws {
        let text = try code("Sources/BaneySpaces/AppDelegate.swift")
        XCTAssertFalse(text.contains("\"Add ⇧ to send the front window there\""), "the ⇧ hint row is gone; setup teaches it")
        XCTAssertTrue(text.contains("MenuLayout.rows("), "the workspace rows come from MenuLayout")
        XCTAssertTrue(text.contains("optionsItem()"), "the switches live in one Options submenu")
    }

    func testDockMenusAreShortAndForceQuitHidesBehindOption() throws {
        let text = try code("Sources/BaneySpaces/WorkspaceDock.swift")
        XCTAssertTrue(text.contains("quit.modifierKeyAlternate(.option) { force }"), "Force Quit shows only while ⌥ is held")
        XCTAssertTrue(text.contains(".contextMenu { appMenu(app, in: tile) }"))
        // The dock's own buttons do these; the menus don't repeat them.
        let start = try XCTUnwrap(text.range(of: "private func tileMenu("))
        let end = try XCTUnwrap(text.range(of: "private func icons("))
        let menus = text[start.lowerBound..<end.lowerBound]
        XCTAssertFalse(menus.contains("Find or Install an App"))
        XCTAssertFalse(menus.contains("Show All Workspaces"))
        XCTAssertFalse(menus.contains("Send Front Window"))
    }
}
