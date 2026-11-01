import XCTest
@testable import BaneySpacesCore

/// Donovan, 2026-11-01 (a recording at 11:48): he clicked the empty workspace 3 in the dock, opened
/// the launcher, picked Photos (already open on workspace 2), and BaneySpaces took him to workspace 2.
/// "If someone presses on a space and tries to open it it should open there."
final class OpenHereTests: XCTestCase {
    private func situation(running: Bool = true, on: [Int] = [], canMakeWindow: Bool = false, target: Int = 3) -> OpenHere.Situation {
        .init(target: target, running: running, windowsOn: on, canMakeWindow: canMakeWindow)
    }

    // MARK: Target capture from each entry point

    func testEveryEntryPointCarriesItsOwnWorkspace() {
        XCTAssertEqual(OpenHere.target(.dockPlus(3)), 3)
        XCTAssertEqual(OpenHere.target(.dockTileMenu(5)), 5)
        XCTAssertEqual(OpenHere.target(.overviewSlot(7)), 7)
        XCTAssertEqual(OpenHere.target(.overviewTile(4)), 4)
        XCTAssertEqual(OpenHere.target(.launcher(shownOn: 3)), 3)
    }

    func testADockAppIconOpensHereOnlyInTheWorkspaceYouAreOn() {
        XCTAssertEqual(OpenHere.target(.dockApp(tile: 3, current: 3)), 3)
        XCTAssertNil(OpenHere.target(.dockApp(tile: 2, current: 3)), "another workspace's icon goes to that workspace's window")
    }

    func testAWorkspaceThatDoesNotExistIsNoTarget() {
        XCTAssertNil(OpenHere.target(.launcher(shownOn: 0)))
        XCTAssertNil(OpenHere.target(.dockPlus(Workspaces.range.upperBound + 1)))
    }

    // MARK: The reported bug

    /// Photos on workspace 2, launcher opened on the empty workspace 3: Photos moves to 3.
    func testPhotosOnWorkspaceTwoMovesToThreeAndDoesNotTakeYouToTwo() {
        let action = OpenHere.plan(situation(on: [2], canMakeWindow: false), mode: .here, modifier: false)
        XCTAssertEqual(action, .moveWindowHere)
        XCTAssertTrue(OpenHere.staysOnTarget(action))
        XCTAssertFalse(OpenHere.followsActivation(action))
    }

    // MARK: Each case

    func testAnAppThatIsNotRunningLaunches() {
        let action = OpenHere.plan(situation(running: false), mode: .here, modifier: false)
        XCTAssertEqual(action, .launch)
        XCTAssertTrue(OpenHere.staysOnTarget(action))
    }

    func testARunningAppThatCanMakeAWindowMakesOneAndTheActivationIsNotFollowed() {
        let action = OpenHere.plan(situation(on: [1, 2], canMakeWindow: true), mode: .here, modifier: false)
        XCTAssertEqual(action, .newWindow)
        XCTAssertFalse(OpenHere.followsActivation(action), "the app comes forward ~54 ms before its window exists (ledger, 10-13)")
        XCTAssertTrue(OpenHere.staysOnTarget(action))
    }

    func testARunningAppWithNoNewWindowItemMovesItsWindowHere() {
        for others in [[2], [1, 2], [9]] {
            XCTAssertEqual(OpenHere.plan(situation(on: others), mode: .here, modifier: false), .moveWindowHere, "\(others)")
        }
    }

    func testAnAppWithAWindowOnTheTargetBringsThatWindowForwardInsteadOfMakingAnother() {
        XCTAssertEqual(OpenHere.plan(situation(on: [2, 3], canMakeWindow: true), mode: .here, modifier: false), .focusHere)
        XCTAssertEqual(OpenHere.plan(situation(on: [3]), mode: .here, modifier: false), .focusHere)
    }

    func testARunningAppWithNoWindowIsAskedForOne() {
        XCTAssertEqual(OpenHere.plan(situation(on: []), mode: .here, modifier: false), .reopen)
    }

    // MARK: The modifier and the setting

    func testOptionGoesToWhereTheAppAlreadyIs() {
        for canMakeWindow in [true, false] {
            let action = OpenHere.plan(situation(on: [2], canMakeWindow: canMakeWindow), mode: .here, modifier: true)
            XCTAssertEqual(action, .goThere)
            XCTAssertTrue(OpenHere.followsActivation(action))
            XCTAssertFalse(OpenHere.staysOnTarget(action))
        }
    }

    func testGoModeIsTheOldBehaviorAndOptionDoesNotChangeItBack() {
        XCTAssertEqual(OpenHere.plan(situation(on: [2]), mode: .go, modifier: false), .goThere)
        XCTAssertEqual(OpenHere.plan(situation(on: [2]), mode: .go, modifier: true), .goThere)
    }

    func testAnAppThatIsNotRunningLaunchesWhateverTheModeOrModifier() {
        for mode in OpenHere.Mode.allCases {
            for modifier in [true, false] {
                XCTAssertEqual(OpenHere.plan(situation(running: false), mode: mode, modifier: modifier), .launch)
            }
        }
    }

    func testTheModeDefaultsToHereAndReadsTheStoredWords() {
        XCTAssertEqual(OpenHere.Mode.standard, .here)
        XCTAssertEqual(OpenHere.Mode(setting: nil), .here)
        XCTAssertEqual(OpenHere.Mode(setting: "go"), .go)
        XCTAssertEqual(OpenHere.Mode(setting: " GO "), .go)
        XCTAssertEqual(OpenHere.Mode(setting: "nonsense"), .here)
    }

