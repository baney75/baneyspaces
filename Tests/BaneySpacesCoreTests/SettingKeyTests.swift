import XCTest
@testable import BaneySpacesCore

/// `baneyspaces set appearance.theme omarchy`, `set appearance.palette nord`, `set dock.enabled false`.
final class SettingKeyTests: XCTestCase {
    func testTheThreeSettingsHaveTheSpecNames() {
        XCTAssertEqual(SettingKey.allCases.map(\.rawValue), ["appearance.theme", "appearance.palette", "dock.enabled"])
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

    func testAWrongValueOrNameIsRefusedWithWhatWouldWork() {
        for (k, v) in [("appearance.theme", "vaporwave"), ("appearance.palette", "nope"), ("dock.enabled", "maybe"), ("nothing", "x")] {
            guard case .refused(let why) = SettingKey.ask(target: k, text: v) else { return XCTFail("\(k) \(v)") }
            XCTAssertFalse(why.isEmpty)
        }
    }

    func testEveryPaletteTheCatalogHasIsASettableValue() {
        for name in PaletteCatalog.shared.names { XCTAssertEqual(SettingKey.palette.normalized(name), name) }
    }

    func testAnotherMachineCannotChangeHowThisMacLooks() {
        let set = Wire.Request(op: .setting, target: "dock.enabled", text: "false")
        let get = Wire.Request(op: .setting, target: "appearance.theme")
        XCTAssertFalse(Remote.allows(set))
        XCTAssertFalse(Remote.allows(get))
        // The request survives the wire.
        let back = try? JSONDecoder().decode(Wire.Request.self, from: JSONEncoder().encode(set))
        XCTAssertEqual(back, set)
    }
}
