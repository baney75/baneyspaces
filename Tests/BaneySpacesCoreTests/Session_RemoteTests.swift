import XCTest
@testable import BaneySpacesCore

final class RemoteTests: XCTestCase {
    func testRemoteCallersCantTouchYourScreen() {
        XCTAssertTrue(Remote.allows(Wire.Request(op: .list)))
        XCTAssertTrue(Remote.allows(Wire.Request(op: .ping)))
        XCTAssertTrue(Remote.allows(Wire.Request(op: .agent, text: "run")))
        XCTAssertTrue(Remote.allows(Wire.Request(op: .agent, text: "open")))
        XCTAssertTrue(Remote.allows(Wire.Request(op: .agent)), "status by default")
        for op in [Wire.Request.Op.focus, .send, .open, .notify, .event, .remote] {
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

final class RemoteHardeningTests: XCTestCase {
    func testTheTokenNeverLeavesTheTailnet() {
        let start = Date()
        XCTAssertNil(Wire.callRemote(host: "127.0.0.1", Wire.Request(op: .ping, token: "secret"), timeout: 1),
                     "a non-tailnet address is refused before connecting")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    func testATricklingRequestHitsOneDeadline() {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        // A few bytes and no newline: the reader must give up at the deadline, not wait forever.
        _ = "{\"op\":".withCString { write(fds[1], $0, 6) }
        let start = Date()
        XCTAssertNil(Wire.readLine(fds[0], limit: 64 << 10, deadline: Date().addingTimeInterval(0.3)))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testAWholeLineArrivesBeforeTheDeadline() {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        _ = "{\"op\":\"ping\"}\n".withCString { write(fds[1], $0, 14) }
        XCTAssertEqual(Wire.readLine(fds[0], limit: 64 << 10, deadline: Date().addingTimeInterval(1)), Data("{\"op\":\"ping\"}".utf8))
    }
}
