import XCTest
@testable import BaneySpacesCore

/// The Workspace Dock stayed up with the pointer away from it (Donovan, 2026-10-29: "it keeps
/// getting stuck"). Each check here is one thing that could hold it up with nothing to let it go.
final class DockStuckTests: XCTestCase {
    func testAMenuFlagWithNoMenuOnScreenLetsTheDockGo() {
        XCTAssertFalse(DockMenu.holdsDock(flag: true, setAt: 100, now: 105, ownMenusOnScreen: { 0 }),
                       "a menu flag left set with no menu on screen must not hold the dock up")
        XCTAssertTrue(DockMenu.holdsDock(flag: true, setAt: 100, now: 105, ownMenusOnScreen: { 1 }),
                      "a dock menu still open keeps the dock up")
        XCTAssertFalse(DockMenu.holdsDock(flag: false, setAt: 100, now: 100.2, ownMenusOnScreen: { 1 }))
    }

    func testAMenuJustOpenedHoldsTheDockBeforeTheWindowServerListsIt() {
        var asked = false
        XCTAssertTrue(DockMenu.holdsDock(flag: true, setAt: 100, now: 100.3, ownMenusOnScreen: { asked = true; return 0 }))
        XCTAssertFalse(asked, "the window list isn't read during the grace")
    }

    func testOnlyBaneySpacesOwnMenusOnScreenCount() {
        let list: [[String: Any]] = [
            [kCGWindowLayer as String: 101, kCGWindowOwnerPID as String: Int32(42), kCGWindowIsOnscreen as String: true],
            [kCGWindowLayer as String: 101, kCGWindowOwnerPID as String: Int32(42), kCGWindowIsOnscreen as String: false],
            [kCGWindowLayer as String: 101, kCGWindowOwnerPID as String: Int32(7), kCGWindowIsOnscreen as String: true],
            [kCGWindowLayer as String: 25, kCGWindowOwnerPID as String: Int32(42), kCGWindowIsOnscreen as String: true],
        ]
        XCTAssertEqual(MenuWindows.ownCount(list, level: 101, ownPID: 42), 1)
    }

    func testAPanelStillUpAfterTheDockWentDownIsAStray() {
        XCTAssertTrue(DockStray.isStray(shown: false, panelUp: true, hiddenAt: 100, now: 102))
        XCTAssertTrue(DockStray.isStray(shown: false, panelUp: true, hiddenAt: nil, now: 102))
        XCTAssertFalse(DockStray.isStray(shown: false, panelUp: true, hiddenAt: 100, now: 100.1), "mid slide-out")
        XCTAssertFalse(DockStray.isStray(shown: true, panelUp: true, hiddenAt: 100, now: 102))
        XCTAssertFalse(DockStray.isStray(shown: false, panelUp: false, hiddenAt: 100, now: 102))
    }

    /// AppKit hides a panel when its app deactivates and shows it again when the app comes back,
    /// unless told not to. BaneySpaces activates itself on every empty workspace and in the
    /// overview, so the dock came and went behind its own back. Every other panel opts out.
    func testTheDockPanelIsNeverHiddenOrShownByAppKit() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BaneySpaces/WorkspaceDock.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
            .split(separator: "\n").map { $0.components(separatedBy: "//")[0] }.joined(separator: "\n")
        XCTAssertTrue(text.contains("p.hidesOnDeactivate = false"))
        XCTAssertTrue(text.contains("DockMenu.holdsDock("), "the tick must check the menu flag against the screen")
        XCTAssertTrue(text.contains("DockStray.isStray("), "the tick must put away a panel left up")
    }
}
