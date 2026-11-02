import XCTest
@testable import BaneySpacesCore

/// The dock's "Background" tile: running apps with no window to see on any workspace.
final class BackgroundAppsTests: XCTestCase {
    let me: Int32 = 1

    func app(_ pid: Int32, _ name: String, bundle: String? = nil, regular: Bool = true,
             terminated: Bool = false, hidden: Bool = false) -> BackgroundApps.Running {
        .init(pid: pid, name: name, bundleID: bundle, isRegular: regular, isTerminated: terminated, isHidden: hidden)
    }

    func window(_ pid: Int32, minimized: Bool = false) -> BackgroundApps.TrackedWindow {
        .init(pid: pid, isMinimized: minimized)
    }

    func list(_ running: [BackgroundApps.Running], _ windows: [BackgroundApps.TrackedWindow] = []) -> [BackgroundApps.Entry] {
        BackgroundApps.list(running: running, trackedWindows: windows, selfPID: me)
    }

    func testAHiddenAppWithNoWindowsIsListedAsHidden() {
        XCTAssertEqual(list([app(10, "Mail", hidden: true)]), [.init(pid: 10, name: "Mail", state: .hidden)])
    }

    func testAnAppThatIsNotHiddenAndHasNoWindowsIsListedAsNoWindow() {
        XCTAssertEqual(list([app(10, "Notes")]), [.init(pid: 10, name: "Notes", state: .noWindow)])
    }

    func testAnAppWithOnlyMinimizedWindowsIsListedAsMinimized() {
        let found = list([app(10, "Notes")], [window(10, minimized: true), window(10, minimized: true)])
        XCTAssertEqual(found, [.init(pid: 10, name: "Notes", state: .minimized)])
    }

    func testMinimizedWinsOverHiddenBecauseTheWindowIsWhatAClickRestores() {
        let found = list([app(10, "Notes", hidden: true)], [window(10, minimized: true)])
        XCTAssertEqual(found.map(\.state), [.minimized])
    }

    func testOneWindowThatIsNotMinimizedKeepsTheAppOut() {
        XCTAssertEqual(list([app(10, "Notes")], [window(10, minimized: true), window(10)]), [])
    }

    /// An app BaneySpaces hid because its windows live on another workspace has a window there.
    /// It shows on that workspace's tile, so it is not in the background.
    func testAnAppHiddenByBaneySpacesForAWindowOnAnotherWorkspaceIsNotListed() {
        XCTAssertEqual(list([app(10, "Ghostty", hidden: true)], [window(10)]), [])
    }

    func testAWindowOnAnyWorkspaceCountsOnlyForItsOwnApp() {
        let found = list([app(10, "Ghostty"), app(11, "Mail")], [window(10)])
        XCTAssertEqual(found.map(\.pid), [11])
    }

    func testFinderIsNeverListed() {
        XCTAssertEqual(list([app(10, "Finder", bundle: BackgroundApps.finderBundleID)]), [])
        XCTAssertEqual(list([app(10, "Finder", bundle: "com.apple.finder", hidden: true)]), [])
    }

    func testMenuBarAndBackgroundOnlyAppsAreNotListed() {
        XCTAssertEqual(list([app(10, "Bartender", regular: false), app(11, "Mail")]).map(\.pid), [11])
    }

    func testBaneySpacesItselfAndTerminatedAppsAreNotListed() {
        XCTAssertEqual(list([app(me, "BaneySpaces"), app(10, "Gone", terminated: true), app(11, "Mail")]).map(\.pid), [11])
    }

    func testSortedByNameIgnoringCase() {
        let found = list([app(10, "zoom.us"), app(11, "Mail"), app(12, "calendar"), app(13, "Notes")])
        XCTAssertEqual(found.map(\.name), ["calendar", "Mail", "Notes", "zoom.us"])
    }

    func testTwoAppsWithOneNameKeepAStableOrderByPid() {
        XCTAssertEqual(list([app(12, "Helper"), app(11, "Helper")]).map(\.pid), [11, 12])
    }

    func testAnAppListedTwiceByTheSystemAppearsOnce() {
        XCTAssertEqual(list([app(10, "Mail"), app(10, "Mail")]).count, 1)
    }

    func testEmptyInputsGiveNothing() {
        XCTAssertEqual(list([]), [])
    }

    func testTheRowWordsAreShortAndLowercase() {
        XCTAssertEqual(BackgroundApps.State.hidden.label, "hidden")
        XCTAssertEqual(BackgroundApps.State.minimized.label, "minimized")
        XCTAssertEqual(BackgroundApps.State.noWindow.label, "no window")
    }

    /// Review 11-01 (second-F6): every launch flashed the tile, since a new app has no window yet.
    func testAJustLaunchedAppWaitsOutItsGrace() {
        let now = Date(timeIntervalSince1970: 1000)
        let fresh = BackgroundApps.Running(pid: 10, name: "Safari", launchedAt: now.addingTimeInterval(-1))
        let settled = BackgroundApps.Running(pid: 11, name: "Mail", launchedAt: now.addingTimeInterval(-BackgroundApps.launchGrace))
        XCTAssertEqual(BackgroundApps.list(running: [fresh, settled], trackedWindows: [], selfPID: me, now: now).map(\.pid), [11])
    }

    /// Review 11-01 (second-F8, first-F5): a dialog on screen, or a full-screen window on its own
    /// desktop, is something to see; the row would open a second window.
    func testAnAppShowingAnUntrackedWindowIsNotListed() {
        let dialog = BackgroundApps.Running(pid: 10, name: "Updater", hasUntrackedWindow: true)
        XCTAssertEqual(list([dialog, app(11, "Notes")]).map(\.pid), [11])
    }

    /// Review 11-01 (second-F7): a launch while the list is open re-sorts it under the pointer.
    func testHeldRowsKeepTheirPlacesAndNewOnesGoLast() {
        let shown: [BackgroundApps.Entry] = [.init(pid: 1, name: "Mail", state: .hidden), .init(pid: 2, name: "Notes", state: .noWindow)]
        let fresh: [BackgroundApps.Entry] = [.init(pid: 3, name: "Calendar", state: .noWindow), .init(pid: 2, name: "Notes", state: .minimized)]
        XCTAssertEqual(BackgroundApps.held(shown, now: fresh),
                       [.init(pid: 2, name: "Notes", state: .minimized), .init(pid: 3, name: "Calendar", state: .noWindow)],
                       "Mail left, Notes keeps its place and new state, Calendar goes last")
    }

    /// A tripwire on the source text, not a test of the behavior (pruning lives in AppKit-bound `refresh()`).
    /// Review 11-01 (r1 second-F9, #156): a saved layout's window counts as on its workspace only
    /// while the window server still has it. `refresh()` drops the rest, or a relaunched app that
    /// never reopened that window would stay off the list for good.
    func testPendingLayoutEntriesGoWithTheirWindows() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let spaces = try String(contentsOf: root.appendingPathComponent("Sources/BaneySpaces/Spaces.swift"), encoding: .utf8)
        XCTAssertTrue(spaces.contains("pendingLayout = pendingLayout.filter { alive.contains($0.key) }"))
        XCTAssertTrue(spaces.contains("for e in pendingLayout.values where model.workspace(of: e.window) == nil"),
                      "backgroundApps reads the pruned entries")
    }
}

