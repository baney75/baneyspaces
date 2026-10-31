import XCTest
@testable import BaneySpacesCore

/// `DockTick.step`: the Workspace Dock's per-tick decision, in the order the tick makes it (#44).
final class DockTickTests: XCTestCase {
    private func step(_ i: DockTick.Input, _ s: inout DockTick.State,
                      menuHolds: Bool = false, menuInTheWay: Bool = false, undroppable: Bool = false) -> [DockTick.Action] {
        DockTick.step(i, state: &s, menuHoldsDock: { menuHolds }, menuInTheWay: { menuInTheWay }, carryUndroppable: { undroppable })
    }

    /// The issue's case: the dock went down, its panel stayed on screen, and the overview is open.
    /// The stray check must run before the overview's early return.
    func testAStrayPanelIsPutAwayWhileTheOverviewIsOpen() {
        var s = DockTick.State()
        let i = DockTick.Input(uptime: 102, shown: false, panelPresent: true, panelUp: true, hiddenAt: 100, viewerOpen: true)
        XCTAssertEqual(step(i, &s), [.orderOutStray])
    }

    func testTheOverviewHidesTheDockAndStaysDown() {
        var s = DockTick.State(edgeSince: 5)
        let up = DockTick.Input(shown: true, panelPresent: true, panelUp: true, viewerOpen: true, inKeepZone: true)
        XCTAssertEqual(step(up, &s), [.hideForViewer])
        XCTAssertNil(s.edgeSince)
        let down = DockTick.Input(clock: 10, viewerOpen: true, edgeScreen: 0, withinSpan: true)
        XCTAssertEqual(step(down, &s), [], "the edge brings nothing up under the overview")
        XCTAssertNil(s.edgeSince)
    }

    func testAPanelMidSlideOutIsNotAStray() {
        var s = DockTick.State()
        let i = DockTick.Input(uptime: 100.1, shown: false, panelPresent: true, panelUp: true, hiddenAt: 100)
        XCTAssertEqual(step(i, &s), [])
    }

    func testTheDockHidesPointFourSecondsAfterTheKeepZoneIsLeft() {
        var s = DockTick.State()
        func tick(_ t: TimeInterval, keep: Bool = false) -> [DockTick.Action] {
            step(DockTick.Input(clock: t, shown: true, panelPresent: true, panelUp: true, inKeepZone: keep), &s)
        }
        XCTAssertEqual(tick(10), [], "the clock starts when the pointer leaves")
        XCTAssertEqual(s.awaySince, 10)
        XCTAssertEqual(tick(10.3), [])
        XCTAssertEqual(tick(10.39), [], "not past 0.4 s yet")
        XCTAssertEqual(tick(10.41), [.hideAway])
        XCTAssertTrue(s.needsRearm, "it was hidden with the pointer possibly still on the edge")
    }

    func testComingBackToTheKeepZoneRestartsTheAwayClock() {
        var s = DockTick.State()
        func tick(_ t: TimeInterval, keep: Bool) -> [DockTick.Action] {
            step(DockTick.Input(clock: t, shown: true, panelPresent: true, panelUp: true, inKeepZone: keep), &s)
        }
        XCTAssertEqual(tick(10, keep: false), [])
        XCTAssertEqual(tick(10.3, keep: true), [])
        XCTAssertNil(s.awaySince)
        XCTAssertEqual(tick(10.6, keep: false), [])
        XCTAssertEqual(tick(10.9, keep: false), [], "0.3 s since it left again")
        XCTAssertEqual(tick(11.05, keep: false), [.hideAway])
    }

    func testAMenuHoldingTheDockKeepsItUp() {
        var s = DockTick.State(awaySince: 1)
        let i = DockTick.Input(clock: 60, shown: true, panelPresent: true, panelUp: true, inKeepZone: false)
        XCTAssertEqual(step(i, &s, menuHolds: true), [], "long past the delay, a menu still holds it")
        XCTAssertNil(s.awaySince)
        XCTAssertEqual(step(DockTick.Input(clock: 61, shown: true, panelPresent: true, panelUp: true), &s, menuHolds: false), [])
        XCTAssertEqual(step(DockTick.Input(clock: 61.5, shown: true, panelPresent: true, panelUp: true), &s, menuHolds: false), [.hideAway])
    }

