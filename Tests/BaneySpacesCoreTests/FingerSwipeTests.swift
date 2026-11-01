import XCTest
@testable import BaneySpacesCore

/// The trackpad swipe that opened Mission Control now opens BaneySpaces' overview.
final class FingerSwipeTests: XCTestCase {
    typealias T = FingerSwipe.Touch

    /// `n` fingers side by side at height `y`, centred on `x`.
    private func fingers(_ n: Int, y: Float, x: Float = 0.5) -> [T] {
        (0..<n).map { T(x: x - 0.1 + 0.05 * Float($0), y: y) }
    }

    /// A swipe from `from` to `to` in small steps; the direction fired, if any.
    private func swipe(_ s: inout FingerSwipe, _ n: Int, from: Float, to: Float, dx: Float = 0) -> [FingerSwipe.Direction] {
        var fired: [FingerSwipe.Direction] = []
        for i in 0...10 {
            let k = Float(i) / 10
            if let d = s.frame(fingers(n, y: from + (to - from) * k, x: 0.5 + dx * k)) { fired.append(d) }
        }
        return fired
    }

    func testThreeFingersUpOpensOnce() {
        var s = FingerSwipe(fingers: [3])
        XCTAssertEqual(swipe(&s, 3, from: 0.3, to: 0.8), [.up])
    }

    func testThreeFingersDownCloses() {
        var s = FingerSwipe(fingers: [3])
        XCTAssertEqual(swipe(&s, 3, from: 0.8, to: 0.3), [.down])
    }

    func testFourFingersWhenOnlyThreeAreMissionControl() {
        var s = FingerSwipe(fingers: [3])
        XCTAssertEqual(swipe(&s, 4, from: 0.3, to: 0.8), [])
        var four = FingerSwipe(fingers: [4])
        XCTAssertEqual(swipe(&four, 3, from: 0.3, to: 0.8), [], "three fingers when macOS wants four")
        XCTAssertEqual(swipe(&four, 4, from: 0.3, to: 0.8), [.up])
    }

    func testEitherCountWhenBothAreOn() {
        var s = FingerSwipe(fingers: [3, 4])
        XCTAssertEqual(swipe(&s, 3, from: 0.3, to: 0.8), [.up])
        s.reset()
        XCTAssertEqual(swipe(&s, 4, from: 0.3, to: 0.8), [.up])
    }

    func testAShortOrSidewaysOrSlantedMoveIsNotASwipe() {
        var s = FingerSwipe(fingers: [3])
        XCTAssertEqual(swipe(&s, 3, from: 0.5, to: 0.58), [], "too short")
        s.reset()
        XCTAssertEqual(swipe(&s, 3, from: 0.5, to: 0.5, dx: 0.4), [], "sideways: workspace-style swipe")
        s.reset()
        XCTAssertEqual(swipe(&s, 3, from: 0.3, to: 0.6, dx: 0.3), [], "more across than up")
    }

    func testFiresOnceThenWaitsForFingersToLift() {
        var s = FingerSwipe(fingers: [3])
        XCTAssertEqual(swipe(&s, 3, from: 0.3, to: 0.8), [.up])
        XCTAssertEqual(swipe(&s, 3, from: 0.8, to: 0.2), [], "still down: the same gesture")
        XCTAssertNil(s.frame([]))
        XCTAssertEqual(swipe(&s, 3, from: 0.8, to: 0.2), [.down], "a new gesture after letting go")
    }

    func testFingersLandingOneAtATimeStillWork() {
        var s = FingerSwipe(fingers: [4])
        XCTAssertNil(s.frame(fingers(1, y: 0.3)))
        XCTAssertNil(s.frame(fingers(2, y: 0.3)))
        XCTAssertNil(s.frame(fingers(3, y: 0.31)))
        XCTAssertEqual(swipe(&s, 4, from: 0.3, to: 0.8), [.up])
    }

    func testAFourthFingerLandingIsNotAThreeFingerSwipe() {
        var s = FingerSwipe(fingers: [3])
        XCTAssertNil(s.frame(fingers(3, y: 0.3)))
        XCTAssertNil(s.frame(fingers(4, y: 0.3)))
        XCTAssertEqual(swipe(&s, 4, from: 0.3, to: 0.8), [])
    }

