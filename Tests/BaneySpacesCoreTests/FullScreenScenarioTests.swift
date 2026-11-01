import XCTest
@testable import BaneySpacesCore

/// Donovan, 2026-11-01: "we have errors with that at times on mac, where things sometimes disappear
/// when in full screen." Each scenario puts the real model (`Workspaces`) and the full-screen
/// decisions (`FullScreen.swift`) through a switch on a fake desktop, then asks the audit whether
/// any window ended up where nobody can get it. `OldCheck` is the detection `Spaces.swift` used
/// until then: the scenarios that vanished a window under it are the ones named "old".
final class FullScreenScenarioTests: XCTestCase {
    /// One window on the fake desktop.
    struct Win {
        var app: String
        var pid: Int32
        /// On a macOS desktop of its own.
        var fullScreen = false
        /// Half a screen (Split View) when false and in full screen; the screen when true.
        var screenSized = true
        /// Answers Accessibility.
        var responsive = true
        /// Leaves full screen when asked (Chromium's video full screen does not).
        var leavesWhenAsked = true
        var parked = false
        var minimized = false
        var closedButKept = false
    }

    /// Windows, workspaces and what a switch does to them.
    final class Desktop {
        var model = Workspaces()
        var wins: [WindowID: Win] = [:]
        var hiddenApps = Set<Int32>()
        var refused = RefusedFullScreen()
        var now = Date(timeIntervalSince1970: 9000)
        /// The window server's answer about desktops; false = it doesn't answer.
        var windowServerAnswers = true
        /// Asked to leave, in order, for the scenarios that count stalls.
        var asked: [WindowID] = []
        /// Runs after the plan is made and before windows move: a window entering full screen mid-switch.
        var midSwitch: (() -> Void)?
        /// The old detection, for the scenarios that show what it missed.
        var useOldCheck = false

        func open(_ id: WindowID, _ w: Win, on n: Int? = nil) {
            wins[id] = w
            _ = model.sync(seen: [id], alive: Set(wins.keys))
            if let n { model.assign(id, to: n, focus: false) }
        }

        func close(_ id: WindowID) {
            wins[id] = nil
            _ = model.sync(seen: [], alive: Set(wins.keys))
            refused.keep(alive: Set(wins.keys))
        }

        func evidence(_ id: WindowID) -> FullScreenEvidence {
            let w = wins[id]!
            return FullScreenEvidence(desktop: windowServerAnswers ? (w.fullScreen ? .yes : .no) : .unknown,
                                      attribute: w.responsive ? (w.fullScreen ? .yes : .no) : .unknown,
                                      screenSized: w.screenSized ? .yes : .no)
        }

        func call(_ id: WindowID) -> FullScreenCall {
            if useOldCheck { return OldCheck.call(wins[id]!) }
            return FullScreenDecision.call(evidence(id))
        }

        /// What `Spaces.switchTo` does about full screen (the same `FullScreenFlow` the app runs), then what
        /// `apply` does to windows. The glue around it (timers, Accessibility) is the app's and has no unit test.
        func switchTo(_ n: Int) {
            let plan = model.switchTo(n)
            let begin = FullScreenFlow.begin(plan: plan, model: &model, to: n, refused: &refused, now: now) { hide in
                Dictionary(uniqueKeysWithValues: hide.filter { self.wins[$0] != nil }.map { ($0, self.call($0)) })
            }
            for id in begin.ask {
                asked.append(id)
                // The request lands even if the app can't say so afterwards.
                if wins[id]!.leavesWhenAsked { wins[id]!.fullScreen = false }
            }
            var next = begin.plan
            if !begin.ask.isEmpty {
                let after = Dictionary(uniqueKeysWithValues: begin.ask.map { ($0, call($0)) })
                next = FullScreenFlow.complete(model: &model, to: n, asked: begin.ask, after: after, refused: &refused, now: now).plan
            }
            midSwitch?()
            midSwitch = nil
            apply(next)
        }

