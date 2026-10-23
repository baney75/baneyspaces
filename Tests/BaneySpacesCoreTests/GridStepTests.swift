import XCTest
@testable import BaneySpacesCore

final class GridStepTests: XCTestCase {
    func testStepsLikeTheNumberKeys() {
        XCTAssertEqual(GridStep.right.from(5), 6)
        XCTAssertEqual(GridStep.left.from(5), 4)
        XCTAssertEqual(GridStep.up.from(5), 2)
        XCTAssertEqual(GridStep.down.from(5), 8)
    }

    func testStopsAtTheEdges() {
        XCTAssertEqual(GridStep.left.from(4), 4)
        XCTAssertEqual(GridStep.right.from(3), 3)
        XCTAssertEqual(GridStep.up.from(2), 2)
        XCTAssertEqual(GridStep.down.from(9), 9)
    }
}
