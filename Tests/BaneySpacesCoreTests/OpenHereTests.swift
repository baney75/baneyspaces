import XCTest
@testable import BaneySpacesCore

/// Donovan, 2026-11-01 (a recording at 11:48): he clicked the empty workspace 3 in the dock, opened
/// the launcher, picked Photos (already open on workspace 2), and BaneySpaces took him to workspace 2.
/// "If someone presses on a space and tries to open it it should open there."
final class OpenHereTests: XCTestCase {
    private func situation(running: Bool = true, on: [Int] = [], command: OpenHere.WindowCommand = .no, target: Int = 3) -> OpenHere.Situation {
        .init(target: target, running: running, windowsOn: on, windowCommand: command)
    }

    // MARK: Target capture from each entry point

    func testEveryEntryPointCarriesItsOwnWorkspace() {
        XCTAssertEqual(OpenHere.target(.dockPlus(3)), 3)
        XCTAssertEqual(OpenHere.target(.dockTileMenu(5)), 5)
        XCTAssertEqual(OpenHere.target(.overviewSlot(7)), 7)
        XCTAssertEqual(OpenHere.target(.overviewTile(4)), 4)
        XCTAssertEqual(OpenHere.target(.launcher(shownOn: 3)), 3)
    }

    func testAWorkspaceThatDoesNotExistIsNoTarget() {
        XCTAssertNil(OpenHere.target(.launcher(shownOn: 0)))
        XCTAssertNil(OpenHere.target(.dockPlus(Workspaces.range.upperBound + 1)))
    }

    // MARK: The reported bug

    /// Photos on workspace 2, launcher opened on the empty workspace 3: Photos moves to 3.
    func testPhotosOnWorkspaceTwoMovesToThreeAndDoesNotTakeYouToTwo() {
        let action = OpenHere.plan(situation(on: [2], command: .no), mode: .here, modifier: false)
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
        let action = OpenHere.plan(situation(on: [1, 2], command: .yes), mode: .here, modifier: false)
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
        XCTAssertEqual(OpenHere.plan(situation(on: [2, 3], command: .yes), mode: .here, modifier: false), .focusHere)
        XCTAssertEqual(OpenHere.plan(situation(on: [3]), mode: .here, modifier: false), .focusHere)
    }

    func testARunningAppWithNoWindowIsAskedForOne() {
        XCTAssertEqual(OpenHere.plan(situation(on: []), mode: .here, modifier: false), .reopen)
    }

    // MARK: The modifier and the setting