        /// Hides apps with nothing here, parks the windows of apps that have a window here.
        func apply(_ plan: SwitchPlan) {
            let owner = Dictionary(uniqueKeysWithValues: wins.map { ($0.key, $0.value.pid) })
            let how = Concealment(plan: plan, owner: owner)
            hiddenApps.subtract(how.showApps)
            for pid in how.hideApps { hiddenApps.insert(pid) }
            for id in plan.show { wins[id]?.parked = false }
            for id in how.park { let fs = wins[id]?.fullScreen ?? false; wins[id]?.parked = !fs }
        }

        func observations() -> [WindowObservation] {
            model.home.compactMap { id, ws in
                guard let w = wins[id] else { return nil }
                let hidden = hiddenApps.contains(w.pid)
                // The window server draws a window unless its app is hidden or it is on another desktop.
                // A parked window keeps a pixel on screen, as the real one does.
                let onScreen = !w.minimized && !hidden && !(w.fullScreen && !model.isShown(ws)) && !w.closedButKept
                return WindowObservation(id: id, app: w.app, workspace: ws, onScreen: onScreen, parked: w.parked, appHidden: hidden,
                                         atHidingSpot: w.parked, minimized: w.minimized, onFullScreenDesktop: w.fullScreen, closedButKept: w.closedButKept)
            }
        }

        func findings() -> [VanishFinding] { VanishAudit.findings(observations(), shown: Set(model.shown.isEmpty ? [model.current] : Array(model.shown.values))) }

        /// `Spaces.finish`'s audit, then its repair: asks the stranded windows to leave and shows the workspace again.
        @discardableResult
        func auditAndRepair(afterDesktopChange: Bool = false) -> [VanishFinding] {
            let found = findings()
            if !VanishAudit.repairable(found, afterDesktopChange: afterDesktopChange).isEmpty { switchTo(model.current) }
            return found
        }
    }

    /// The detection before this change: a window counts only if the window server's bounds are
    /// screen-sized and the app answers that AXFullScreen is true. An app that doesn't answer reads as "no".
    enum OldCheck {
        static func call(_ w: Win) -> FullScreenCall {
            w.screenSized && w.responsive && w.fullScreen ? .inFullScreen("old") : .notInFullScreen("old")
        }
    }

    private var d = Desktop()
    override func setUp() { d = Desktop() }

    /// Helium with a video in full screen on workspace 1, Ghostty beside it.
    private func helium(fullScreen: Bool = true) -> Win { Win(app: "Helium", pid: 10, fullScreen: fullScreen) }
    private func ghostty() -> Win { Win(app: "Ghostty", pid: 20) }

    // MARK: (a) Switching away from a full-screen window and back

    func testAwayAndBackLeavesFullScreenAndShowsTheWindow() {
        d.open(1, helium(), on: 1)
        d.switchTo(2)
        XCTAssertEqual(d.asked, [1])
        XCTAssertFalse(d.wins[1]!.fullScreen)
        XCTAssertTrue(d.hiddenApps.contains(10), "out of full screen, it hides like any window")
        XCTAssertEqual(d.findings(), [])
        d.switchTo(1)
        XCTAssertTrue(d.observations().first { $0.id == 1 }!.onScreen)
        XCTAssertEqual(d.findings(), [])
    }

    func testAwayAndBackTenTimesNeverLosesAWindow() {
        d.open(1, helium(), on: 1)
        d.open(2, ghostty(), on: 2)
        for round in 1...10 {
            d.wins[1]!.fullScreen = true   // the person enters full screen again
            d.switchTo(2)
            XCTAssertEqual(d.findings(), [], "round \(round) away")
            d.switchTo(1)
            XCTAssertEqual(d.findings(), [], "round \(round) back")
            XCTAssertEqual(d.model.workspace(of: 1), 1)
            XCTAssertEqual(d.model.workspace(of: 2), 2)
        }
    }

