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
        let body = String(text[end.lowerBound...].prefix(1300))
        XCTAssertTrue(body.contains("more = nil"), "the list was the source workspace's, so a move closes it")
        XCTAssertTrue(body.contains("onMove(alive, to)"))
    }

    // Review of #100 (G4): a drag started on a "+N" row outlives the row. When the row goes (its
    // window closed, its app quit, its tile refreshed) SwiftUI drops the gesture without its end.

    func testADragWhoseWindowsAreAllGoneIsOrphaned() {
        XCTAssertTrue(DockDrop.isOrphaned(ids: [11, 12], alive: [30, 31], rowShown: true), "closed or moved elsewhere")
        XCTAssertTrue(DockDrop.isOrphaned(ids: [11], alive: [], rowShown: nil), "the workspace emptied")
    }

    func testADragKeepsGoingWhileAWindowAndItsRowRemain() {
        XCTAssertFalse(DockDrop.isOrphaned(ids: [11, 12], alive: [12, 30], rowShown: true))
        XCTAssertFalse(DockDrop.isOrphaned(ids: [11], alive: [11], rowShown: nil), "a tile icon has no row to lose")
    }

    func testADragFromAListRowIsOrphanedOnceTheRowIsGone() {
        // The windows are alive, but the row and its gesture are not: nothing will end this drag.
        XCTAssertTrue(DockDrop.isOrphaned(ids: [11], alive: [11], rowShown: false))
    }

    func testOnlyTheSurvivingWindowsAreMoved() {
        XCTAssertEqual(DockDrop.survivors(of: [11, 12, 13], alive: [13, 11, 40]), [11, 13])
        XCTAssertEqual(DockDrop.survivors(of: [11], alive: []), [])
    }

    func testAnOrphanedDragMovesNothingAndLeavesNoTarget() throws {
        let text = try dockSource()
        let tick = try XCTUnwrap(text.range(of: "if model.dragOrphaned(refresh: fresh) {"))
        XCTAssertTrue(text[tick.upperBound...].prefix(160).contains("model.cancelDrag()"), "the tick ends an orphaned drag")
        let pinned = try XCTUnwrap(text.range(of: "guard !pinned else { return }"))
        XCTAssertLessThan(tick.lowerBound, pinned.lowerBound, "...before the pinned dock returns early")
        let end = try XCTUnwrap(text.range(of: "func endDrag()"))
        let body = String(text[end.lowerBound...].prefix(900))
        XCTAssertTrue(body.contains("DockDrop.survivors(of: drag.ids, alive: liveWindows(drag.from, true))"), "the drop reads the live window list")
        XCTAssertTrue(body.contains("alive.isEmpty ? nil : dropTarget"), "no windows left, no target")
        XCTAssertTrue(body.contains("onMove(alive, to)"), "only a window that still exists moves")
        // Cancelling clears the drag, and with it the drop target the badge and label read.
        let cancel = try XCTUnwrap(text.range(of: "func cancelDrag()"))
        XCTAssertTrue(text[cancel.upperBound...].prefix(200).contains("drag = nil"))
    }

    func testTheListHeaderAndBadgeReadATargetOnlyForADragFromThisTile() throws {
        let text = try dockSource()
        let list = try XCTUnwrap(text.range(of: "private func moreList("))
        let body = String(text[list.lowerBound...].prefix(2600))
        XCTAssertTrue(body.contains("let dragHere = model.drag?.from == tile.id"))
        XCTAssertTrue(body.contains("WorkspaceBadge(n: (dragHere ? model.dropTarget : nil) ?? tile.id"), "no stale target beside \"N more\"")
        XCTAssertTrue(body.contains("listApp: app.id"), "the drag knows which app's row it began on")
    }

    // Review of #102 round 1.

    func testACancelledDragStaysCancelledWhileTheGestureLivesOn() {
        // F1: the gesture keeps reporting moves; without this each one starts the drag again.
        var cancel = DragCancel()
        XCTAssertFalse(cancel.blocks([11, 12]))
        cancel.cancelled([11, 12])
        XCTAssertTrue(cancel.blocks([11, 12]), "the same gesture's next move starts nothing")
        XCTAssertFalse(cancel.blocks([30]), "another drag is its own")
        cancel.released()
        XCTAssertFalse(cancel.blocks([11, 12]), "a new press may drag the same app again")
    }

    func testTheDockWiresTheCancelIntoDraggedAndReleasesItWhenThePressEnds() throws {
        let text = try dockSource()
        let moved = try XCTUnwrap(text.range(of: "func dragged(_ ids"))
        XCTAssertTrue(text[moved.lowerBound...].prefix(500).contains("guard !cancelled.blocks(ids) else { return }"))
        let cancel = try XCTUnwrap(text.range(of: "func cancelDrag()"))
        XCTAssertTrue(text[cancel.upperBound...].prefix(200).contains("cancelled.cancelled(d.ids)"))
        XCTAssertTrue(text.contains("if !pressed { model.cancelled.released() }"), "buttons up ends the press")
    }

    func testTheTickReadsTheWindowListFreshWhileADragIsInFlight() throws {
        // F5: reloads wait out a drag, so the cached list never shows a closed window.
        XCTAssertTrue(DockDrop.freshReadDue(now: 10, last: nil))
        XCTAssertFalse(DockDrop.freshReadDue(now: 10.2, last: 10))
        XCTAssertTrue(DockDrop.freshReadDue(now: 10.5, last: 10))
        let text = try dockSource()
        XCTAssertTrue(text.contains("model.dragOrphaned(refresh: fresh)"))
        XCTAssertTrue(text.contains("DockDrop.freshReadDue(now:"))
    }

    func testAnotherTilesListIsNotTheRowTheDragBeganOn() {
        // #103: the drag began on tile 2's list; tile 4's list took its place. That is not the row
        // the gesture is on, even when it lists the same app.
        XCTAssertTrue(DockDrop.rowStillShown(app: "x", from: 2, list: (tile: 2, apps: ["x", "y"])))
        XCTAssertFalse(DockDrop.rowStillShown(app: "x", from: 2, list: (tile: 4, apps: ["x"])), "same app, another tile's list")
        XCTAssertFalse(DockDrop.rowStillShown(app: "x", from: 2, list: (tile: 4, apps: ["y"])))
        XCTAssertFalse(DockDrop.rowStillShown(app: "x", from: 2, list: nil))
        XCTAssertFalse(DockDrop.rowStillShown(app: "x", from: 2, list: (tile: 2, apps: ["y"])), "the app left the list")
    }

    func testTheOrphanCheckComesBeforeSpringLoadAndClearsTheHold() throws {
        let text = try dockSource()
        let orphan = try XCTUnwrap(text.range(of: "if model.dragOrphaned(refresh: fresh) {"))
        let spring = try XCTUnwrap(text.range(of: "springLoad(carrying)\n        guard !pinned"))
        XCTAssertLessThan(orphan.lowerBound, spring.lowerBound)
        let cancel = try XCTUnwrap(text.range(of: "func cancelDrag()"))
        let body = String(text[cancel.upperBound...].prefix(300))
        XCTAssertTrue(body.contains("heldTarget = nil") && body.contains("dwell?.cancel()"), "a cancelled drag leaves no hold behind")
        XCTAssertTrue(text.contains("DockDrop.rowStillShown(app: $0, from: d.from, list: shown)"))
    }

    func testARowKeepsItsDragWhenOneOfItsWindowsCloses() throws {
        // F3: the row is the app's; it outlives a window, and the survivors move.
        XCTAssertFalse(DockDrop.isOrphaned(ids: [11, 12], alive: [12], rowShown: true))
        XCTAssertEqual(DockDrop.survivors(of: [11, 12], alive: [12]), [12])
        let text = try dockSource()
        XCTAssertTrue(text.contains("let row: Bool? = d.listApp.map"), "row identity (app and tile), not exact window ids")
        XCTAssertFalse(text.contains("list.map(\\.id) == d.ids"))
    }
}
