import CoreGraphics
import XCTest
@testable import BaneySpacesCore

/// Donovan, 2026-10-17: a file dragged from another app to the dock's edge never brought the
/// dock up, so there was no way to reach a window on another workspace to drop it in.
final class DockFileDragTests: XCTestCase {
    func testAPressWithoutADragIsNotOne() {
        var d = OutsideDrag()
        d.update(buttonsDown: false) { 7 }
        XCTAssertFalse(d.update(buttonsDown: true) { 7 })
        XCTAssertFalse(d.update(buttonsDown: true) { 7 })
    }

    func testTheDragPasteboardChangingWhileDownIsADrag() {
        var d = OutsideDrag()
        d.update(buttonsDown: false) { 7 }
        d.update(buttonsDown: true) { 7 }
        XCTAssertTrue(d.update(buttonsDown: true) { 8 })
        // Still on while the button stays down, even with no further change.
        XCTAssertTrue(d.update(buttonsDown: true) { 8 })
        XCTAssertFalse(d.update(buttonsDown: false) { 8 })
    }

    /// Review r1: a flick that starts the drag before the first tick with the button down.
    func testADragAlreadyStartedOnTheFirstDownTickCounts() {
        var d = OutsideDrag()
        d.update(buttonsDown: false) { 7 }
        XCTAssertTrue(d.update(buttonsDown: true) { 8 })
    }

    func testTheNextPressStartsFromTheLastDragsCount() {
        var d = OutsideDrag()
        d.update(buttonsDown: false) { 7 }
        XCTAssertTrue(d.update(buttonsDown: true) { 8 })
        d.update(buttonsDown: false) { 8 }
        XCTAssertFalse(d.update(buttonsDown: true) { 8 })
    }

    /// Review r2, r3: a write after the buttons went up (a drop finishing late) isn't the next
    /// drag, even when the next press comes on the very next tick.
    func testALateWriteWhileUpIsNotTheNextDrag() {
        var d = OutsideDrag()
        d.update(buttonsDown: false) { 7 }
        d.update(buttonsDown: false) { 8 }
        XCTAssertFalse(d.update(buttonsDown: true) { 8 })
    }


    let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
    let ghostty = URL(fileURLWithPath: "/Applications/Ghostty.app")
    /// Bundle identifiers by app name, as `Bundle(url:)` would read them.
    func identify(_ app: URL) -> String? {
        ["Preview": "com.apple.Preview", "Ghostty": "com.mitchellh.ghostty", "Safari": "com.apple.Safari"][app.deletingPathExtension().lastPathComponent]
    }

    /// Review r2: an icon takes a drop only when its app can open everything dropped.
    func testAnAppTakesOnlyWhatItCanOpen() {
        let png = URL(fileURLWithPath: "/tmp/a.png"), pdf = URL(fileURLWithPath: "/tmp/b.pdf")
        let both = DockOpen.apps(openingAll: [png, pdf], handlers: { _ in [self.preview] }, identify: identify)
        XCTAssertEqual(both, ["com.apple.Preview"])
        XCTAssertFalse(both.contains("com.mitchellh.ghostty"))
        XCTAssertEqual(DockOpen.apps(openingAll: [], handlers: { _ in [self.preview] }, identify: identify), [])
        let mixed = DockOpen.apps(openingAll: [png, pdf], handlers: { $0 == png ? [self.preview] : [] }, identify: identify)
        XCTAssertEqual(mixed, [])
    }

    /// Review r4: LaunchServices lists Safari in its Cryptex, a quarantined app at its real
    /// path while it runs translocated. The same bundle identifier is the same app.
    func testTheSameAppAtAnotherPathStillCounts() {
        let registered = URL(fileURLWithPath: "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app")
        let link = URL(string: "https://example.com")!
        let ids = DockOpen.apps(openingAll: [link], handlers: { _ in [registered] }, identify: identify)
        XCTAssertTrue(ids.contains("com.apple.Safari"))
    }

    func testOneLookupPerKindOfFile() {
        var asked = 0
        let urls = (0..<50).map { URL(fileURLWithPath: "/tmp/\($0).png") } + [URL(fileURLWithPath: "/tmp/x.PDF")]
        _ = DockOpen.apps(openingAll: urls, handlers: { _ in asked += 1; return [self.preview] }, identify: identify)
        XCTAssertEqual(asked, 2)
    }

    let frames: [String: CGRect] = [
        "tile:1": CGRect(x: 0, y: 0, width: 64, height: 64),
        "1:501": CGRect(x: 4, y: 4, width: 28, height: 28),
        "tile:3": CGRect(x: 72, y: 0, width: 64, height: 64),
        "more:3": CGRect(x: 100, y: 30, width: 24, height: 24),
        "btn:new": CGRect(x: 144, y: 0, width: 48, height: 64),
    ]

    func testAnIconWinsOverItsTile() {
        XCTAssertEqual(DockSpringTarget.at(CGPoint(x: 10, y: 10), frames: frames), .app(workspace: 1, id: "501"))
    }

    func testBetweenIconsIsTheTile() {
        XCTAssertEqual(DockSpringTarget.at(CGPoint(x: 50, y: 50), frames: frames), .tile(1))
        // The "+N" isn't an app; it counts as its tile.
        XCTAssertEqual(DockSpringTarget.at(CGPoint(x: 110, y: 40), frames: frames), .tile(3))
    }

    func testButtonsAndGapsAreNothing() {
        XCTAssertNil(DockSpringTarget.at(CGPoint(x: 160, y: 30), frames: frames))
        XCTAssertNil(DockSpringTarget.at(CGPoint(x: 68, y: 30), frames: frames))
    }

    func testSpringsOnceAfterResting() {
        var s = SpringLoad()
        let t0 = Date()
        XCTAssertNil(s.update(.tile(3), now: t0))
        XCTAssertNil(s.update(.tile(3), now: t0.addingTimeInterval(SpringLoad.delay - 0.05)))
        XCTAssertEqual(s.update(.tile(3), now: t0.addingTimeInterval(SpringLoad.delay)), .tile(3))
        XCTAssertNil(s.update(.tile(3), now: t0.addingTimeInterval(5)))
    }

    func testMovingToAnotherTargetStartsTheWaitAgain() {
        var s = SpringLoad()
        let t0 = Date()
        _ = s.update(.tile(3), now: t0)
        XCTAssertNil(s.update(.app(workspace: 3, id: "9"), now: t0.addingTimeInterval(0.5)))
        XCTAssertNil(s.update(.app(workspace: 3, id: "9"), now: t0.addingTimeInterval(0.9)))
        XCTAssertEqual(s.update(.app(workspace: 3, id: "9"), now: t0.addingTimeInterval(1.1)), .app(workspace: 3, id: "9"))
    }

    func testNothingUnderTheDragNeverSprings() {
        var s = SpringLoad()
        let t0 = Date()
        _ = s.update(nil, now: t0)
        XCTAssertNil(s.update(nil, now: t0.addingTimeInterval(3)))
    }
}