    /// Old: the app was busy with the transition, so AXFullScreen was unreadable and the window read as
    /// "not in full screen". Its app was hidden and the window stayed on its own desktop.
    func testOldBusyAppVanishedItsWindow() {
        d.useOldCheck = true
        var w = helium(); w.responsive = false
        d.open(1, w, on: 1)
        d.open(2, ghostty(), on: 2)
        d.switchTo(2)
        XCTAssertEqual(d.findings().map(\.kind), [.hiddenButInFullScreen], "the old check let a full-screen window be hidden")
    }

    func testABusyAppIsAskedAndCarriedNeverHidden() {
        var w = helium(); w.responsive = false; w.leavesWhenAsked = false
        d.open(1, w, on: 1)
        d.open(2, ghostty(), on: 2)
        d.switchTo(2)
        XCTAssertEqual(d.asked, [1])
        XCTAssertEqual(d.model.workspace(of: 1), 2, "it did not provably leave, so it comes along")
        XCTAssertEqual(d.findings(), [])
    }

    /// The window server shows the window on no full-screen desktop any more: provably out, though the
    /// app never answers. It hides like any window.
    func testABusyAppThatLeavesIsHiddenOnceTheWindowServerShowsItOut() {
        var w = helium(); w.responsive = false
        d.open(1, w, on: 1)
        d.open(2, ghostty(), on: 2)
        d.switchTo(2)
        XCTAssertEqual(d.model.workspace(of: 1), 1)
        XCTAssertTrue(d.hiddenApps.contains(10))
        XCTAssertEqual(d.findings(), [])
    }

    /// Nothing proves it left: neither the window server nor the app answers, and it is screen-sized.
    func testNothingAnsweringIsNotAWindowThatLeft() {
        d.windowServerAnswers = false
        var w = helium(); w.responsive = false
        d.open(1, w, on: 1)
        d.open(2, ghostty(), on: 2)
        d.switchTo(2)
        XCTAssertEqual(d.model.workspace(of: 1), 2)
        XCTAssertEqual(d.findings(), [])
    }

    // MARK: (b) Entering full screen while a switch is in flight

    func testFullScreenEnteredMidSwitchIsFoundAndRepaired() {
        d.open(1, helium(fullScreen: false), on: 1)
        d.open(2, ghostty(), on: 2)
        d.midSwitch = { [unowned self] in d.wins[1]!.fullScreen = true }   // the green button, after the plan was made
        d.switchTo(2)
        let found = d.auditAndRepair()
        XCTAssertEqual(found.map(\.kind), [.hiddenButInFullScreen], "the audit sees it")
        XCTAssertEqual(d.findings(), [], "and the repair puts it away")
        XCTAssertFalse(d.wins[1]!.fullScreen)
    }

    func testARepairThatIsRefusedCarriesTheWindowToTheWorkspaceInSight() {
        var w = helium(fullScreen: false); w.leavesWhenAsked = false
        d.open(1, w, on: 1)
        d.open(2, ghostty(), on: 2)
        d.midSwitch = { [unowned self] in d.wins[1]!.fullScreen = true }
        d.switchTo(2)
        d.auditAndRepair()
        XCTAssertEqual(d.model.workspace(of: 1), 2)
        XCTAssertEqual(d.findings(), [])
    }

    // MARK: (c) The green button and ⌃⌘F on a window whose workspace isn't current

    func testNativeFullScreenOnAHiddenWorkspaceWindowIsTakenOutAgain() {
        d.open(1, ghostty(), on: 1)
        d.open(2, helium(fullScreen: false), on: 2)
        d.switchTo(1)
        d.wins[2]!.fullScreen = true   // it entered full screen from out of sight
        XCTAssertEqual(d.findings().map(\.kind), [.hiddenButInFullScreen])
        d.auditAndRepair()
        XCTAssertEqual(d.findings(), [])
    }