    func testTheMenuIsNotAskedWhileThePointerIsOnTheDock() {
        var s = DockTick.State()
        var asked = false
        let i = DockTick.Input(clock: 1, shown: true, panelPresent: true, panelUp: true, inKeepZone: true)
        _ = DockTick.step(i, state: &s, menuHoldsDock: { asked = true; return false }, menuInTheWay: { false }, carryUndroppable: { false })
        XCTAssertFalse(asked)
    }

    func testAStrayDragOffTheDockKeepsItUpUntilItIsCancelled() {
        var s = DockTick.State()
        func tick(_ t: TimeInterval, buttonsDown: Bool) -> [DockTick.Action] {
            step(DockTick.Input(clock: t, shown: true, panelPresent: true, panelUp: true, buttonsDown: buttonsDown,
                                dragActive: true, dragStraying: true, inKeepZone: false), &s)
        }
        XCTAssertEqual(tick(10, buttonsDown: true), [], "holding a tile off the dock keeps it up")
        XCTAssertEqual(tick(10.1, buttonsDown: false), [])
        XCTAssertEqual(tick(10.3, buttonsDown: false), [])
        XCTAssertEqual(tick(10.41, buttonsDown: false), [.cancelDrag], "buttons up for over 0.3 s: the drag is over, and the dock is no longer held by it")
        XCTAssertEqual(s.awaySince, 10.41, "with the drag gone, the away clock starts in that same tick")
    }

    /// After hiding with the pointer on the edge, the dock stays down until the pointer leaves.
    func testAfterHidingItDoesNotComeBackUntilThePointerLeavesTheEdge() {
        var s = DockTick.State()
        // Left the keep zone, hidden, needsRearm set.
        _ = step(DockTick.Input(clock: 1, shown: true, panelPresent: true, panelUp: true), &s)
        XCTAssertEqual(step(DockTick.Input(clock: 1.5, shown: true, panelPresent: true, panelUp: true), &s), [.hideAway])
        // Pointer sits on the edge of the same screen, for as long as it likes.
        let onEdge = DockTick.Input(clock: 2, edgeScreen: 0, onRearmScreen: true, withinSpan: true)
        XCTAssertEqual(step(onEdge, &s), [])
        var later = onEdge; later.clock = 30
        XCTAssertEqual(step(later, &s), [], "a parked pointer can't make it bob up")
        XCTAssertTrue(s.needsRearm)
        XCTAssertNil(s.edgeSince)
        // It leaves the edge: re-armed.
        var gone = onEdge; gone.edgeScreen = nil; gone.clock = 31
        XCTAssertEqual(step(gone, &s), [])
        XCTAssertFalse(s.needsRearm)
        // And back: the dwell, then the dock.
        var back = onEdge; back.onRearmScreen = false; back.clock = 32
        XCTAssertEqual(step(back, &s), [])
        back.clock = 32.13
        XCTAssertEqual(step(back, &s), [.show(screen: 0)])
    }

    func testAnotherScreensEdgeIsFreshAfterHiding() {
        var s = DockTick.State(needsRearm: true)
        let other = DockTick.Input(clock: 5, edgeScreen: 1, onRearmScreen: false, withinSpan: true)
        XCTAssertEqual(step(other, &s), [])
        XCTAssertFalse(s.needsRearm)
        var later = other; later.clock = 5.2
        XCTAssertEqual(step(later, &s), [.show(screen: 1)])
    }

    func testTheDockWaitsOutTheDwellBeforeShowing() {
        var s = DockTick.State()
        func tick(_ t: TimeInterval, dwell: TimeInterval = 0.12) -> [DockTick.Action] {
            step(DockTick.Input(clock: t, edgeScreen: 0, withinSpan: true, dwell: dwell), &s)
        }
        XCTAssertEqual(tick(10), [])
        XCTAssertEqual(s.edgeSince, 10)
        XCTAssertEqual(tick(10.1), [])
        XCTAssertEqual(tick(10.12), [], "not past the dwell yet")
        XCTAssertEqual(tick(10.13), [.show(screen: 0)])
    }

