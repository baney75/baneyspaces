import XCTest
@testable import BaneySpacesCore

final class PhonesTests: XCTestCase {
    func testAdbTrackSplitsMessagesAndKeepsAPartialOne() {
        let first = "R5CT123\tdevice product:o1 model:Pixel_8 device:shiba transport_id:3\n"
        let second = "R5CT123\tunauthorized transport_id:4\n"
        var buf = Data((String(format: "%04x", first.utf8.count) + first + String(format: "%04x", second.utf8.count)).utf8)
        buf.append(Data(second.utf8.prefix(5)))
        let msgs = AdbTrack.messages(&buf)
        XCTAssertEqual(msgs, [first])
        XCTAssertEqual(buf.count, 4 + 5, "the half-received second message (header and 5 bytes) waits for the rest")
        let p = AdbTrack.phones(msgs[0])
        XCTAssertEqual(p.first?.name, "Pixel 8")
        XCTAssertEqual(p.first?.ready, true)
        buf.append(Data(second.utf8.dropFirst(5)))
        let later = AdbTrack.phones(AdbTrack.messages(&buf)[0])
        XCTAssertEqual(later.first?.ready, false)
        XCTAssertEqual(later.first?.status, "allow USB debugging on the phone")
        XCTAssertEqual(AdbTrack.phones(""), [], "an empty message means every phone left")
    }

    func testDeviceCtlListsPairedPhonesAndBootedSimulatorsOnly() {
        let json = #"""
        {"result":{"devices":[
          {"identifier":"3F42","deviceProperties":{"name":"Magnus_Net 15+"},"hardwareProperties":{"marketingName":"iPhone 15 Plus","reality":"physical"},
           "connectionProperties":{"tunnelState":"connected","transportType":"wired"}},
          {"identifier":"AAAA","deviceProperties":{"name":"Old"},"hardwareProperties":{"marketingName":"iPhone 12","reality":"physical"},
           "connectionProperties":{"tunnelState":"unavailable","transportType":"localNetwork"}},
          {"identifier":"7CCA","deviceProperties":{"name":"iPhone 17 Pro","bootState":"shutdown"},"hardwareProperties":{"marketingName":"iPhone 17 Pro","reality":"simulated"},
           "connectionProperties":{"tunnelState":"disconnected","transportType":"sameMachine"}},
          {"identifier":"9B32","deviceProperties":{"name":"iPhone 17 Pro","bootState":"booted"},"hardwareProperties":{"marketingName":"iPhone 17 Pro","reality":"simulated"},
           "connectionProperties":{"tunnelState":"disconnected","transportType":"sameMachine"}}
        ]}}
        """#
        let p = DeviceCtl.phones(Data(json.utf8))
        XCTAssertEqual(p.map(\.id), ["3F42", "AAAA", "9B32"])
        XCTAssertEqual(p[0].status, "USB")
        XCTAssertTrue(p[0].ready)
        XCTAssertEqual(p[1].status, "out of reach")
        XCTAssertFalse(p[1].ready)
        XCTAssertTrue(p[2].simulator && p[2].ready)
        XCTAssertEqual(p[0].item.id, "ios:3F42")
        XCTAssertEqual(p[0].item.role, .device)
        XCTAssertEqual(DeviceCtl.phones(Data("garbage".utf8)), [])
    }
}

final class AdbInputTests: XCTestCase {
    func testTextCantRunAnythingOnThePhone() {
        XCTAssertEqual(AdbTrack.inputText("hello world"), "'hello%sworld'")
        XCTAssertEqual(AdbTrack.inputText("it's"), #"'it'\''s'"#)
        // Command substitution stays literal inside single quotes.
        XCTAssertEqual(AdbTrack.inputText("$(reboot)"), "'$(reboot)'")
        XCTAssertEqual(AdbTrack.inputText("a;b|c&d"), "'a;b|c&d'")
    }
}