    func testBaneySpacesFullScreenIgnoresAWindowOnAHiddenWorkspace() {
        XCTAssertTrue(FullScreenRoute.mayFill(workspace: 1, shown: [1]))
        XCTAssertFalse(FullScreenRoute.mayFill(workspace: 2, shown: [1]), "nothing fills a window out of sight")
        XCTAssertTrue(FullScreenRoute.mayFill(workspace: nil, shown: [1]), "a window no scan has placed yet is in sight")
        XCTAssertTrue(FullScreenRoute.mayFill(workspace: 2, shown: [1, 2]), "another display's workspace is in sight too")
    }

    // MARK: (d) An app with several windows, one in full screen

    func testOneFullScreenWindowOfSeveralLeavesAndTheOthersPark() {
        d.open(1, helium(), on: 1)                                   // the video
        d.open(2, Win(app: "Helium", pid: 10), on: 1)                // the same app, same workspace
        d.open(3, Win(app: "Helium", pid: 10), on: 2)                // and one on workspace 2
        d.switchTo(2)
        XCTAssertEqual(d.asked, [1])
        XCTAssertFalse(d.hiddenApps.contains(10), "the app has a window here, so it parks instead of hiding")
        XCTAssertTrue(d.wins[1]!.parked)
        XCTAssertTrue(d.wins[2]!.parked)
        XCTAssertFalse(d.wins[3]!.parked)
        XCTAssertEqual(d.findings(), [])
        d.switchTo(1)
        XCTAssertEqual(d.findings(), [])
        XCTAssertTrue(d.wins[3]!.parked)
    }

    func testOldAWindowInSplitViewWasNotAskedAndVanished() {
        d.useOldCheck = true
        var w = helium(); w.screenSized = false   // half a screen
        d.open(1, w, on: 1)
        d.open(2, ghostty(), on: 2)
        d.switchTo(2)
        XCTAssertEqual(d.findings().map(\.kind), [.hiddenButInFullScreen])
    }

    func testASplitViewWindowIsAskedToLeave() {
        var w = helium(); w.screenSized = false
        d.open(1, w, on: 1)
        d.open(2, ghostty(), on: 2)
        d.switchTo(2)
        XCTAssertEqual(d.asked, [1])
        XCTAssertEqual(d.findings(), [])
    }

    // MARK: (e) Full screen on a second display or Sidecar

    func testTheOtherDisplaysFullScreenWindowIsLeftAloneUntilItsWorkspaceIsLeft() {
        d.model.displays(["A", "B"])
        d.model.reserved = []
        XCTAssertEqual(d.model.shown, ["A": 1, "B": 2])
        d.open(1, ghostty(), on: 1)
        d.open(2, helium(), on: 2)                  // full screen on the Sidecar display, which shows workspace 2
        d.switchTo(3)                               // the focused display (A) goes to 3
        XCTAssertEqual(d.asked, [], "workspace 2 is still shown on B: its window is not hidden")
        XCTAssertTrue(d.wins[2]!.fullScreen)
        XCTAssertEqual(d.findings(), [])
        d.model.focus(display: "B")
        d.switchTo(4)                               // B leaves workspace 2
        XCTAssertEqual(d.asked, [2])
        XCTAssertEqual(d.findings(), [])
    }

    // MARK: (f) Full-screen video in Helium

    func testAVideoThatWillNotLeaveComesAlongWithoutStallingAgain() {
        var w = helium(); w.leavesWhenAsked = false
        d.open(1, w, on: 1)
        d.open(2, ghostty(), on: 2)
        d.switchTo(2)
        XCTAssertEqual(d.asked, [1])
        XCTAssertEqual(d.model.workspace(of: 1), 2)
        d.switchTo(3)
        XCTAssertEqual(d.asked, [1], "not asked a second time: that would stall 5 s on every switch")
        XCTAssertEqual(d.model.workspace(of: 1), 3)
        XCTAssertEqual(d.findings(), [])
    }

