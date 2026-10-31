import XCTest
@testable import BaneySpacesCore

/// Settings › Appearance: the model that every panel's colors come from. A fresh install must
/// look exactly as BaneySpaces always has.
final class AppearanceTests: XCTestCase {
    private let red = AccentPreset.red.rgb

    func testDefaultsRoundTrip() throws {
        let s = AppearanceSettings()
        let data = try XCTUnwrap(s.encoded())
        XCTAssertEqual(AppearanceSettings.decoded(data), s)
        XCTAssertEqual(s.accent, .preset(.red))
        XCTAssertEqual(s.palette, .rainbow)
        XCTAssertEqual(s.panelStyle, .glass)
        XCTAssertEqual(s.dockSize, .medium)
        XCTAssertEqual(s.panelOpacity, 0.88)
        XCTAssertTrue(s.overrides.isEmpty)
    }

    func testEverySettingRoundTrips() throws {
        var s = AppearanceSettings()
        s.accent = .custom(RGB(hex: "#3366CC")!)
        s.palette = .calm
        s.overrides = [2: RGB(hex: "#112233")!, 9: RGB(hex: "#FFAA00")!]
        s.panelStyle = .tinted
        s.panelOpacity = 0.7
        s.dockSize = .large
        XCTAssertEqual(AppearanceSettings.decoded(s.encoded()), s)
        s.accent = .system
        XCTAssertEqual(AppearanceSettings.decoded(s.encoded()), s)
    }

    func testGarbageIsTheDefaultLook() {
        XCTAssertEqual(AppearanceSettings.decoded(nil), AppearanceSettings())
        XCTAssertEqual(AppearanceSettings.decoded(Data("not json".utf8)), AppearanceSettings())
        XCTAssertEqual(AppearanceSettings.decoded(Data("{\"palette\":\"neon\"}".utf8)), AppearanceSettings())
        XCTAssertEqual(AppearanceSettings.decoded(Data()), AppearanceSettings())
    }

