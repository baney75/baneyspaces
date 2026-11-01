import XCTest
@testable import BaneySpacesCore

/// The dock switch (spec/themes.md, "The dock switch"): off, no dock window exists at all, the edge
/// watcher is stopped and a carried window is nobody's business; on, the next reveal builds it.
final class DockSwitchTests: XCTestCase {
    final class FakePanel {}

    private final class Rig {
        var made = 0, released = 0, started = 0, stopped = 0
        lazy var dock = DockSwitch<FakePanel>(
            make: { self.made += 1; return FakePanel() },
            startWatching: { self.started += 1 },
            stopWatching: { self.stopped += 1 },
            release: { _ in self.released += 1 })
    }

    func testOffThereIsNoPanelNoWatcherAndNoCarry() {
        let r = Rig()
        XCTAssertFalse(r.dock.enabled)
        XCTAssertNil(r.dock.panelForReveal(), "a reveal builds nothing while the dock is off")
        XCTAssertEqual(r.made, 0)
        XCTAssertNil(r.dock.panel)
        XCTAssertFalse(r.dock.watching)
        XCTAssertEqual(r.started, 0)
        XCTAssertFalse(r.dock.carryActs)
    }

    func testOnTheWatcherRunsAndTheFirstRevealBuildsThePanel() {
        let r = Rig()
        r.dock.set(true)
        XCTAssertTrue(r.dock.watching)
        XCTAssertEqual(r.started, 1)
        XCTAssertEqual(r.made, 0, "the panel waits for the pointer to reach the edge")
        XCTAssertTrue(r.dock.carryActs)
        let a = r.dock.panelForReveal()
        let b = r.dock.panelForReveal()
        XCTAssertNotNil(a)
        XCTAssertTrue(a === b)
        XCTAssertEqual(r.made, 1)
    }

    func testTurningItOffTakesThePanelDownAndStopsTheWatcher() {
        let r = Rig()
        r.dock.set(true)
        _ = r.dock.panelForReveal()
        r.dock.set(false)
        XCTAssertNil(r.dock.panel, "no dock panel exists, not just a hidden one")
        XCTAssertEqual(r.released, 1)
        XCTAssertEqual(r.stopped, 1)
        XCTAssertFalse(r.dock.watching)
        XCTAssertFalse(r.dock.carryActs)
        XCTAssertNil(r.dock.panelForReveal())
        XCTAssertEqual(r.made, 1)
    }

    func testFlippingItBackBringsTheDockBackOnTheNextReveal() {
        let r = Rig()
        r.dock.set(true)
        _ = r.dock.panelForReveal()
        r.dock.set(false)
        XCTAssertNil(r.dock.panelForReveal())
        r.dock.set(true)
        XCTAssertEqual(r.started, 2)
        XCTAssertNil(r.dock.panel, "still waiting for the edge")
        XCTAssertNotNil(r.dock.panelForReveal())
        XCTAssertEqual(r.made, 2)
        XCTAssertTrue(r.dock.carryActs)
    }

    func testSettingTheSameValueTwiceDoesNothing() {
        let r = Rig()
        r.dock.set(false)
        r.dock.set(true)
        r.dock.set(true)
        XCTAssertEqual(r.started, 1)
        r.dock.set(false)
        r.dock.set(false)
        XCTAssertEqual(r.stopped, 1)
    }

    func testTheTopDragStillNeedsItsWatcherWithTheDockOff() {
        typealias D = DockSwitch<FakePanel>
        XCTAssertTrue(D.windowDragsNeeded(topDrag: true, dockEnabled: false))
        XCTAssertTrue(D.windowDragsNeeded(topDrag: false, dockEnabled: true))
        XCTAssertFalse(D.windowDragsNeeded(topDrag: false, dockEnabled: false))
    }

    // MARK: The app's dock goes through it