    func testThreeFingerLandingBeforeAFourthRestartsWhenBothAreOn() {
        var s = FingerSwipe(fingers: [3, 4])
        XCTAssertNil(s.frame(fingers(3, y: 0.3)))
        XCTAssertEqual(swipe(&s, 4, from: 0.3, to: 0.8), [.up])
    }

    func testTwoFingersScrollingNeverOpens() {
        var s = FingerSwipe(fingers: [3, 4])
        XCTAssertEqual(swipe(&s, 2, from: 0.1, to: 0.9), [])
        XCTAssertEqual(swipe(&s, 1, from: 0.1, to: 0.9), [])
    }

    /// Show Desktop: the thumb stays low while three fingers go up and away. The centre moves up,
    /// but the hand spreads, so it isn't a four-finger swipe.
    func testAShowDesktopSpreadIsNotASwipe() {
        var s = FingerSwipe(fingers: [4])
        var fired: [FingerSwipe.Direction] = []
        for i in 0...10 {
            let k = Float(i) / 10
            let hand = [T(x: 0.2, y: 0.1),
                        T(x: 0.5, y: 0.3 + 0.28 * k), T(x: 0.6 + 0.1 * k, y: 0.3 + 0.28 * k), T(x: 0.7 + 0.2 * k, y: 0.3 + 0.28 * k)]
            if let d = s.frame(hand) { fired.append(d) }
        }
        XCTAssertEqual(fired, [])
        // The same four fingers moving as one hand still swipe.
        var together = FingerSwipe(fingers: [4])
        XCTAssertEqual(swipe(&together, 4, from: 0.3, to: 0.8), [.up])
    }

    func testAPinchIsNotASwipe() {
        var s = FingerSwipe(fingers: [4])
        var fired: [FingerSwipe.Direction] = []
        for i in 0...10 {
            let k = Float(i) / 10
            // Fingers close in on the middle while drifting up.
            let hand = [T(x: 0.3 + 0.15 * k, y: 0.3 + 0.2 * k), T(x: 0.45 + 0.05 * k, y: 0.3 + 0.2 * k),
                        T(x: 0.55 - 0.05 * k, y: 0.3 + 0.2 * k), T(x: 0.7 - 0.15 * k, y: 0.3 + 0.2 * k)]
            if let d = s.frame(hand) { fired.append(d) }
        }
        XCTAssertEqual(fired, [])
    }

    /// System Settings › Trackpad › Mission Control unticked: the vertical swipe stays on for App
    /// Exposé, but the Dock's own switch says Mission Control isn't on it.
    func testNoSwipeWhenTheTrackpadSettingsKeepMissionControlOff() {
        XCTAssertEqual(FingerSwipe.fingerCounts(threeFingers: 2, fourFingers: 2, threeFingerDrag: false, missionControlGesture: false), [])
        XCTAssertEqual(FingerSwipe.fingerCounts(threeFingers: 2, fourFingers: 2, threeFingerDrag: false, missionControlGesture: true), [3, 4])
        XCTAssertEqual(FingerSwipe.fingerCounts(threeFingers: nil, fourFingers: nil, threeFingerDrag: false), [4], "missing means on")
    }

    func testFingerCountsFollowTheTrackpadSettings() {
        XCTAssertEqual(FingerSwipe.fingerCounts(threeFingers: 2, fourFingers: 2, threeFingerDrag: false), [3, 4])
        XCTAssertEqual(FingerSwipe.fingerCounts(threeFingers: 0, fourFingers: 2, threeFingerDrag: false), [4])
        XCTAssertEqual(FingerSwipe.fingerCounts(threeFingers: 2, fourFingers: 0, threeFingerDrag: false), [3])
        XCTAssertEqual(FingerSwipe.fingerCounts(threeFingers: 2, fourFingers: 0, threeFingerDrag: true), [], "three fingers drag windows")
        XCTAssertEqual(FingerSwipe.fingerCounts(threeFingers: nil, fourFingers: nil, threeFingerDrag: false), [4], "macOS's defaults")
        XCTAssertEqual(FingerSwipe.fingerCounts(threeFingers: 0, fourFingers: 0, threeFingerDrag: false), [], "both off: no swipe")
    }
}
