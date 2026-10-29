import XCTest
@testable import BaneySpacesCore

/// Two displays, each with a workspace of its own (Donovan, 2026-10-28), as AeroSpace does it.
final class DisplaysTests: XCTestCase {
    let laptop = "laptop", ipad = "sidecar"

    /// Windows 1–2 on workspace 1, 3 on workspace 2, 4 on workspace 4.
    private func model() -> Workspaces {
        var m = Workspaces()
        m.sync(seen: [1, 2], alive: [1, 2, 3, 4])
        _ = m.switchTo(2); m.sync(seen: [3], alive: [1, 2, 3, 4])
        _ = m.switchTo(4); m.sync(seen: [4], alive: [1, 2, 3, 4])
        _ = m.switchTo(1)
        return m
    }

    func testOneDisplayIsThePlainNineWorkspaces() {
        var m = model()
        m.displays([laptop])
        XCTAssertEqual(m.shown, [laptop: 1])
        let p = m.switchTo(2)
        XCTAssertEqual(p.show, [3])
        XCTAssertEqual(p.hide, [1, 2, 4])
        XCTAssertNil(p.display, "one display: nothing to carry")
    }

    func testANewDisplayShowsTheFirstEmptyWorkspace() {
        var m = model()
        m.displays([laptop, ipad])
        XCTAssertEqual(m.shown, [laptop: 1, ipad: 3])
        XCTAssertEqual(m.current, 1)
        XCTAssertEqual(m.focusedDisplay, laptop)
    }

    /// ⌘N changes only the display you're on; the other keeps its workspace and windows.
    func testSwitchingChangesOnlyTheFocusedDisplay() {
        var m = model()
        m.displays([laptop, ipad])
        m.focus(display: ipad)
        XCTAssertEqual(m.current, 3)
        let p = m.switchTo(4)
        XCTAssertEqual(m.shown, [laptop: 1, ipad: 4])
        XCTAssertEqual(p.show, [1, 2, 4], "workspace 1 stays up on the laptop")
        XCTAssertEqual(p.hide, [3])
        XCTAssertEqual(p.focus, 4)
        XCTAssertEqual(p.display, ipad, "workspace 4's windows go to the iPad")
    }

    /// ⌘N for a workspace another display shows goes there; nothing moves.
    func testSwitchingToAWorkspaceOnTheOtherDisplayGoesThere() {
        var m = model()
        m.displays([laptop, ipad])
        m.focus(display: ipad)
        _ = m.switchTo(4)
        m.focus(display: laptop)
        let p = m.switchTo(4)
        XCTAssertEqual(m.shown, [laptop: 1, ipad: 4], "neither display changed")
        XCTAssertEqual(m.focusedDisplay, ipad)
        XCTAssertEqual(m.current, 4)
        XCTAssertEqual(p.hide, [3])
        XCTAssertEqual(p.focus, 4)
    }

    func testANewWindowJoinsTheWorkspaceOfItsDisplay() {
        var m = model()
        m.displays([laptop, ipad])
        m.sync(seen: [9], alive: [1, 2, 3, 4, 9], on: [9: ipad])
        XCTAssertEqual(m.workspace(of: 9), 3)
        m.sync(seen: [10], alive: [1, 2, 3, 4, 9, 10])
        XCTAssertEqual(m.workspace(of: 10), 1, "display unknown: the current workspace")
    }

    func testAWindowDraggedToTheOtherDisplayJoinsItsWorkspace() {
        var m = model()
        m.displays([laptop, ipad])
        XCTAssertTrue(m.moved(2, to: ipad))
        XCTAssertEqual(m.workspace(of: 2), 3)
        XCTAssertFalse(m.moved(2, to: ipad), "already there")
    }

    /// Unplugged, the display's workspace goes out of view; back, it gets an empty one.
    func testADisplayThatGoesAwayStopsShowingItsWorkspace() {
        var m = model()
        m.displays([laptop, ipad])
        m.focus(display: ipad)
        _ = m.switchTo(4)
        m.displays([laptop])
        XCTAssertEqual(m.shown, [laptop: 1])
        XCTAssertEqual(m.focusedDisplay, laptop)
        XCTAssertEqual(m.current, 1)
        XCTAssertFalse(m.isShown(4))
        XCTAssertEqual(m.switchTo(1).hide, [3, 4])
    }

    func testRestoreBringsBackEachDisplaysWorkspaceEvenSwapped() {
        var m = model()
        m.displays([laptop, ipad])
        m.restore(current: 3, home: [:], lastFocused: [:], displays: [laptop: 3, ipad: 1])
        XCTAssertEqual(m.shown, [laptop: 3, ipad: 1])
        XCTAssertEqual(m.focusedDisplay, laptop)
        XCTAssertEqual(m.current, 3)
    }

    func testVisibleWindowsAreThoseOnEveryShownWorkspace() {
        var m = model()
        m.displays([laptop, ipad])
        m.focus(display: ipad)
        _ = m.switchTo(4)
        XCTAssertEqual(m.visibleWindows, [1, 2, 4])
    }

    func testDisplayOfAWindowIsTheOneHoldingMostOfIt() {
        let screens = [laptop: CGRect(x: 0, y: 0, width: 1512, height: 982),
                       ipad: CGRect(x: -1468, y: -165, width: 1468, height: 1147)]
        XCTAssertEqual(Geometry.display(of: CGRect(x: -400, y: 100, width: 600, height: 400), in: screens), ipad)
        XCTAssertEqual(Geometry.display(of: CGRect(x: 100, y: 100, width: 600, height: 400), in: screens), laptop)
        XCTAssertNil(Geometry.display(of: CGRect(x: 1511, y: 981, width: 600, height: 400), in: screens), "parked off every display")
    }

    func testCarryingKeepsThePlaceAndFitsTheNewDisplay() {
        let a = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let b = CGRect(x: -500, y: 0, width: 500, height: 400)
        let moved = Geometry.carry(CGRect(x: 100, y: 100, width: 400, height: 300), from: a, to: b)
        XCTAssertTrue(b.contains(moved), "\(moved)")
        XCTAssertEqual(moved.size, CGSize(width: 400, height: 300))
        let big = Geometry.carry(CGRect(x: 0, y: 0, width: 1000, height: 800), from: a, to: b)
        XCTAssertEqual(big, b, "too big: fills the new display")
    }

    /// A layout saved before displays had their own workspaces: the second display's pick waits
    /// until windows are back, so it gets a workspace that's really empty.
    func testRedisplayPicksAnEmptyWorkspaceOnceWindowsAreBack() {
        var m = Workspaces()
        m.sync(seen: [1, 2, 3], alive: [1, 2, 3])
        m.displays([laptop, ipad])
        XCTAssertEqual(m.shown[ipad], 2, "every window is on 1 so far")
        m.restore(current: 1, home: [2: 2, 3: 3], lastFocused: [:])
        m.redisplay([laptop, ipad])
        XCTAssertEqual(m.shown, [laptop: 1, ipad: 4])
    }
}
