import XCTest
@testable import BaneySpacesCore

final class RemoteTests: XCTestCase {
    func testRemoteCallersCantTouchYourScreen() {
        XCTAssertTrue(Remote.allows(Wire.Request(op: .list)))
        XCTAssertTrue(Remote.allows(Wire.Request(op: .ping)))
        XCTAssertTrue(Remote.allows(Wire.Request(op: .agent, text: "run")))
        XCTAssertTrue(Remote.allows(Wire.Request(op: .agent, text: "open")))
        XCTAssertTrue(Remote.allows(Wire.Request(op: .agent)), "status by default")
        for op in [Wire.Request.Op.focus, .send, .open, .notify, .tile, .layout, .sidebar, .palette, .event, .remote] {
            XCTAssertFalse(Remote.allows(Wire.Request(op: op)), "\(op) changes what you see")
        }
        for sub in ["on", "off", "move", "anything"] {
            XCTAssertFalse(Remote.allows(Wire.Request(op: .agent, text: sub)), "agent \(sub)")
        }
    }

    func testOnlyTailnetAddresses() {
        XCTAssertTrue(Remote.isTailnet("100.107.206.73"))
        XCTAssertTrue(Remote.isTailnet("100.64.0.1"))
        XCTAssertFalse(Remote.isTailnet("100.128.0.1"))
        XCTAssertFalse(Remote.isTailnet("192.168.1.10"))
        XCTAssertFalse(Remote.isTailnet("0.0.0.0"))
        XCTAssertFalse(Remote.isTailnet("not an ip"))
    }

    func testTokens() {
        let t = Remote.newToken()
        XCTAssertEqual(t.count, 64)
        XCTAssertNotEqual(t, Remote.newToken())
        XCTAssertTrue(Remote.tokensMatch(t, t))
        XCTAssertFalse(Remote.tokensMatch(t, String(t.dropLast()) + "x"))
        XCTAssertFalse(Remote.tokensMatch("", ""), "an empty token never matches")
        XCTAssertFalse(Remote.tokensMatch(t, String(t.prefix(10))))
    }

    func testTokenTravelsInTheRequest() throws {
        let r = Wire.Request(op: .agent, text: "run", args: ["--", "claude"], token: "abc")
        XCTAssertEqual(try JSONDecoder().decode(Wire.Request.self, from: JSONEncoder().encode(r)).token, "abc")
    }
}
