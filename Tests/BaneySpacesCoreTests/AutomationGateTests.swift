import XCTest
@testable import BaneySpacesCore

/// Review of #100 (G5): Accessibility allowed but BaneySpaces waiting for AeroSpace to quit left
/// the Automation tab's button and boxes live, doing nothing. They wait for BaneySpaces to start.
final class AutomationGateTests: XCTestCase {
    func testStartedMeansNothingToWaitFor() {
        XCTAssertNil(AutomationGate.reason(trusted: true, aeroSpaceRunning: false, started: true))
    }

    func testWaitingForAccessibilityNamesIt() throws {
        let why = try XCTUnwrap(AutomationGate.reason(trusted: false, aeroSpaceRunning: false, started: false))
        XCTAssertTrue(why.hasPrefix("Available once BaneySpaces is running"))
        XCTAssertTrue(why.contains("Accessibility"))
    }

    func testWaitingForAeroSpaceNamesIt() throws {
        let why = try XCTUnwrap(AutomationGate.reason(trusted: true, aeroSpaceRunning: true, started: false))
        XCTAssertTrue(why.contains("AeroSpace"))
        XCTAssertFalse(why.contains("Accessibility"), "Accessibility is already allowed")
    }

    func testAllowedAndAloneButNotStartedYetIsJustStarting() throws {
        let why = try XCTUnwrap(AutomationGate.reason(trusted: true, aeroSpaceRunning: false, started: false))
        XCTAssertTrue(why.contains("starting"))
    }

    func testNotStartedAlwaysGivesAReason() {
        for trusted in [true, false] {
            for aero in [true, false] {
                XCTAssertNotNil(AutomationGate.reason(trusted: trusted, aeroSpaceRunning: aero, started: false))
            }
        }
    }

    func testAccessibilityRevokedAfterStartDisablesAgain() throws {
        // F7: started, then the person turns Accessibility off in System Settings.
        let why = try XCTUnwrap(AutomationGate.reason(trusted: false, aeroSpaceRunning: false, started: true))
        XCTAssertTrue(why.contains("Accessibility"))
        XCTAssertNil(AutomationGate.reason(trusted: true, aeroSpaceRunning: false, started: true))
    }
}