    func testABlobMissingOneKeyKeepsTheOthers() throws {
        var s = AppearanceSettings()
        s.accent = .preset(.blue)
        s.palette = .calm
        s.panelStyle = .tinted
        s.panelOpacity = 0.7
        s.dockSize = .large
        s.overrides = [3: RGB(r: 0.2, g: 0.3, b: 0.4)]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(s.encoded())) as? [String: Any])
        for key in ["accent", "palette", "overrides", "panelStyle", "panelOpacity", "dockSize"] {
            var partial = object
            partial.removeValue(forKey: key)
            let back = AppearanceSettings.decoded(try JSONSerialization.data(withJSONObject: partial))
            var want = s
            switch key {
            case "accent": want.accent = AppearanceSettings().accent
            case "palette": want.palette = AppearanceSettings().palette
            case "overrides": want.overrides = [:]
            case "panelStyle": want.panelStyle = AppearanceSettings().panelStyle
            case "panelOpacity": want.panelOpacity = AppearanceSettings().panelOpacity
            default: want.dockSize = AppearanceSettings().dockSize
            }
            XCTAssertEqual(back, want, "without \(key)")
        }
        object["futureField"] = ["anything": 1]
        XCTAssertEqual(AppearanceSettings.decoded(try JSONSerialization.data(withJSONObject: object)), s, "an unknown key is ignored")
    }

    func testAnUnknownRawValueFallsBackForThatFieldOnly() throws {
        var s = AppearanceSettings()
        s.palette = .mono
        s.dockSize = .small
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(s.encoded())) as? [String: Any])
        object["panelStyle"] = "neon"
        let back = AppearanceSettings.decoded(try JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(back.panelStyle, .glass)
        XCTAssertEqual(back.palette, .mono)
        XCTAssertEqual(back.dockSize, .small)
    }

    func testAColorOutsideZeroToOneIsBroughtBackOnDecode() throws {
        let rgb = try JSONDecoder().decode(RGB.self, from: Data(#"{"r":3,"g":-2,"b":0.5}"#.utf8))
        XCTAssertEqual(rgb, RGB(r: 1, g: 0, b: 0.5))
    }

    func testSavedInOneUserDefaultsKey() throws {
        let suite = UserDefaults(suiteName: "AppearanceTests-\(UUID().uuidString)")!
        XCTAssertEqual(AppearanceSettings.load(from: suite), AppearanceSettings())
        var s = AppearanceSettings()
        s.palette = .mono
        s.save(to: suite)
        XCTAssertNotNil(suite.data(forKey: "appearance"))
        XCTAssertEqual(AppearanceSettings.load(from: suite), s)
    }

    func testOutOfRangeValuesAreBroughtBack() throws {
        var s = AppearanceSettings()
        s.panelOpacity = 0.1
        s.overrides = [0: RGB(r: 1, g: 0, b: 0), 4: RGB(r: 0, g: 1, b: 0)]
        let back = AppearanceSettings.decoded(s.encoded())
        XCTAssertEqual(back.panelOpacity, 0.6)
        XCTAssertEqual(Set(back.overrides.keys), [4])
    }

    /// Today's code, copied: `Chrome.workspace` before Settings › Appearance.
    private func todaysWorkspace(_ n: Int) -> (h: Double, s: Double, b: Double) {
        let hues: [Double] = [0.0, 0.07, 0.12, 0.33, 0.47, 0.55, 0.62, 0.74, 0.86]
        let h = hues[(max(1, min(9, n)) - 1)]
        let dim = (0.10...0.36).contains(h) ? 0.68 : 0.80
        return (h, 0.62, dim)
    }

    func testRainbowIsExactlyTodaysColors() {
        let s = AppearanceSettings()
        for n in 1...9 {
            let c = s.workspaceColor(n, accent: red)
            let want = todaysWorkspace(n)
            XCTAssertEqual(c.h, want.h, "hue \(n)")
            XCTAssertEqual(c.s, want.s, "saturation \(n)")
            XCTAssertEqual(c.b, want.b, "brightness \(n)")
        }
        // Out-of-range numbers land on the ends, as before.
        XCTAssertEqual(s.workspaceColor(0, accent: red), s.workspaceColor(1, accent: red))
        XCTAssertEqual(s.workspaceColor(12, accent: red), s.workspaceColor(9, accent: red))
        // The accent doesn't touch Rainbow.
        XCTAssertEqual(s.workspaceColor(3, accent: AccentPreset.blue.rgb), s.workspaceColor(3, accent: red))
    }

    func testTodaysAccentIsTheDefault() {
        XCTAssertEqual(AppearanceSettings().accentRGB(system: RGB(r: 0, g: 0, b: 1)), RGB(r: 0.91, g: 0.26, b: 0.29))
    }

    func testAccentChoices() {
        var s = AppearanceSettings()
        let system = RGB(r: 0.1, g: 0.2, b: 0.3)
        s.accent = .system
        XCTAssertEqual(s.accentRGB(system: system), system)
        s.accent = .custom(RGB(r: 0.5, g: 0.6, b: 0.7))
        XCTAssertEqual(s.accentRGB(system: system), RGB(r: 0.5, g: 0.6, b: 0.7))
        s.accent = .preset(.teal)
        XCTAssertEqual(s.accentRGB(system: system), AccentPreset.teal.rgb)
        XCTAssertEqual(AccentPreset.allCases.count, 9)
        XCTAssertEqual(Set(AccentPreset.allCases.map(\.rgb)).count, 9, "each preset is its own color")
    }

    func testOverridesWinAndResetClearsThem() {
        var s = AppearanceSettings()
        let before = s.workspaceColor(4, accent: red)
        let own = RGB(hex: "#2255AA")!
        s.overrides[4] = own
        let after = s.workspaceColor(4, accent: red)
        XCTAssertNotEqual(after, before)
        XCTAssertEqual(after.h, own.hsb.h, accuracy: 1e-9)
        XCTAssertEqual(s.workspaceColor(5, accent: red), AppearanceSettings().workspaceColor(5, accent: red), "others keep the palette")
        s.palette = .mono
        XCTAssertEqual(s.workspaceColor(4, accent: red), after, "an override beats every palette")
        s.resetOverrides()
        XCTAssertTrue(s.overrides.isEmpty)
        XCTAssertEqual(s.workspaceColor(4, accent: red), AppearanceSettings.paletteColor(.mono, 4, accent: red))
    }

    func testOverridesAreHeldDownForWhiteText() {
        var s = AppearanceSettings()
        let brightestDefault = (1...9).map { AppearanceSettings().workspaceColor($0, accent: red).rgb.contrastWithWhite }.min()!
        for hex in ["#FFFFFF", "#FFFF00", "#00FFFF", "#00FF00", "#FF0000", "#FFEEAA", "#CCCCCC", "#80FF00"] {
            s.overrides[1] = RGB(hex: hex)!
            let c = s.workspaceColor(1, accent: red).rgb
            XCTAssertGreaterThanOrEqual(c.contrastWithWhite, brightestDefault - 1e-6, "\(hex) must read as well as the brightest default")
        }
        // Pure yellow and white are really dimmed; a dark pick is left alone.
        for hex in ["#FFFF00", "#FFFFFF"] {
            s.overrides[1] = RGB(hex: hex)!
            XCTAssertLessThan(s.workspaceColor(1, accent: red).b, 0.8, hex)
        }
        s.overrides[1] = RGB(hex: "#102030")!
        XCTAssertEqual(s.workspaceColor(1, accent: red).b, RGB(hex: "#102030")!.hsb.b, accuracy: 1e-9)
    }

    func testTheLuminanceLimitIsTheBrightestDefaultSoDefaultsAreUnchanged() {
        let lums = (1...9).map { AppearanceSettings.paletteColor(.rainbow, $0, accent: red).rgb.luminance }
        XCTAssertEqual(AppearanceSettings.maxLuminance, lums.max()!, accuracy: 1e-12)
        for n in 1...9 {
            let c = AppearanceSettings.paletteColor(.rainbow, n, accent: red)
            XCTAssertEqual(AppearanceSettings.readable(c), c, "clamping a default Rainbow color must change nothing (\(n))")
        }
    }

    func testLuminanceAndContrast() {
        XCTAssertEqual(RGB(r: 1, g: 1, b: 1).luminance, 1, accuracy: 1e-9)
        XCTAssertEqual(RGB(r: 0, g: 0, b: 0).luminance, 0)
        XCTAssertEqual(RGB(r: 1, g: 1, b: 1).contrastWithWhite, 1, accuracy: 1e-9)
        XCTAssertEqual(RGB(r: 0, g: 0, b: 0).contrastWithWhite, 21, accuracy: 1e-9)
    }

    func testEveryPaletteStaysReadableForEveryAccent() {
        for palette in WorkspacePalette.allCases {
            for preset in AccentPreset.allCases {
                for n in 1...9 {
                    let c = AppearanceSettings.paletteColor(palette, n, accent: preset.rgb)
                    XCTAssertLessThanOrEqual(c.rgb.luminance, AppearanceSettings.maxLuminance + 1e-9, "\(palette) \(preset) \(n)")
                }
            }
        }
    }

    func testAccentPaletteIsNineDistinctShadesOfTheAccent() {
        for preset in AccentPreset.allCases {
            let accent = preset.rgb
            let shades = (1...9).map { AppearanceSettings.paletteColor(.accent, $0, accent: accent) }
            XCTAssertEqual(Set(shades.map(\.rgb)).count, 9, "\(preset)")
            if accent.hsb.s >= 0.15 {
                for c in shades { XCTAssertEqual(c.h, accent.hsb.h, accuracy: 1e-9, "\(preset) keeps the accent's hue") }
            }
            // Dark to light.
            XCTAssertEqual(shades.map(\.b), shades.map(\.b).sorted())
        }
    }

    func testCalmIsMutedAndMonoIsGray() {
        for n in 1...9 {
            XCTAssertLessThan(AppearanceSettings.paletteColor(.calm, n, accent: red).s, AppearanceSettings.paletteColor(.rainbow, n, accent: red).s)
            XCTAssertEqual(AppearanceSettings.paletteColor(.mono, n, accent: red).s, 0)
        }
        XCTAssertEqual(Set((1...9).map { AppearanceSettings.paletteColor(.calm, $0, accent: red).rgb }).count, 9)
        XCTAssertEqual(Set((1...9).map { AppearanceSettings.paletteColor(.mono, $0, accent: red).rgb }).count, 9)
    }

    func testHexAndHSBConversions() {
        XCTAssertEqual(RGB(hex: "#E8424A")?.hex, "#E8424A")
        XCTAssertEqual(RGB(hex: "e8424a")?.hex, "#E8424A")
        XCTAssertNil(RGB(hex: "#12345"))
        XCTAssertNil(RGB(hex: "zzzzzz"))
        for hex in ["#E8424A", "#33CC66", "#2255AA", "#808080", "#000000", "#FFFFFF"] {
            let c = RGB(hex: hex)!
            XCTAssertEqual(c.hsb.rgb.hex, hex)
        }
    }

    func testPanelLookDefaultsToToday() {
        let s = AppearanceSettings()
        XCTAssertEqual(s.effectivePanelOpacity, 0.88, "the dark fill every panel has always had")
        XCTAssertEqual(s.overviewDim, 0.35, "the overview's scrim has always been 35%")
        var solid = s
        solid.panelStyle = .solid
        XCTAssertEqual(solid.effectivePanelOpacity, 1)
        var loose = s
        loose.panelOpacity = 0.6
        XCTAssertLessThan(loose.overviewDim, s.overviewDim)
    }

    func testDockSizeScales() {
        XCTAssertEqual(DockSize.medium.scale, 1, "Medium is the size the dock has always had")
        XCTAssertLessThan(DockSize.small.scale, 1)
        XCTAssertGreaterThan(DockSize.large.scale, 1)
    }

    // MARK: Wiring

    private func appSource(_ file: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BaneySpaces/\(file)")
        // Code only: a commented-out line must not pass.
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map { $0.components(separatedBy: "//")[0] }.joined(separator: "\n")
    }

    /// The view code lives in the app target, which tests can't import, so this reads the source.
    func testChromeReadsFromAppearanceNotConstants() throws {
        let text = try appSource("WorkspaceSwitcher.swift")
        let chrome = try XCTUnwrap(text.range(of: "enum Chrome {"))
        let end = try XCTUnwrap(text.range(of: "extension NSWindow", range: chrome.upperBound..<text.endIndex))
        let body = String(text[chrome.upperBound..<end.lowerBound])
        XCTAssertTrue(body.contains("static var accent: Color { Appearance.shared.accent }"), "Chrome.accent must follow Settings")
        XCTAssertTrue(body.contains("Appearance.shared.workspace(n)"), "Chrome.workspace must follow Settings")
        XCTAssertFalse(body.contains("static let accent"), "a constant accent can't change live")
        XCTAssertFalse(body.contains("let hues"), "the workspace hues live in Appearance now")
        XCTAssertTrue(body.contains("panelBackground"))
    }

    func testEveryPanelDrawsItsBackgroundFromChromeAndWatchesAppearance() throws {
        for (file, view) in [("WorkspaceDock.swift", "struct DockView"), ("WorkspaceSwitcher.swift", "struct SwitcherView"),
                             ("Launcher.swift", "struct LauncherView"), ("SwitchHUD.swift", "struct HUDView"),
                             ("Viewer.swift", "struct ViewerView"), ("WorkspaceSwitcher.swift", "struct WorkspaceBadge")] {
            let text = try appSource(file)
            let start = try XCTUnwrap(text.range(of: view), "\(view) in \(file)")
            let head = String(text[start.lowerBound...].prefix(600))
            XCTAssertTrue(head.contains("@ObservedObject private var appearance = Appearance.shared"), "\(view) must redraw when the look changes")
        }
        XCTAssertFalse(try appSource("Viewer.swift").contains("Color(red: 0.91"), "the overview's accent must follow Settings")
    }

    func testTheDockScalesFromTheDockSizeSetting() throws {
        let text = try appSource("WorkspaceDock.swift")
        XCTAssertTrue(text.contains("appearance.settings.dockSize.scale"))
        XCTAssertTrue(text.contains("private var tileSize: CGFloat { 64 * k }"))
        XCTAssertTrue(text.contains("forName: Appearance.didChange"), "a new size must re-frame the dock's panel")
    }

    func testBothColorPickersIgnoreAnEchoOfTheColorShown() throws {
        let text = try appSource("Setup.swift")
        let start = try XCTUnwrap(text.range(of: "ColorPicker(\"Custom accent\""))
        let block = String(text[start.lowerBound...].prefix(900))
        XCTAssertTrue(block.contains("appearance.accentRGB"), "the accent picker must compare with the accent shown")
        XCTAssertTrue(block.contains("> 0.01 else { return }"), "an echo of the shown color must not switch to Custom")
        XCTAssertLessThan(try XCTUnwrap(block.range(of: "> 0.01 else { return }")).lowerBound,
                          try XCTUnwrap(block.range(of: ".custom(rgb)")).lowerBound)
    }

    func testTheDockKeepsAndRemovesItsAppearanceObserver() throws {
        let text = try appSource("WorkspaceDock.swift")
        XCTAssertTrue(text.contains("appearanceObserver = NotificationCenter.default.addObserver(forName: Appearance.didChange"))
        XCTAssertTrue(text.contains("deinit { appearanceObserver.map(NotificationCenter.default.removeObserver) }"))
    }

    func testSystemColorChangesAlwaysRefreshTheSettingsTab() throws {
        let text = try appSource("Appearance.swift")
        let start = try XCTUnwrap(text.range(of: "systemColorsDidChangeNotification"))
        let block = String(text[start.lowerBound...].prefix(700))
        let send = try XCTUnwrap(block.range(of: "objectWillChange.send()"))
        let post = try XCTUnwrap(block.range(of: "post(name: Appearance.didChange"))
        XCTAssertLessThan(send.lowerBound, post.lowerBound)
        XCTAssertTrue(block.contains("if case .system = self.settings.accent { NotificationCenter"), "didChange only when the accent is System")
    }

    func testRenderShotsUseTheDefaultLook() throws {
        XCTAssertTrue(try appSource("Render.swift").contains("Appearance.shared.useDefaultLookWithoutSaving()"))
    }
}
