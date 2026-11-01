import AppKit
import BaneySpacesCore
import XCTest
@testable import BaneySpacesCursor

/// The overlay's real layers. The panels are built but never put on screen (`ordersFront: false`), so nothing flashes
/// on the machine running the tests.
final class OverlayTests: XCTestCase {
    let first = CursorDisplaySpec(globalFrame: CGRect(x: 0, y: 0, width: 1000, height: 700), panelFrame: CGRect(x: 40000, y: 0, width: 1000, height: 700), scale: 2)
    let second = CursorDisplaySpec(globalFrame: CGRect(x: 1000, y: 0, width: 800, height: 600), panelFrame: CGRect(x: 42000, y: 0, width: 800, height: 600), scale: 2)
    let look = CursorLook(name: "Claude", status: .working, identity: CursorPalette.identityColor(for: "a"), theme: .standard)

    override func setUp() {
        _ = NSApplication.shared
    }

    func surface() -> OverlaySurface { OverlaySurface(displays: [first, second], ordersFront: false) }

    func testAMarkIsInsideItsContainerAfterTheFirstAttach() {
        let s = surface()
        s.configure("a", look: look)
        s.appear("a", at: CGPoint(x: 100, y: 100))
        XCTAssertTrue(s.marksAreAttached("a"), "the last-3 marks have somewhere to show")
        s.act("a", effect: .click, point: CGPoint(x: 100, y: 100), frame: CGRect(x: 80, y: 90, width: 40, height: 20), delay: 0)
        XCTAssertTrue(s.marksAreAttached("a"))
    }

    func testMovingToAnotherDisplayKeepsTheMarks() {
        let s = surface()
        s.configure("a", look: look)
        s.appear("a", at: CGPoint(x: 100, y: 100))
        s.jump("a", to: CGPoint(x: 1400, y: 300))
        XCTAssertTrue(s.isShown("a"))
        XCTAssertTrue(s.marksAreAttached("a"), "marks survive the move to the other display")
        s.act("a", effect: .type, point: CGPoint(x: 1400, y: 300), frame: CGRect(x: 1380, y: 290, width: 40, height: 20), delay: 0)
        XCTAssertTrue(s.marksAreAttached("a"))
    }

    func testACursorSurvivesAChangeOfDisplays() {
        let s = surface()
        s.configure("a", look: look)
        s.configure("b", look: CursorLook(name: "Grok", status: .asking, identity: .init(r: 1, g: 0, b: 0), theme: .omarchy))
        s.appear("a", at: CGPoint(x: 100, y: 100))
        s.appear("b", at: CGPoint(x: 1400, y: 300))
        s.setDisplays([second, first])   // plugged in a different order, same places
        XCTAssertEqual(s.cursorCount, 2, "the overlay keeps its cursors")
        XCTAssertTrue(s.isShown("a") && s.isShown("b"), "and they come back where they stood")
        XCTAssertTrue(s.marksAreAttached("a") && s.marksAreAttached("b"))
        s.setDisplays([first])   // one display unplugged: "b" stood on it
        XCTAssertEqual(s.cursorCount, 2)
        XCTAssertTrue(s.isShown("a"))
        XCTAssertFalse(s.isShown("b"), "a cursor on a display that is gone is hidden")
        s.appear("b", at: CGPoint(x: 200, y: 200))
        XCTAssertTrue(s.isShown("b"), "and can be drawn again by its next action")
        XCTAssertTrue(s.marksAreAttached("b"))
    }

    func testRemovingACursorTakesItsLayersOff() {
        let s = surface()
        s.configure("a", look: look)
        s.appear("a", at: CGPoint(x: 100, y: 100))
        let root = s.panels[0].contentView!.layer!
        XCTAssertGreaterThan(root.sublayers?.count ?? 0, 0)
        s.remove("a")
        XCTAssertEqual(s.cursorCount, 0)
        XCTAssertEqual(root.sublayers?.count ?? 0, 0)
    }

    func testThePanelsCanNeverBecomeKeyOrMainAndIgnoreTheMouse() {
        let s = surface()
        for p in s.panels {
            XCTAssertFalse(p.canBecomeKey)
            XCTAssertFalse(p.canBecomeMain)
            XCTAssertTrue(p.ignoresMouseEvents)
            XCTAssertFalse(p.isKeyWindow)
            XCTAssertEqual(p.sharingType, .none)
        }
    }

    func testAGlideIsOneKeyframeAnimationEndingOnTheTarget() {
        let s = surface()
        s.configure("a", look: look)
        s.appear("a", at: CGPoint(x: 100, y: 100))
        let plan = GlidePlan(from: GlideState(position: CGPoint(x: 100, y: 100)), target: CGPoint(x: 600, y: 400), spring: .baneyspaces)
        s.move("a", motion: CursorMotion(plan: plan, start: ProcessInfo.processInfo.systemUptime))
        XCTAssertTrue(s.isGliding("a"), "one animation on the cursor layer, run by the compositor")
    }

    func testWithMotionOffNothingScalesGrowsOrSquishes() {
        func scheduled(still: Bool) -> [String] {
            let s = surface()
            s.configure("a", look: CursorLook(name: "Claude", status: .working, identity: look.identity, theme: .standard, still: still))
            s.appear("a", at: CGPoint(x: 100, y: 100))
            s.act("a", effect: .click, point: CGPoint(x: 100, y: 100), frame: CGRect(x: 80, y: 90, width: 40, height: 20), delay: 0.1)
            s.act("a", effect: .scroll(dx: 0, dy: 1), point: CGPoint(x: 300, y: 300), frame: CGRect(x: 280, y: 290, width: 40, height: 20), delay: 0)
            return s.motionAnimationKeys("a")
        }
        XCTAssertFalse(scheduled(still: false).isEmpty, "the default theme pops, squishes, grows a ripple and draws a trail")
        XCTAssertEqual(scheduled(still: true), [], "with motion off only fades run")
    }

    func testAMarkOutsideTheCaptureDrawsNothing() throws {
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let ctx = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        let image = try XCTUnwrap(ctx.makeImage())
        let mark = CursorMark(look: look, point: CGPoint(x: 5000, y: 5000), windowFrame: CGRect(x: 0, y: 0, width: 100, height: 50), at: 0)
        XCTAssertNil(ShotComposite.draw(mark, onto: image, windowFrame: CGRect(x: 0, y: 0, width: 100, height: 50), scale: 2))
        let inside = CursorMark(look: look, point: CGPoint(x: 40, y: 20), windowFrame: CGRect(x: 0, y: 0, width: 100, height: 50), at: 0)
        let drawn = try XCTUnwrap(ShotComposite.draw(inside, onto: image, windowFrame: CGRect(x: 0, y: 0, width: 100, height: 50), scale: 2))
        XCTAssertEqual(drawn.width, 200)
        XCTAssertEqual(drawn.colorSpace?.name, image.colorSpace?.name, "the capture keeps its color space")
        XCTAssertEqual(drawn.bitmapInfo, image.bitmapInfo)
    }
}
