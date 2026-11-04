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

    /// Donovan's Mac on 2026-10-16: wayside1 sat on the same Wi-Fi with its tunnel idle and read
    /// "not connected", though devicectl reached it in 3 s. The iPad was off the network.
    func testIdleWiFiTunnelIsReadyAndAnIPadIsAnIPad() {
        let json = #"""
        {"result":{"devices":[
          {"identifier":"B946","deviceProperties":{"name":"iPad"},"hardwareProperties":{"marketingName":"iPad Pro (12.9-inch) (5th generation)","deviceType":"iPad","reality":"physical"},
           "connectionProperties":{"pairingState":"paired","tunnelState":"unavailable"}},
          {"identifier":"3F42","deviceProperties":{"name":"wayside1"},"hardwareProperties":{"marketingName":"iPhone 15 Plus","deviceType":"iPhone","reality":"physical"},
           "connectionProperties":{"pairingState":"paired","tunnelState":"disconnected","transportType":"localNetwork"}},
          {"identifier":"C0DE","deviceProperties":{"name":"Loaner"},"hardwareProperties":{"marketingName":"iPhone 16","deviceType":"iPhone","reality":"physical"},
           "connectionProperties":{"pairingState":"unpaired","tunnelState":"disconnected","transportType":"wired"}},
          {"identifier":"D00D","deviceProperties":{"name":"Desk"},"hardwareProperties":{"marketingName":"iPhone 16","deviceType":"iPhone","reality":"physical"},
           "connectionProperties":{"pairingState":"paired","tunnelState":"disconnected","transportType":"wired"}},
          {"identifier":"5155","deviceProperties":{"name":"iPad Air","bootState":"booted"},"hardwareProperties":{"marketingName":"iPad Air","deviceType":"iPad","reality":"simulated"},
           "connectionProperties":{"tunnelState":"disconnected","transportType":"sameMachine"}}
        ]}}
        """#
        let p = DeviceCtl.phones(Data(json.utf8))
        XCTAssertEqual(p.count, 5)
        XCTAssertFalse(p[0].ready)
        XCTAssertEqual(p[0].status, "out of reach")
        XCTAssertTrue(p[0].tablet)
        XCTAssertEqual(p[0].item.appName, "iPad")
        XCTAssertTrue(p[1].ready, "an idle tunnel on Wi-Fi opens on first use")
        XCTAssertEqual(p[1].status, "Wi-Fi")
        XCTAssertEqual(p[1].item.detail, "iPhone 15 Plus")
        XCTAssertEqual(p[1].item.appName, "iPhone")
        XCTAssertFalse(p[2].ready)
        XCTAssertEqual(p[2].status, "not paired")
        XCTAssertTrue(p[3].ready, "an idle tunnel on USB opens on first use too")
        XCTAssertEqual(p[3].status, "USB")
        XCTAssertFalse(p[4].tablet, "an iPad simulator still opens in Simulator")
        XCTAssertTrue(p[4].ready)
    }

    /// Donovan, 2026-10-23: picking the iPad should open Device Hub on it. Device Hub's links take
    /// the hardware UDID; devicectl's own identifier opens nothing (tried live against vestry1).
    func testAnIPadOpensInDeviceHubByItsUDID() {
        let json = #"""
        {"result":{"devices":[
          {"identifier":"B946EA8B-637F-5D1C-B246-13A8E2AE7817","deviceProperties":{"name":"vestry1"},
           "hardwareProperties":{"marketingName":"iPad Pro (12.9-inch) (5th generation)","deviceType":"iPad","reality":"physical","udid":"00008103-001824281469401E"},
           "connectionProperties":{"pairingState":"paired","tunnelState":"disconnected","transportType":"localNetwork"}},
          {"identifier":"3F42","deviceProperties":{"name":"wayside1"},"hardwareProperties":{"marketingName":"iPhone 15 Plus","deviceType":"iPhone","reality":"physical"},
           "connectionProperties":{"pairingState":"paired","tunnelState":"connected","transportType":"wired"}}
        ]}}
        """#
        let p = DeviceCtl.phones(Data(json.utf8))
        XCTAssertEqual(p[0].udid, "00008103-001824281469401E")
        XCTAssertEqual(p[0].deviceHubURL?.absoluteString, "devices://manage/open?id=00008103-001824281469401E")
        XCTAssertNil(p[1].deviceHubURL, "no UDID, no link")
        XCTAssertNil(Phone(platform: .android, id: "R5CT", name: "Pixel", model: "Pixel 8", ready: true, status: "USB", udid: "x").deviceHubURL)
        XCTAssertNil(Phone(platform: .ios, id: "9B32", name: "iPhone 17 Pro", model: "iPhone 17 Pro Simulator", ready: true, status: "ready", simulator: true, udid: "9B32").deviceHubURL,
                     "a simulator's link was never tried")
    }

    /// Each device's menu names the app that will show it (review r1 on #27).
    func testTheMirrorItemNamesTheAppThatOpens() {
        func phone(_ p: Phone.Platform, simulator: Bool = false, tablet: Bool = false) -> Phone {
            Phone(platform: p, id: "x", name: "x", model: "x", ready: true, status: "", simulator: simulator, tablet: tablet)
        }
        XCTAssertEqual(phone(.ios).mirrorTitle, "Open iPhone Mirroring")
        XCTAssertNil(phone(.ios, tablet: true).mirrorTitle, "an iPad opens in Device Hub")
        XCTAssertEqual(phone(.ios, simulator: true).mirrorTitle, "Open in Simulator")
        XCTAssertEqual(phone(.android).mirrorTitle, "Mirror the Screen")
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

final class ChildGuardTests: XCTestCase {
    func testWrapKeepsTheCommandAsSeparateArguments() {
        let w = ChildGuard.wrap(["/opt/homebrew/bin/adb", "track-devices", "-l"])
        XCTAssertEqual(w.executable, "/bin/sh")
        XCTAssertEqual(Array(w.arguments.prefix(2)), ["-c", ChildGuard.script])
        XCTAssertEqual(Array(w.arguments.suffix(3)), ["/opt/homebrew/bin/adb", "track-devices", "-l"],
                       "the command is passed as \"$@\", never spliced into the script")
    }

    /// The wrapper with a stdin pipe, as the app starts it. Keep `life` open for as long as the command should live.
    private func run(_ command: [String], life: Pipe = Pipe()) throws -> (process: Process, out: Pipe, life: Pipe) {
        let w = ChildGuard.wrap(command)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: w.executable)
        p.arguments = w.arguments
        let out = Pipe()
        p.standardInput = life
        p.standardOutput = out
        try p.run()
        return (p, out, life)
    }

    /// The pid a `echo $$; exec sleep 300` command prints, and a cleanup in case the test fails.
    private func sleeperPid(_ out: Pipe) throws -> pid_t {
        let line = String(data: out.fileHandleForReading.availableData, encoding: .utf8) ?? ""
        let pid = try XCTUnwrap(pid_t(line.trimmingCharacters(in: .whitespacesAndNewlines)))
        addTeardownBlock { kill(pid, SIGKILL) }
        return pid
    }

    private func gone(_ pid: pid_t, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while kill(pid, 0) == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        return kill(pid, 0) == -1
    }

    func testTheWrappedCommandRunsAndItsExitStatusComesBack() throws {
        let r = try run(["/bin/sh", "-c", "echo hi; exit 7"])
        r.process.waitUntilExit()
        XCTAssertEqual(String(data: r.out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), "hi\n")
        XCTAssertEqual(r.process.terminationStatus, 7)
    }

    func testTerminateReachesTheWrappedCommand() throws {
        let r = try run(["/bin/sh", "-c", "echo $$; exec sleep 300"])
        let pid = try sleeperPid(r.out)
        XCTAssertEqual(kill(pid, 0), 0, "the command is running")
        r.process.terminate()
        r.process.waitUntilExit()
        XCTAssertTrue(gone(pid, within: 5), "terminate() on the wrapper must not leave the command behind")
    }

    /// The headline path: the process holding the pipe dies by kill -9 and the command goes with it.
    func testTheCommandDiesWhenTheProcessHoldingThePipeIsKilled() throws {
        let life = Pipe()
        // The stand-in for BaneySpaces: a process whose stdout is the pipe's write end, and nothing else holds it.
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        parent.arguments = ["300"]
        parent.standardOutput = life.fileHandleForWriting
        try parent.run()
        addTeardownBlock { kill(parent.processIdentifier, SIGKILL) }
        try life.fileHandleForWriting.close()
        let r = try run(["/bin/sh", "-c", "echo $$; exec sleep 300"], life: life)
        let pid = try sleeperPid(r.out)
        XCTAssertEqual(kill(pid, 0), 0, "the command is running while its parent lives")
        XCTAssertFalse(gone(pid, within: 1), "and it stays up")
        kill(parent.processIdentifier, SIGKILL)
        XCTAssertTrue(gone(pid, within: 3), "the command must end within seconds of its parent being killed")
    }
}