    func testWhenTheVideoEndsTheWindowHidesLikeAnyOther() {
        var w = helium(); w.leavesWhenAsked = false
        d.open(1, w, on: 1)
        d.open(2, ghostty(), on: 2)
        d.switchTo(2)
        XCTAssertEqual(d.asked, [1])
        d.wins[1]!.fullScreen = false              // the page leaves full screen by itself
        d.switchTo(3)
        XCTAssertEqual(d.model.workspace(of: 1), 2, "seen out of full screen: no longer carried")
        XCTAssertEqual(d.findings(), [])
        d.switchTo(2)
        d.wins[1]!.fullScreen = true               // and a new video
        d.switchTo(3)
        XCTAssertEqual(d.asked, [1, 1], "seen out of full screen, it is asked again when it goes full screen later")
        XCTAssertEqual(d.findings(), [])
    }

    // MARK: (g) Exiting full screen while hidden or parked

    func testAHiddenWindowThatLeavesFullScreenOnItsOwnIsPutAwayAgain() {
        d.open(1, helium(fullScreen: false), on: 1)
        d.open(2, ghostty(), on: 2)
        d.midSwitch = { [unowned self] in d.wins[1]!.fullScreen = true }
        d.switchTo(2)                              // hidden while it entered full screen
        XCTAssertEqual(d.findings().map(\.kind), [.hiddenButInFullScreen])
        // The person leaves full screen (the video ends, Esc): macOS draws the window where it was.
        d.wins[1]!.fullScreen = false
        d.hiddenApps.remove(10)
        XCTAssertEqual(d.findings().map(\.kind), [.inSightOnHiddenWorkspace])
        XCTAssertEqual(d.auditAndRepair().map(\.kind), [.inSightOnHiddenWorkspace])
        XCTAssertEqual(d.findings().map(\.kind), [.inSightOnHiddenWorkspace], "an after-switch audit does not touch a window it has no full-screen reason for")
        d.auditAndRepair(afterDesktopChange: true)   // the desktop-change audit's own selection
        XCTAssertEqual(d.findings(), [], "put away at once, not left exposed")
    }

    // MARK: (h) A window that refused is carried and then closed

    func testCarriedThenClosedLeavesNoTraceBehind() {
        var w = helium(); w.leavesWhenAsked = false
        d.open(1, w, on: 1)
        d.open(2, ghostty(), on: 2)
        d.open(3, Win(app: "Ghostty", pid: 20), on: 2)
        d.switchTo(2)
        XCTAssertEqual(d.model.workspace(of: 1), 2)
        d.close(1)
        XCTAssertEqual(d.refused.ids, [], "a closed window is forgotten")
        XCTAssertNil(d.model.workspace(of: 1))
        d.switchTo(1)
        d.switchTo(2)
        XCTAssertEqual(d.findings(), [])
        XCTAssertEqual(d.model.windows(on: 2), [2, 3])
    }

    // MARK: (i) The overview, the dock and ⌘Tab showing or activating a full-screen window

    func testGoingToAWorkspaceHoldingACarriedWindowShowsItOnItsDesktop() {
        var w = helium(); w.leavesWhenAsked = false
        d.open(1, w, on: 1)
        d.open(2, ghostty(), on: 2)
        d.switchTo(2)                              // 1 comes along
        d.switchTo(1)                              // a dock tile: it comes along again, nothing is hidden
        XCTAssertEqual(d.model.workspace(of: 1), 1)
        XCTAssertTrue(d.wins[1]!.fullScreen)
        XCTAssertEqual(d.findings(), [], "on a shown workspace, on its own desktop, is where it belongs")
        XCTAssertEqual(d.model.windows(on: 2), [2])
    }

