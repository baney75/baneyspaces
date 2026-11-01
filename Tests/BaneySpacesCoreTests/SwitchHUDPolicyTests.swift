import XCTest
@testable import BaneySpacesCore

/// The HUD flashed on every number-key switch and every app focus on another workspace, with
/// nothing pressed to open it (11-01). With `showSwitchHUD` unset it must stay down.
final class SwitchHUDPolicyTests: XCTestCase {
    func testOffWhenNeverSet() {
        XCTAssertFalse(SwitchHUDPolicy.enabledByDefault)
        XCTAssertFalse(SwitchHUDPolicy.enabled(stored: nil))
    }

    func testASwitchThatAnnouncesShowsNothingByDefault() {
        // switchTo, focus and focusApp all default to announce: true and take the focus.
        XCTAssertFalse(SwitchHUDPolicy.shows(announce: true, takeFocus: true, stored: nil))
    }

    func testAnExplicitOptInStillShowsIt() {
        XCTAssertTrue(SwitchHUDPolicy.shows(announce: true, takeFocus: true, stored: true))
        XCTAssertFalse(SwitchHUDPolicy.shows(announce: true, takeFocus: true, stored: false))
    }

    func testQuietSwitchesNeverShowItEvenWhenOn() {
        XCTAssertFalse(SwitchHUDPolicy.shows(announce: false, takeFocus: true, stored: true))
        XCTAssertFalse(SwitchHUDPolicy.shows(announce: true, takeFocus: false, stored: true))
    }

    func testTheKeyIsUnchanged() {
        XCTAssertEqual(SwitchHUDPolicy.defaultsKey, "showSwitchHUD")
    }
}

/// The app decides through the policy above, so its tests test what runs.
final class SwitchHUDWiringTests: XCTestCase {
    func testTheHUDReadsItsSwitchThroughThePolicy() throws {
        let hud = try Repo.code("Sources/BaneySpaces/SwitchHUD.swift")
        XCTAssertTrue(hud.contains("SwitchHUDPolicy.enabled(stored: stored)"))
        XCTAssertTrue(hud.contains("forKey: SwitchHUDPolicy.defaultsKey"))
        XCTAssertFalse(hud.contains("?? true"), "the HUD must not default on")
        XCTAssertTrue(hud.contains("guard SwitchHUD.enabled else { return }"))
    }

    func testEverySwitchAsksThePolicyBeforeShowingTheHUD() throws {
        let spaces = try Repo.code("Sources/BaneySpaces/Spaces.swift")
        XCTAssertEqual(spaces.components(separatedBy: "hud.show(").count - 1, 1, "one place shows the HUD")
        let gate = try XCTUnwrap(spaces.range(of: "if SwitchHUDPolicy.shows(announce: announce, takeFocus: moveFocus, stored: SwitchHUD.stored)"))
        let show = try XCTUnwrap(spaces.range(of: "hud.show("))
        XCTAssertLessThan(gate.lowerBound, show.lowerBound)
        XCTAssertFalse(spaces.contains("if announce, moveFocus"), "the old gate showed it whenever a switch announced")
    }
}
