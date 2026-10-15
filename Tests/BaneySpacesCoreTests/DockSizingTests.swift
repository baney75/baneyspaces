import XCTest

/// The Workspace Dock crashed twice on 2026-10-14 ("more Update Constraints in Window passes than
/// there are views"): its NSHostingView set the panel's min and max size from inside a layout
/// pass. The dock sizes its own panel; SwiftUI may only report the size. The view code lives in
/// the app target, which tests can't import, so this reads the source.
final class DockSizingTests: XCTestCase {
    func testDockHostingViewLeavesWindowSizeToTheDock() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BaneySpaces/WorkspaceDock.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        XCTAssertTrue(text.contains("host.sizingOptions = [.intrinsicContentSize]"),
                      "the dock's NSHostingView must not size the panel (no .minSize/.maxSize)")
        XCTAssertTrue(text.contains("host.onSizeChange"), "the dock must re-frame itself when SwiftUI's size changes")
    }
}