    /// A window moved from the overview (the switch stays on the workspace you're on) to a workspace
    /// that is not shown. It cannot be hidden in full screen, so it is not sent there.
    func testMovingAFullScreenWindowThatWillNotLeaveKeepsItInSight() {
        var w = helium(); w.leavesWhenAsked = false
        d.open(1, w, on: 1)
        d.open(2, ghostty(), on: 1)
        d.model.assign(1, to: 5, focus: false)     // the overview moves it
        d.switchTo(1)                              // reapply the workspace you're on
        XCTAssertEqual(d.model.workspace(of: 1), 1, "a window that cannot be hidden stays where you are")
        XCTAssertEqual(d.findings(), [])
    }

    // MARK: (j) Mission Control held off

    /// The audit and the repair never rely on macOS's own way between desktops: a window on a hidden
    /// workspace on a full-screen desktop is a finding whether or not Mission Control is available.
    func testNothingDependsOnMovingBetweenDesktopsByHand() {
        d.open(1, helium(), on: 1)
        d.open(2, ghostty(), on: 2)
        d.switchTo(2)
        XCTAssertFalse(d.wins[1]!.fullScreen, "BaneySpaces took it out; the person never has to swipe to it")
        d.switchTo(1)
        XCTAssertEqual(d.findings(), [])
    }

    // MARK: The recording of 2026-11-01, 11:56: three full-screen windows on one workspace

    /// With `native`, activating one full-screen window after another on the same workspace asks none of
    /// them to leave: only windows being hidden are ever asked.
    func testActivatingFullScreenWindowsOnOneWorkspaceTouchesNone() {
        d.open(1, Win(app: "Word", pid: 10, fullScreen: true), on: 1)
        d.open(2, Win(app: "Helium", pid: 20, fullScreen: true), on: 1)
        d.open(3, Win(app: "Obsidian", pid: 30, fullScreen: true), on: 1)
        for id: WindowID in [2, 3, 1, 2] {
            d.model.noteFocus(id)
            d.switchTo(1)   // what a dock click does when the workspace is already shown
            XCTAssertEqual(d.asked, [], "activating window \(id) asked another window to leave full screen")
        }
        XCTAssertTrue(d.wins.values.allSatisfy(\.fullScreen))
        XCTAssertEqual(d.findings(), [])
    }

    /// With BaneySpaces full screen nothing is on a desktop of its own: switching between them is a raise.
    func testBaneySpacesFullScreenWindowsAreNeverOnADesktopOfTheirOwn() {
        d.open(1, Win(app: "Word", pid: 10), on: 1)
        d.open(2, Win(app: "Helium", pid: 20), on: 1)
        d.open(3, Win(app: "Obsidian", pid: 30), on: 1)
        for id: WindowID in [2, 3, 1, 2] { d.model.noteFocus(id); d.switchTo(1) }
        XCTAssertEqual(d.asked, [])
        XCTAssertTrue(d.wins.values.allSatisfy { !$0.fullScreen })
        XCTAssertEqual(d.findings(), [])
    }

    // MARK: The dock keeps listing them

    /// Scans, switches and the audit: a window in native full screen stays in the model, with its workspace.
    /// A scan that doesn't list it (its desktop isn't the one shown) must not drop it, and a switch must not forget it.
    func testTheModelKeepsAFullScreenWindowThroughScansSwitchesAndTheAudit() {
        var w = helium(); w.leavesWhenAsked = false
        d.open(1, w, on: 1)
        d.open(2, ghostty(), on: 1)
        for _ in 0..<3 {
            // A scan that lists only the other window, as one taken from another desktop does.
            _ = d.model.sync(seen: [2], alive: Set(d.wins.keys))
            XCTAssertNotNil(d.model.workspace(of: 1))
            d.switchTo(2)
            d.switchTo(1)
            d.auditAndRepair(afterDesktopChange: true)
            XCTAssertNotNil(d.model.workspace(of: 1), "dropped from the model")
        }
        XCTAssertTrue(d.wins[1]!.fullScreen)
        XCTAssertEqual(d.findings(), [])
        // And the closed-window rule leaves it alone while it is off screen on its own desktop.
        let closed = ClosedWindows.find(candidates: [1, 2], listed: [2], answered: [10, 20], offscreen: [1: 10], heldByFullScreen: [1], onNoOtherDesktop: { _ in true })
        XCTAssertEqual(closed, [])
    }

