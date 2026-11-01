import CoreGraphics
import XCTest
@testable import BaneySpacesCore

/// Donovan, 2026-10-31: an app in the "+N" list on a workspace tile drags like the tile's own icons.
/// The drop decision is the same `DockDrop.target` (a row's drag starts on its tile's workspace), so
/// these pin what it gives for the layouts a list sits in: a bottom dock, a side dock, and the
/// dashed "+" tile. The view wiring is a source check, since tests can't import the app target.
final class DockOverflowDragTests: XCTestCase {
    // A bottom dock, as drawn: tiles 1, 2 and 4 (64 wide, 8 apart), then the dashed "+" for the
    // first empty workspace, 3, in a slimmer slot (48 wide). The "+N" list floats above the bar.
    let tiles: [Int: CGRect] = [
        1: CGRect(x: 0, y: 40, width: 64, height: 64),
        2: CGRect(x: 72, y: 40, width: 64, height: 64),
        4: CGRect(x: 144, y: 40, width: 64, height: 64),
    ]
    let plus = (workspace: 3, frame: CGRect(x: 216, y: 40, width: 48, height: 64))
    /// The list above tile 2, 8 pt over the bar.
    let list = CGRect(x: 40, y: -190, width: 240, height: 142)

    func testARowDroppedOnThePlusTileGoesToTheFirstEmptyWorkspace() {
        // From workspace 2, whose "+N" list the row was in.
        XCTAssertEqual(DockDrop.target(at: CGPoint(x: 240, y: 70), from: 2, tiles: tiles, empty: plus), 3)
    }

    func testARowDroppedOnAnotherTileGoesToThatWorkspace() {
        XCTAssertEqual(DockDrop.target(at: CGPoint(x: 30, y: 70), from: 2, tiles: tiles, empty: plus), 1)
        XCTAssertEqual(DockDrop.target(at: CGPoint(x: 170, y: 70), from: 2, tiles: tiles, empty: plus), 4)
    }

    func testARowDroppedBackOnItsOwnTileOrItsListMovesNothing() {
        XCTAssertNil(DockDrop.target(at: CGPoint(x: 100, y: 70), from: 2, tiles: tiles, empty: plus), "its own tile")
        XCTAssertNil(DockDrop.target(at: CGPoint(x: list.midX, y: list.midY), from: 2, tiles: tiles, empty: plus), "the list it came from")
    }

    func testThePlusTileHasNoRoomOfItsOwnWithoutAnEmptyWorkspace() {
        // Every workspace in use: no "+" is drawn, so its slot is no target.
        XCTAssertNil(DockDrop.target(at: CGPoint(x: 240, y: 70), from: 2, tiles: tiles, empty: nil))
    }

    func testAWorkspaceThatEmptiedIsNoTargetForItself() {
        // The "+" stands for workspace 3; a row dragged from 3 (a stale list) must not "move" to 3.
        XCTAssertNil(DockDrop.target(at: CGPoint(x: 240, y: 70), from: 3, tiles: tiles, empty: plus))
    }

    func testASideDockHasTheSameDecisionAlongTheOtherAxis() {
        // Tiles stacked down the left edge; the list sits beside them, on the screen side.
        let column: [Int: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 64, height: 64),
            2: CGRect(x: 0, y: 72, width: 64, height: 64),
        ]
        let plusDown = (workspace: 3, frame: CGRect(x: 0, y: 144, width: 64, height: 48))
        XCTAssertEqual(DockDrop.target(at: CGPoint(x: 30, y: 170), from: 2, tiles: column, empty: plusDown), 3)
        XCTAssertNil(DockDrop.target(at: CGPoint(x: 150, y: 100), from: 2, tiles: column, empty: plusDown), "over the list beside the bar")
    }

    // The app target can't be imported, so the wiring is read from the source.
    private func dockSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BaneySpaces/WorkspaceDock.swift")
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").map { $0.components(separatedBy: "//")[0] }.joined(separator: "\n")
    }

    func testEachRowOfTheMoreListDragsLikeATileIcon() throws {
        let text = try dockSource()
        let start = try XCTUnwrap(text.range(of: "private struct MoreRow"))
        let row = String(text[start.lowerBound...].prefix(2200))
        XCTAssertTrue(row.contains("DragGesture(minimumDistance: 4, coordinateSpace: .named(\"dock\"))"), "the same drag the icons use")
        XCTAssertTrue(row.contains(".simultaneousGesture(TapGesture().onEnded(action))"), "a click without a drag still goes to the app")
        XCTAssertFalse(row.contains(".onTapGesture(perform: action)"), "a tap handler would swallow the press a drag needs")
        let list = try XCTUnwrap(text.range(of: "private func moreList("))
        let body = String(text[list.lowerBound...].prefix(2600))
        XCTAssertTrue(body.contains("model.dragged(ids, from: tile.id"), "a row drags all of its app's windows on that workspace")
        XCTAssertTrue(body.contains("model.endDrag()"))
        XCTAssertTrue(body.contains("guard model.clickCounts"), "the mouse-up that ends a drag isn't a click")
    }

    func testTheListClosesWhenADropMovedItsApp() throws {
        let text = try dockSource()
        let end = try XCTUnwrap(text.range(of: "func endDrag()"))
        let body = String(text[end.lowerBound...].prefix(700))
        XCTAssertTrue(body.contains("more = nil"), "the list was the source workspace's, so a move closes it")
        XCTAssertTrue(body.contains("onMove(drag.ids, to)"))
    }
}
