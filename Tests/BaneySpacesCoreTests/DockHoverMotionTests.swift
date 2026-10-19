import XCTest

/// Hovering a dock tile slid it sideways over its neighbors (Donovan, 2026-10-19). Each tile, icon
/// and button had `.animation(_, value: hovered)`, which animates every change in that update,
/// including the re-centering when the hover label widens the dock. Hover may animate only its
/// scale, through `HoverScale`. The view code lives in the app target, which tests can't import,
/// so this reads the source.
final class DockHoverMotionTests: XCTestCase {
    func testHoverAnimatesOnlyTheScale() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BaneySpaces/WorkspaceDock.swift")
        // Code only: a comment that names the old pattern must not fail.
        let text = try String(contentsOf: source, encoding: .utf8)
            .split(separator: "\n").map { $0.components(separatedBy: "//")[0] }.joined(separator: "\n")
        XCTAssertFalse(text.contains("value: hovered)"),
                       "a hover animation on a whole view also slides it when the dock re-lays out; use HoverScale")
        XCTAssertGreaterThanOrEqual(text.components(separatedBy: ".modifier(HoverScale(").count - 1, 3,
                                    "tiles, app icons and the small buttons each grow through HoverScale")
        XCTAssertTrue(text.contains("content.animation(spring) { $0.scaleEffect(scale, anchor: anchor) }"),
                      "HoverScale must scope its spring to the scale effect")
    }
}