    func testOptionGoesToWhereTheAppAlreadyIs() {
        for command in [OpenHere.WindowCommand.yes, .no, .unknown] {
            let action = OpenHere.plan(situation(on: [2], command: command), mode: .here, modifier: true)
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

    // MARK: Review round 1 (#125)

    /// A no is never assumed: an app that was busy, showing a sheet or slow to answer is unknown, and an
    /// unknown is tried as a new window. Only a known no moves the window.
    func testAnUnknownIsTriedAsANewWindowAndOnlyAKnownNoMovesTheWindow() {
        XCTAssertEqual(OpenHere.plan(situation(on: [2], command: .unknown), mode: .here, modifier: false), .newWindow)
        XCTAssertEqual(OpenHere.plan(situation(on: [2], command: .yes), mode: .here, modifier: false), .newWindow)
        XCTAssertEqual(OpenHere.plan(situation(on: [2], command: .no), mode: .here, modifier: false), .moveWindowHere)
    }

    /// The probe answered "no" once (busy) and "yes" next time: the second open makes a window. Nothing about
    /// the first answer is kept, so the plan depends only on what is known now.
    func testABusyNoThenAYesPlansANewWindowTheSecondTime() {
        var evidence = NewWindowEvidence()
        evidence.sawNo("org.ghostty", day: "2026-11-01")
        XCTAssertFalse(evidence.knownSingleWindow("org.ghostty"), "one no, on one day, is not knowledge")
        let first = OpenHere.plan(situation(on: [2], command: evidence.knownSingleWindow("org.ghostty") ? .no : .unknown), mode: .here, modifier: false)
        XCTAssertEqual(first, .newWindow, "an app that said no once is still tried")
        evidence.sawYes("org.ghostty")
        let second = OpenHere.plan(situation(on: [2], command: .yes), mode: .here, modifier: false)
        XCTAssertEqual(second, .newWindow)
    }

    func testSingleWindowIsKnownFromTheCuratedListOrThreeSeparateDays() {
        var evidence = NewWindowEvidence()
        for id in ["com.apple.Photos", "com.apple.Music", "com.apple.AppStore", "com.apple.systempreferences", "com.apple.calculator", "com.apple.MobileSMS"] {
            XCTAssertTrue(evidence.knownSingleWindow(id), id)
        }
        XCTAssertFalse(evidence.knownSingleWindow("org.ghostty"))
        evidence.sawNo("com.example.notes", day: "2026-11-01")
        evidence.sawNo("com.example.notes", day: "2026-11-01")
        evidence.sawNo("com.example.notes", day: "2026-11-02")
        XCTAssertFalse(evidence.knownSingleWindow("com.example.notes"), "two days, however many reads")
        evidence.sawNo("com.example.notes", day: "2026-11-04")
        XCTAssertTrue(evidence.knownSingleWindow("com.example.notes"))
        evidence.sawYes("com.example.notes")
        XCTAssertFalse(evidence.knownSingleWindow("com.example.notes"), "a yes forgets every no")
    }

    func testTheEvidenceSurvivesBeingSaved() throws {
        var evidence = NewWindowEvidence()
        evidence.sawNo("com.example.a", day: "2026-11-01")
        let back = try JSONDecoder().decode(NewWindowEvidence.self, from: JSONEncoder().encode(evidence))
        XCTAssertEqual(back, evidence)
    }

    func testTheAgentWorkspaceAndAgentProcessesAreNotTheUsers() {
        XCTAssertEqual(OpenHere.userWorkspaces([3, 9, 2], agentWorkspace: 9), [3, 2])
        XCTAssertEqual(OpenHere.userWorkspaces([3, 9, 2], agentWorkspace: nil), [3, 9, 2])
        XCTAssertEqual(OpenHere.userProcesses([100, 200, 300] as [Int32], agent: [200]), [100, 300])
    }

    func testOpenHereNeverReachesAnAgentsAppInTheSources() throws {
        let spaces = try Repo.code("Sources/BaneySpaces/Spaces.swift")
        let move = try XCTUnwrap(spaces.range(of: "func moveWindowHere("))
        let moveBody = String(spaces[move.lowerBound...].prefix(1400))
        XCTAssertTrue(moveBody.contains("AgentOwned.shared.pids.contains(pid)"), "an agent's process is never moved")
        XCTAssertTrue(moveBody.contains("OpenHere.userWorkspaces(order, agentWorkspace: agentWorkspace)"), "the agent workspace is never a candidate")
        let make = try XCTUnwrap(spaces.range(of: "func openWindowHere("))
        XCTAssertTrue(String(spaces[make.lowerBound...].prefix(400)).contains("AgentOwned.shared.pids.contains(pid)"))
        let launcher = try Repo.code("Sources/BaneySpaces/Launcher.swift")
        XCTAssertTrue(launcher.contains("!agents.contains($0.processIdentifier)"), "the launcher's running copy is the user's")
        let delegate = try Repo.code("Sources/BaneySpaces/AppDelegate.swift")
        XCTAssertTrue(delegate.contains("where !agents.contains(e.pid)"), "windows on workspaces exclude an agent's processes")
        XCTAssertTrue(delegate.contains("LSMultipleInstancesProhibited"), "an app that allows one copy is refused, not taken from the agent")
        XCTAssertTrue(delegate.contains("createsNewApplicationInstance = newInstance"))
        XCTAssertTrue(delegate.contains("in use by an agent; open it from the agent workspace or wait"))
    }

    /// The launcher caches no no, and reads no menu while the list is built.
    func testNoNegativeIsCachedAndNoMenuIsReadOnTheKeystrokePath() throws {
        let launcher = try Repo.code("Sources/BaneySpaces/Launcher.swift")
        XCTAssertFalse(launcher.contains("[String: Bool]"), "no cache of yes and no")
        XCTAssertTrue(launcher.contains("private var windowYes: [String: pid_t]"), "only a yes, for the process it was found in")
        XCTAssertEqual(launcher.components(separatedBy: "canOpenWindow(").count - 1, 1, "the menu is read in exactly one place")
        let probe = try XCTUnwrap(launcher.range(of: "private func probeWindowCommands()"))
        let read = try XCTUnwrap(launcher.range(of: "canOpenWindow("))
        let queue = try XCTUnwrap(launcher.range(of: "Self.probeQueue.async"))
        XCTAssertGreaterThan(read.lowerBound, probe.lowerBound)
        XCTAssertGreaterThan(read.lowerBound, queue.lowerBound, "and it is off the main thread")
    }

    // MARK: A launch registered before the request, activation first

    func testAnActivationBeforeTheRequestReturnsIsHeldAndBound() {
        let now = Date()
        let launch = PendingLaunch(bundle: "com.apple.calculator", target: 3, before: [], until: now.addingTimeInterval(10))
        XCTAssertEqual(launch.arrival(bundle: "com.apple.calculator", pid: 501, now: now, activation: true), .bind(pid: 501, newProcess: true),
                       "the activation comes first, before openApplication's completion")
        XCTAssertEqual(launch.arrival(bundle: "com.apple.Photos", pid: 9, now: now, activation: true), .unrelated)
        XCTAssertEqual(launch.arrival(bundle: "com.apple.calculator", pid: 501, now: now.addingTimeInterval(11), activation: true), .expired)
    }

    func testAProcessThatWasAlreadyRunningIsNeverANewProcess() {
        let now = Date()
        let launch = PendingLaunch(bundle: "org.ghostty", target: 3, before: [77], until: now.addingTimeInterval(10))
        XCTAssertEqual(launch.arrival(bundle: "org.ghostty", pid: 77, now: now, activation: true), .unrelated, "your own activation")
        XCTAssertEqual(launch.arrival(bundle: "org.ghostty", pid: 77, now: now, activation: false), .bind(pid: 77, newProcess: false),
                       "the request answered by the running copy: claimed, but its windows stay yours")
    }

    func testTheLaunchIsRegisteredBeforeTheRequestIsMade() throws {
        let delegate = try Repo.code("Sources/BaneySpaces/AppDelegate.swift")
        let expect = try XCTUnwrap(delegate.range(of: "spaces.expectLaunch(bundle: bundle, on: target)"))
        let request = try XCTUnwrap(delegate.range(of: "NSWorkspace.shared.openApplication(at: url, configuration: config)"))
        XCTAssertLessThan(expect.lowerBound, request.lowerBound)
        XCTAssertTrue(delegate.contains("spaces.launchFailed()"), "a failed request clears it")
    }

    // MARK: The probe's gate

    func testTheProbeGateIsAnExpiryAndIsClearedAtLaunch() throws {
        let delegate = try Repo.code("Sources/BaneySpaces/AppDelegate.swift")
        XCTAssertTrue(delegate.contains("until < Date().timeIntervalSince1970 + 61"), "an expiry far in the future is refused")
        XCTAssertTrue(delegate.contains("clearStaleOpenHereGate()"))
        XCTAssertTrue(delegate.contains("d.removeObject(forKey: \"openHereURLCommands\")"))
        let probe = try Repo.text("scripts/open-here-probe.swift")
        for sig in ["SIGINT", "SIGTERM", "SIGHUP"] { XCTAssertTrue(probe.contains(sig), sig) }
        XCTAssertTrue(probe.contains("openGate()"))
    }

    // MARK: Showing the moved window without a switch

    func testAWindowMovedToTheWorkspaceYouAreOnComesAloneWithoutASwitch() throws {
        let spaces = try Repo.code("Sources/BaneySpaces/Spaces.swift")
        XCTAssertTrue(spaces.contains("if n == model.current, showAlone(w) { return true }"))
        XCTAssertTrue(spaces.contains("private func showAlone("))
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
