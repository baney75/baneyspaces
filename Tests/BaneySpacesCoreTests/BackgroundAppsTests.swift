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
}