    /// Only the old go-to behavior follows an app's activation; everything that opens here ignores it.
    func testOnlyGoThereFollowsTheActivation() {
        let all: [OpenHere.Action] = [.launch, .focusHere, .newWindow, .moveWindowHere, .reopen, .goThere]
        XCTAssertEqual(all.filter(OpenHere.followsActivation), [.goThere])
        XCTAssertEqual(all.filter { !OpenHere.staysOnTarget($0) }, [.goThere])
    }

    // MARK: Source checks (the app target can't be imported)

    /// The launcher takes the workspace it was opened for and passes it to every open, instead of asking
    /// for "wherever the app already is".
    func testTheLauncherPassesItsTargetWorkspaceThrough() throws {
        let launcher = try Repo.code("Sources/BaneySpaces/Launcher.swift")
        XCTAssertTrue(launcher.contains("func show(scope: LauncherModel.Scope = .root, takeKeys: Bool = true, entry: OpenHere.Entry? = nil)"),
                      "show() takes the entry point the launcher was opened from")
        XCTAssertTrue(launcher.contains("model.prepare(scope: scope, target: target)"), "the controller captures the target at show()")
        XCTAssertTrue(launcher.contains("var target: Int?") || launcher.contains("private(set) var target: Int?"), "the model holds the target")
        XCTAssertTrue(launcher.contains("OpenHere.plan("), "opening an app goes through OpenHere.plan")
        XCTAssertTrue(launcher.contains("actions.openApp("), "the open is made by the app's actions with the target")
        XCTAssertFalse(launcher.contains("actions.focusApp(app.processIdentifier, nil)"),
                       "the old 'go to wherever the app is' call is only for go mode and the ⌥ path")
        let delegate = try Repo.code("Sources/BaneySpaces/AppDelegate.swift")
        XCTAssertTrue(delegate.contains("a.openApp = "), "AppDelegate wires the open")
        XCTAssertTrue(delegate.contains("OpenHere.Mode(setting: "), "the mode is read from the stored setting")
        XCTAssertTrue(delegate.contains("func openHere(app: String, target: Int)"), "one entry point for the overview and the probe")
        XCTAssertTrue(launcher.contains("func openHere(app path: String, target: Int"), "the launcher exposes the same open by app and target")
    }

    /// Dock and overview entry points hand their workspace to the launcher.
    func testTheDockPassesItsWorkspaceToTheLauncher() throws {
        let dock = try Repo.code("Sources/BaneySpaces/WorkspaceDock.swift")
        XCTAssertTrue(dock.contains("onShowLauncher: (OpenHere.Entry"), "the dock's launcher button names its entry")
        XCTAssertTrue(dock.contains(".dockTileMenu("), "a tile's context menu opens an app on that tile's workspace")
    }

    // MARK: The "+" opens the launcher for its workspace (the coordinator, 2026-11-01)

    func testClickingAnEmptyWorkspaceGoesThereAndOpensItsLauncher() {
        XCTAssertEqual(OpenHere.tileClick(empty: true), .goToAndOpenLauncher)
        XCTAssertEqual(OpenHere.tileClick(empty: false), .goTo, "a workspace with windows is only gone to")
        // The launcher it opens is targeted at the workspace clicked, from the dock and the overview.
        for n in Workspaces.range {
            XCTAssertEqual(OpenHere.target(.dockPlus(n)), n)
            XCTAssertEqual(OpenHere.target(.overviewSlot(n)), n)
        }
    }

    func testTheDockAndOverviewPlusClicksOpenTheLauncherWithTheTargetSet() throws {
        let dock = try Repo.code("Sources/BaneySpaces/WorkspaceDock.swift")
        XCTAssertTrue(dock.contains("case .goToAndOpenLauncher: onShowLauncher(.dockPlus(n))"), "the dock's + opens the launcher for its workspace")
        XCTAssertTrue(dock.contains("model.clicked(n, empty: true)"), "the + tile calls it")
        XCTAssertTrue(dock.contains("model.clicked(tile.id, empty: tile.apps.isEmpty)"), "an empty tile does too")
        XCTAssertFalse(dock.contains("onTapGesture { model.onPick("), "no tile click goes around it")
        XCTAssertTrue(dock.contains("Button(\"Open an App Here…\")"), "the menu items stay")
        let viewer = try Repo.code("Sources/BaneySpaces/Viewer.swift")
        XCTAssertTrue(viewer.contains("case .goToAndOpenLauncher: onOpenHere(.overviewSlot(n))"), "the overview's empty slot opens the launcher for its workspace")
        XCTAssertTrue(viewer.contains("model.tileClicked(n, empty: entries.isEmpty)"))
        XCTAssertTrue(viewer.contains("Button(\"Open an App Here…\")"), "the menu item stays")
        // Both end in LauncherController.show(entry:), which sets the model's target from the entry.
        let delegate = try Repo.code("Sources/BaneySpaces/AppDelegate.swift")
        XCTAssertTrue(delegate.contains("self?.launcher.show(entry: entry)"))
        let launcher = try Repo.code("Sources/BaneySpaces/Launcher.swift")
        XCTAssertTrue(launcher.contains("entry.flatMap(OpenHere.target)"), "the entry becomes the launcher's target")
    }

    /// The activation an open causes is not followed: reuse of ledger row 3's fix.
    func testTheSpacesOpensDoNotFollowTheActivation() throws {
        let spaces = try Repo.code("Sources/BaneySpaces/Spaces.swift")
        XCTAssertTrue(spaces.contains("func moveWindowHere("), "single-window apps move their window to the target")
        XCTAssertTrue(spaces.contains("opening = (pid,"), "the activation is ignored through `opening`")
        XCTAssertTrue(spaces.contains("honorsFront"), "a launch claim holds even when the launched app is in front")
    }
}
