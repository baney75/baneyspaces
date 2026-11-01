import XCTest
@testable import BaneySpacesCore

/// `baneyspaces set appearance.theme omarchy`, `set appearance.palette nord`, `set dock.enabled false`.
final class SettingKeyTests: XCTestCase {
    func testTheSettingsHaveTheSpecNames() {
        XCTAssertEqual(SettingKey.allCases.map(\.rawValue), ["appearance.theme", "appearance.palette", "dock.enabled", "behavior.launcher.open"])
    }

    func testThemesPalettesAndTheDockSwitchTakeTheirValues() {
        XCTAssertEqual(SettingKey.ask(target: "appearance.theme", text: "omarchy"), .set(.theme, "omarchy"))
        XCTAssertEqual(SettingKey.ask(target: "appearance.theme", text: "Minimal"), .set(.theme, "minimal"))
        XCTAssertEqual(SettingKey.ask(target: "appearance.palette", text: "auto"), .set(.palette, "auto"))
        XCTAssertEqual(SettingKey.ask(target: "appearance.palette", text: "nord"), .set(.palette, "nord"))
        XCTAssertEqual(SettingKey.ask(target: "dock.enabled", text: "false"), .set(.dockEnabled, "false"))
        XCTAssertEqual(SettingKey.ask(target: "dock.enabled", text: "on"), .set(.dockEnabled, "true"))
        XCTAssertEqual(SettingKey.ask(target: "dock.enabled", text: nil), .get(.dockEnabled))
        XCTAssertEqual(SettingKey.ask(target: nil, text: nil), .list)
    }

    func testOpenHereTakesHereOrGo() {
        XCTAssertEqual(SettingKey.ask(target: "behavior.launcher.open", text: "go"), .set(.launcherOpen, "go"))
        XCTAssertEqual(SettingKey.ask(target: "behavior.launcher.open", text: "HERE"), .set(.launcherOpen, "here"))
        XCTAssertEqual(SettingKey.ask(target: "behavior.launcher.open", text: nil), .get(.launcherOpen))
        guard case .refused = SettingKey.ask(target: "behavior.launcher.open", text: "elsewhere") else { return XCTFail("a wrong value is refused") }
    }

    func testAWrongValueOrNameIsRefusedWithWhatWouldWork() {
        for (k, v) in [("appearance.theme", "vaporwave"), ("appearance.palette", "nope"), ("dock.enabled", "maybe"), ("behavior.launcher.open", "maybe"), ("nothing", "x")] {
            guard case .refused(let why) = SettingKey.ask(target: k, text: v) else { return XCTFail("\(k) \(v)") }
            XCTAssertFalse(why.isEmpty)
        }
    }

    func testAnEmptyNameIsRefusedWhenAValueCameWithIt() {
        guard case .refused = SettingKey.ask(target: "", text: "omarchy") else { return XCTFail("an unset variable is not 'list everything'") }
        guard case .refused = SettingKey.ask(target: nil, text: "omarchy") else { return XCTFail("a value with no name") }
        XCTAssertEqual(SettingKey.ask(target: "", text: nil), .list)
    }

    func testEveryPaletteTheCatalogHasIsASettableValue() {
        for name in PaletteCatalog.shared.names { XCTAssertEqual(SettingKey.palette.normalized(name), name) }
    }

    /// Donovan, 2026-11-01: "agents should be able to customize in any way they choose."
    func testAnAgentTokenMayChangeHowThisMacLooks() {
        for key in SettingKey.allCases {
            XCTAssertTrue(Remote.allows(Wire.Request(op: .setting, target: key.rawValue, text: "x", caller: "claude")), key.rawValue)
            XCTAssertTrue(Remote.allows(Wire.Request(op: .setting, target: key.rawValue)), key.rawValue)
        }
        // The request, caller included, survives the wire.
        let set = Wire.Request(op: .setting, target: "dock.enabled", text: "false", caller: "claude-code")
        let back = try? JSONDecoder().decode(Wire.Request.self, from: JSONEncoder().encode(set))
        XCTAssertEqual(back, set)
        XCTAssertEqual(back?.caller, "claude-code")
        XCTAssertNil(SocketPolicy.refusal(for: set), "the local socket doesn't refuse it either")
    }

    func testWorkspaceAndWindowOpsStayUserOnly() {
        for op in [Wire.Request.Op.focus, .open, .send, .notify, .remote, .hands, .event] {
            XCTAssertFalse(Remote.allows(Wire.Request(op: op, target: "x", text: "x")), "\(op)")
        }
        XCTAssertFalse(Remote.allows(Wire.Request(op: .agent, text: "on")))
        XCTAssertFalse(Remote.allows(Wire.Request(op: .agent, text: "move")))
        XCTAssertFalse(Remote.allows(Wire.Request(op: .agent, text: "lend")))
    }

    func testEachChangeIsLoggedWithItsCallerAndTheLogNeverHoldsTheToken() throws {
        let token = Remote.newToken()
        let fp = Remote.fingerprint(token)
        XCTAssertEqual(fp.count, 8)
        XCTAssertNotEqual(fp, String(token.prefix(8)), "a fingerprint is a hash, not a piece of the token")
        XCTAssertEqual(fp, Remote.fingerprint(token))
        let controller = try Repo.code("Sources/BaneySpaces/Deck/DeckController.swift")
        XCTAssertTrue(controller.contains(#"Trace.log("setting \(key.rawValue)=\(v) by \(r.caller ?? "unnamed caller")")"#))
        let server = try Repo.code("Sources/BaneySpaces/Deck/Server.swift")
        XCTAssertTrue(server.contains("Remote.fingerprint(req.token"))
        XCTAssertLessThan(try XCTUnwrap(server.range(of: "req.caller =")).lowerBound, try XCTUnwrap(server.range(of: "req.token = nil")).lowerBound)
        let cli = try Repo.code("Sources/baneyspaces-cli/main.swift")
        XCTAssertTrue(cli.contains("BANEYSPACES_AGENT"))
    }
}
