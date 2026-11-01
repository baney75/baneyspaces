import XCTest
@testable import BaneySpacesCore

/// 11-01: `BaneySpaces --render` crash-looped (EXC_BREAKPOINT, index out of range in
/// `Render.run`) on a sample with every window on workspace 1. It dragged `tiles[2]![0]`.
final class ProductRenderPlanTests: XCTestCase {
    func testTheStandardSampleStillDragsMailFromWorkspaceTwo() throws {
        let tiles = ProductRenderPlan.tiles(from: ProductRenderPlan.windows(.standard))
        let source = try XCTUnwrap(ProductRenderPlan.dragSource(in: tiles))
        XCTAssertEqual(source.workspace, 2)
        XCTAssertEqual(source.entry.app, "Mail")
    }

    /// The crash: workspace 2 is there but empty. The old code indexed it anyway.
    func testAnEmptyWorkspaceTwoDragsFromTheLowestWorkspaceWithAWindow() throws {
        let tiles = ProductRenderPlan.tiles(from: [1: ["Safari", "Notes"], 4: ["Messages"]])
        XCTAssertEqual(tiles[2], [])
        let source = try XCTUnwrap(ProductRenderPlan.dragSource(in: tiles))
        XCTAssertEqual(source.workspace, 1)
        XCTAssertEqual(source.entry, "Safari")
    }

    func testTheReportedSampleHasSevenWindowsOnWorkspaceOneOnly() throws {
        XCTAssertEqual(ProductRenderPlan.sample(named: "reported"), .reported)
        let tiles = ProductRenderPlan.tiles(from: ProductRenderPlan.windows(.reported))
        XCTAssertEqual(tiles[1]?.count, 7)
        for n in 2...9 { XCTAssertEqual(tiles[n]?.count, 0, "workspace \(n)") }
        let source = try XCTUnwrap(ProductRenderPlan.dragSource(in: tiles))
        XCTAssertEqual(source.workspace, 1)
        XCTAssertEqual(source.entry, tiles[1]?.first)
    }

    func testNoWindowsAnywhereMeansNoDrag() {
        XCTAssertNil(ProductRenderPlan.dragSource(in: ProductRenderPlan.tiles(from: [Int: [String]]())))
        XCTAssertNil(ProductRenderPlan.dragSource(in: [Int: [String]]()))
    }

    /// The source is looked up on the tiles as they are when the shot is drawn, not as planned.
    func testWorkspaceTwoEmptiedOrRemovedAfterThePlan() throws {
        var tiles = ProductRenderPlan.tiles(from: [1: ["Safari"], 2: ["Mail"]])
        tiles[2] = []
        XCTAssertEqual(try XCTUnwrap(ProductRenderPlan.dragSource(in: tiles)).entry, "Safari")
        tiles[2] = nil
        XCTAssertEqual(try XCTUnwrap(ProductRenderPlan.dragSource(in: tiles)).entry, "Safari")
        tiles[1] = []
        XCTAssertNil(ProductRenderPlan.dragSource(in: tiles))
    }

    func testTilesCoverEveryWorkspaceAndNothingElse() {
        let tiles = ProductRenderPlan.tiles(from: [1: ["a"], 12: ["stray"], 0: ["stray"]])
        XCTAssertEqual(Set(tiles.keys), Set(Workspaces.range))
        XCTAssertEqual(tiles[1], ["a"])
    }

    func testAnUnknownSampleNameDrawsTheStandardSample() {
        XCTAssertEqual(ProductRenderPlan.sample(named: nil), .standard)
        XCTAssertEqual(ProductRenderPlan.sample(named: "nope"), .standard)
    }

    /// The render lives in the app target, which tests can't import, so this reads the source.
    func testRenderNeverIndexesTheViewerTiles() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BaneySpaces/Render.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
            .split(separator: "\n").map { $0.components(separatedBy: "//")[0] }.joined(separator: "\n")
        XCTAssertFalse(text.contains("model.tiles["), "the render must take its drag source from ProductRenderPlan.dragSource")
        XCTAssertTrue(text.contains("ProductRenderPlan.dragSource(in: model.tiles)"))
    }
}