    func testTheWorkspaceDockOnlyBuildsItsPanelThroughTheSwitch() throws {
        let code = try Repo.code("Sources/BaneySpaces/WorkspaceDock.swift")
        func count(_ s: String) -> Int { code.components(separatedBy: s).count - 1 }
        XCTAssertEqual(count("self.makePanel()"), 1, "only DockSwitch's factory calls makePanel")
        XCTAssertEqual(count("makePanel()"), 2, "the factory and the definition")
        XCTAssertEqual(count("DockPanel(contentRect"), 2, "the dock's panel and the list's, each in its own maker")
        XCTAssertTrue(code.contains("dockSwitch.panelForReveal()"))
        XCTAssertFalse(code.contains("panel = p"), "nothing assigns the panel around the switch")
        XCTAssertTrue(code.contains("private var panel: DockPanel? { dockSwitch.panel }"))
        // Off, the list's panel goes too.
        XCTAssertTrue(code.contains("sidePanel = nil"))
        // The edge watcher is the switch's; stop goes through it.
        XCTAssertTrue(code.contains("func start() { dockSwitch.set(true) }"))
        XCTAssertTrue(code.contains("dockSwitch.set(false)"))
    }

    func testACarryIsInertWhileTheDockIsOff() throws {
        let code = try Repo.code("Sources/BaneySpaces/WorkspaceDock.swift")
        let carry = try XCTUnwrap(code.range(of: "func carryMoved("))
        XCTAssertTrue(code[carry.lowerBound...].prefix(300).contains("dockSwitch.carryActs"))
        let end = try XCTUnwrap(code.range(of: "func endCarry("))
        XCTAssertTrue(code[end.lowerBound...].prefix(420).contains("guard dockSwitch.carryActs else { return nil }"))
        // Carry state is cleared before the guard, and when the dock goes off mid-drag.
        let body = String(code[end.lowerBound...].prefix(420))
        XCTAssertLessThan(try XCTUnwrap(body.range(of: "windowCarry = nil")).lowerBound, try XCTUnwrap(body.range(of: "guard dockSwitch.carryActs")).lowerBound)
        let off = try XCTUnwrap(code.range(of: "private func endWatching()"))
        let offBody = String(code[off.lowerBound...].prefix(500))
        for field in ["windowCarry = nil", "carryEntry = nil", "carryRefused = nil", "shownForCarry = false"] {
            XCTAssertTrue(offBody.contains(field), field)
        }
    }

    func testTheTopDragWatcherIsKeptForTheTopWhenTheDockIsOff() throws {
        let app = try Repo.code("Sources/BaneySpaces/AppDelegate.swift")
        XCTAssertTrue(app.contains("DockSwitch<DockPanel>.windowDragsNeeded(topDrag: TopDragWatcher.enabled, dockEnabled: WorkspaceDock.enabled)"))
    }

    func testTheDockKeepsWorkingKeysTheSwitcherLauncherOverviewAndIndicatorWithoutIt() throws {
        // None of these reach for the dock: the switch is the dock's alone.
        for file in ["WorkspaceSwitcher", "Launcher", "Viewer", "SwitchHUD", "Keys", "Hotkeys"] {
            let code = try Repo.code("Sources/BaneySpaces/\(file).swift")
            XCTAssertFalse(code.contains("dockSwitch"), file)
            XCTAssertFalse(code.contains("WorkspaceDock.enabled"), "\(file) must not depend on the dock being on")
        }
    }

    func testTheMenuBarMenuHasItsOwnDockToggle() {
        let rows = MenuLayout.rows(current: 1, apps: [:])
        let on = MenuLayout.entries(rows: rows, finished: 0, update: nil, dockOn: true)
        XCTAssertTrue(on.contains(.dock(on: true)))
        let off = MenuLayout.entries(rows: rows, finished: 0, update: nil, dockOn: false)
        XCTAssertTrue(off.contains(.dock(on: false)))
        // Before the app says, the menu is the one it always was.
        XCTAssertFalse(MenuLayout.entries(rows: rows, finished: 0, update: nil).contains(.dock(on: true)))
    }
}
