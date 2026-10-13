import CoreGraphics
import XCTest
@testable import BaneySpacesCore

final class DockDropTests: XCTestCase {
    // Three tiles in a row, 64 wide with 8 between them, as the bottom dock draws them.
    let tiles: [Int: CGRect] = [
        1: CGRect(x: 0, y: 0, width: 64, height: 64),
        3: CGRect(x: 72, y: 0, width: 64, height: 64),
        5: CGRect(x: 144, y: 0, width: 64, height: 64),
    ]

    func testLandsOnTheTileUnderThePointer() {
        XCTAssertEqual(DockDrop.target(at: CGPoint(x: 100, y: 30), from: 1, tiles: tiles), 3)
    }

    func testTheWorkspaceItCameFromIsNoTarget() {
        XCTAssertNil(DockDrop.target(at: CGPoint(x: 30, y: 30), from: 1, tiles: tiles))
    }

    func testOutsideEveryTileIsNoTarget() {
        XCTAssertNil(DockDrop.target(at: CGPoint(x: 100, y: 120), from: 1, tiles: tiles))
    }

    func testTheGapBetweenTilesGoesToTheCloserOne() {
        XCTAssertEqual(DockDrop.target(at: CGPoint(x: 66, y: 30), from: 5, tiles: tiles), 1)
        XCTAssertEqual(DockDrop.target(at: CGPoint(x: 70, y: 30), from: 5, tiles: tiles), 3)
    }

    func testTheEmptyWorkspaceButtonSendsToItsWorkspace() {
        let empty = (workspace: 2, frame: CGRect(x: 216, y: 0, width: 48, height: 64))
        XCTAssertEqual(DockDrop.target(at: CGPoint(x: 240, y: 30), from: 1, tiles: tiles, empty: empty), 2)
    }

    func testAWorkspaceOutsideOneToNineIsNoTarget() {
        XCTAssertNil(DockDrop.target(at: CGPoint(x: 10, y: 10), from: 1, tiles: [12: CGRect(x: 0, y: 0, width: 64, height: 64)]))
    }
}