    // MARK: An unknown window-server shape

    /// The window server's list is in a shape nobody recognises (parse gives nil): every window reads
    /// "desktop unknown", and the app's own answer decides. A full-screen window that answers is still asked.
    func testAnUnreadableWindowServerFallsBackToWhatTheAppSays() {
        d.windowServerAnswers = false
        d.open(1, helium(), on: 1)
        d.open(2, ghostty(), on: 2)
        d.switchTo(2)
        XCTAssertEqual(d.asked, [1])
        XCTAssertFalse(d.wins[1]!.fullScreen)
        XCTAssertEqual(d.findings(), [])
    }

    func testAnUnreadableWindowServerNeverHidesAWindowTheAppSaysIsFullScreenAndWillNotLeave() {
        d.windowServerAnswers = false
        var w = helium(); w.leavesWhenAsked = false
        d.open(1, w, on: 1)
        d.open(2, ghostty(), on: 2)
        d.switchTo(2)
        XCTAssertEqual(d.model.workspace(of: 1), 2)
        XCTAssertEqual(d.findings(), [])
    }

    // MARK: (k) A screen-sized window that isn't in full screen

    func testAScreenSizedWindowThatIsNotFullScreenIsNeitherAskedNorCarried() {
        d.open(1, Win(app: "Game", pid: 30, fullScreen: false, screenSized: true), on: 1)
        d.open(2, ghostty(), on: 2)
        d.switchTo(2)
        XCTAssertEqual(d.asked, [])
        XCTAssertEqual(d.model.workspace(of: 1), 1)
        XCTAssertEqual(d.findings(), [])
    }

    func testAScreenSizedWindowOfABusyAppIsStillNotFullScreenWhenTheWindowServerSaysSo() {
        var w = Win(app: "Game", pid: 30, fullScreen: false, screenSized: true); w.responsive = false
        d.open(1, w, on: 1)
        d.open(2, ghostty(), on: 2)
        d.switchTo(2)
        XCTAssertEqual(d.asked, [])
        XCTAssertEqual(d.model.workspace(of: 1), 1)
    }

    /// The one case where nobody can say: the window server doesn't answer, the app is busy, and the
    /// window is screen-sized. It is treated as full screen (carried), never hidden on a guess.
    func testWhenNothingCanSayAScreenSizedWindowIsNotHiddenOnAGuess() {
        d.windowServerAnswers = false
        var w = Win(app: "Game", pid: 30, fullScreen: false, screenSized: true); w.responsive = false
        d.open(1, w, on: 1)
        d.open(2, ghostty(), on: 2)
        d.switchTo(2)
        XCTAssertEqual(d.asked, [1])
        XCTAssertEqual(d.model.workspace(of: 1), 2)
    }

    // MARK: Parking and closed windows (ledger rows)

    /// A full-screen window is never parked: moving it to the corner does nothing, and its record would say it is hidden.
    func testAFullScreenWindowIsNeverRecordedAsParked() {
        var w = helium(); w.leavesWhenAsked = false
        d.open(1, w, on: 1)
        d.open(2, Win(app: "Helium", pid: 10), on: 1)
        d.open(3, Win(app: "Helium", pid: 10), on: 2)
        d.switchTo(2)
        XCTAssertFalse(d.wins[1]!.parked)
        XCTAssertEqual(d.findings(), [])
    }

    func testAClosedButKeptWindowIsNotCarried() {
        var w = ghostty(); w.closedButKept = true
        d.open(1, w, on: 1)
        d.open(2, helium(), on: 1)
        d.switchTo(2)
        XCTAssertEqual(d.asked, [2])
        XCTAssertEqual(d.findings(), [])
    }