    func testTheTopEdgeWaitsLonger() {
        var s = DockTick.State()
        let dwell = DockEdge.top.dwell
        XCTAssertEqual(step(DockTick.Input(clock: 10, edgeScreen: 0, withinSpan: true, dwell: dwell), &s), [])
        XCTAssertEqual(step(DockTick.Input(clock: 10.4, edgeScreen: 0, withinSpan: true, dwell: dwell), &s), [])
        XCTAssertEqual(step(DockTick.Input(clock: 10.51, edgeScreen: 0, withinSpan: true, dwell: dwell), &s), [.show(screen: 0)])
    }

    func testLeavingTheSpanOrTheEdgeRestartsTheDwell() {
        var s = DockTick.State()
        XCTAssertEqual(step(DockTick.Input(clock: 10, edgeScreen: 0, withinSpan: true), &s), [])
        XCTAssertEqual(step(DockTick.Input(clock: 10.1, edgeScreen: 0, withinSpan: false), &s), [])
        XCTAssertNil(s.edgeSince)
        XCTAssertEqual(step(DockTick.Input(clock: 10.2, edgeScreen: 0, withinSpan: true), &s), [])
        XCTAssertEqual(step(DockTick.Input(clock: 10.25, edgeScreen: nil), &s), [])
        XCTAssertNil(s.edgeSince)
    }

    func testAMenuInTheWayHoldsTheDockBackAfterTheDwellOnly() {
        var s = DockTick.State()
        var asked = 0
        func tick(_ t: TimeInterval) -> [DockTick.Action] {
            DockTick.step(DockTick.Input(clock: t, edgeScreen: 0, withinSpan: true), state: &s,
                          menuHoldsDock: { false }, menuInTheWay: { asked += 1; return true }, carryUndroppable: { false })
        }
        XCTAssertEqual(tick(10), [])
        XCTAssertEqual(asked, 0, "menus are looked at once the dwell is over")
        XCTAssertEqual(tick(10.2), [])
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(s.edgeSince, 10, "waiting on a menu doesn't restart the dwell")
    }

    func testButtonsDownKeepTheDockDownUnlessSomethingIsCarried() {
        var s = DockTick.State(edgeSince: 1)
        let held = DockTick.Input(clock: 10, buttonsDown: true, edgeScreen: 0, withinSpan: true)
        XCTAssertEqual(step(held, &s), [], "a selection drag along the edge")
        XCTAssertNil(s.edgeSince)
        var file = held; file.carrying = true
        XCTAssertEqual(step(file, &s), [])
        file.clock = 10.2
        XCTAssertEqual(step(file, &s), [.show(screen: 0)], "a file from another app brings it up")
        var window = held; window.windowCarry = true; window.clock = 20
        s = DockTick.State()
        XCTAssertEqual(step(window, &s), [])
        window.clock = 20.2
        XCTAssertEqual(step(window, &s), [.show(screen: 0)], "a window by its title bar")
        var refused = window; refused.carryRefused = true; s = DockTick.State()
        XCTAssertEqual(step(refused, &s), [])
        refused.clock = 20.5
        XCTAssertEqual(step(refused, &s), [], "a window refused for this press doesn't count")
    }

    func testACarriedWindowThatCannotBeDroppedNeverBringsTheDockUp() {
        var s = DockTick.State()
        func tick(_ t: TimeInterval) -> [DockTick.Action] {
            step(DockTick.Input(clock: t, buttonsDown: true, edgeScreen: 0, windowCarry: true, withinSpan: true), &s, undroppable: true)
        }
        XCTAssertEqual(tick(10), [])
        XCTAssertEqual(tick(10.2), [])
        XCTAssertNil(s.edgeSince)
    }
}