    // MARK: The code reads what these tests assume

    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BaneySpaces/\(name)")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { $0.components(separatedBy: "//")[0] }.joined(separator: "\n")
    }

    /// The old detection is gone from the app: a size check plus a boolean Accessibility read.
    func testSpacesNoLongerDecidesFullScreenBySizeAlone() throws {
        let spaces = try source("Spaces.swift")
        XCTAssertFalse(spaces.contains("screenSized(b), w.isFullScreen"), "the old detection missed Split View and busy apps")
        XCTAssertFalse(spaces.contains("var isFullScreen"))
        XCTAssertTrue(spaces.contains("FullScreenDecision.call("))
        XCTAssertTrue(spaces.contains("FullScreenFlow.begin("))
        XCTAssertTrue(spaces.contains("VanishAudit.findings("), "every switch with full screen about is audited")
        let windows = try source("Windows.swift")
        XCTAssertFalse(windows.contains("var isFullScreen: Bool"), "an app that doesn't answer must not read as not in full screen")
        XCTAssertTrue(windows.contains("var fullScreenAnswer: Answer"))
    }

    /// (j) and the Space bookkeeping: the app hears of every Space change, so it never relies on Mission Control.
    func testTheAppHearsOfEverySpaceChange() throws {
        let app = try source("AppDelegate.swift")
        XCTAssertTrue(app.contains("activeSpaceDidChangeNotification"))
        XCTAssertTrue(app.contains("spaces.spaceChanged("))
        let spaces = try source("Spaces.swift")
        XCTAssertTrue(spaces.contains("func spaceChanged("))
        XCTAssertTrue(spaces.contains("mission-control="), "trace.log says whether Mission Control was held off")
    }

    /// Step 1: every decision is in trace.log, with the app and the window id.
    func testEveryFullScreenDecisionIsTraced() throws {
        let spaces = try source("Spaces.swift")
        for phrase in ["fullscreen check", "fullscreen ask", "fullscreen left", "fullscreen refused", "fullscreen carried",
                       "fullscreen flatten", "fullscreen desktop missing from the model", "fullscreen audit", "fullscreen closed"] {
            XCTAssertTrue(spaces.contains(phrase), "trace.log has no '\(phrase)' line")
        }
    }

    /// A timeout set on the system-wide element is the default for every Accessibility call in the process
    /// (AppDelegate sets it to 0.25 s on purpose, once). The tap sets short ones on per-app elements only.
    func testNoCodeSetsATimeoutOnTheSystemWideElementButTheOneInStart() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/BaneySpaces")
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        var hits: [String] = []
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8).split(separator: "\n").map { $0.components(separatedBy: "//")[0] }
            for line in text where line.contains("SetMessagingTimeout") && (line.contains("SystemWide") || line.contains("(sys,")) { hits.append("\(f.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))") }
        }
        XCTAssertEqual(hits.count, 1, "only AppDelegate.start() may: \(hits)")
        XCTAssertTrue(hits.first?.hasPrefix("AppDelegate.swift") ?? false)
        let keys = try source("FullScreenKeys.swift")
        XCTAssertFalse(keys.contains("CreateSystemWide"), "the tap never touches the system-wide element")
        XCTAssertTrue(keys.contains("ClickFilter.request("), "a click is tested in memory before any Accessibility call")
    }

    /// An unreadable list of desktops stops the audit and the migration; it is never read as "none".
    func testAnUnreadableDesktopListIsNeverActedOn() throws {
        let spaces = try source("Spaces.swift")
        XCTAssertTrue(spaces.contains("guard let desktops = Windows.fullScreenDesktops() else { return }"), "the audit stops")
        XCTAssertTrue(spaces.contains("the window server's Spaces list is unreadable"), "the migration stops")
        XCTAssertTrue(spaces.contains("fullscreenMigrated"), "the migration happens once")
    }
}
