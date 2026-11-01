import XCTest
@testable import BaneySpacesCore

/// Every surface draws its radius, border, fill, type, spacing and motion from the theme. Each
/// surface's style is rendered in all three themes and compared with spec/themes.json read
/// afresh here, and the view files are scanned for a literal that would bypass the theme.
final class ThemeConformanceTests: XCTestCase {
    private func raw() throws -> [String: [String: Any]] {
        let data = try Repo.text("spec/themes.json").data(using: .utf8)!
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return json["themes"] as! [String: [String: Any]]
    }
    private func num(_ d: [String: Any], _ k: String) -> Double { (d[k] as? NSNumber)?.doubleValue ?? .nan }

    func testEverySurfaceInEveryThemeUsesThemesJSON() throws {
        let themes = try raw()
        let base = themes["baneyspaces"]!["radius"] as! [String: Any]
        for id in ThemeID.allCases {
            let t = themes[id.rawValue]!
            let radius = t["radius"] as! [String: Any]
            let border = t["border"] as! [String: Any]
            let fill = t["fill"] as! [String: Any]
            let font = t["font"] as! [String: Any]
            let space = t["space"] as! [String: Any]
            let motion = t["motion"] as! [String: Any]
            for s in Surface.allCases {
                let st = SurfaceStyle.make(s, theme: id, spec: ThemeCatalog.shared.spec(id))
                let key = "\(s.kind)"
                let want = s.shippedRadius * (num(radius, key) / num(base, key))
                XCTAssertEqual(st.radius, want, accuracy: 1e-9, "\(id) \(s) radius")
                if id == .baneyspaces {
                    XCTAssertEqual(st.radius, s.shippedRadius, "\(s)")
                } else {
                    XCTAssertEqual(st.borderWidth, num(border, "width"), "\(id) \(s)")
                    XCTAssertEqual(st.focusedBorderWidth, num(border, "focused_width"), "\(id) \(s)")
                }
                XCTAssertEqual(st.borderRole, border["role"] as? String)
                XCTAssertEqual(st.focusedBorderRole, border["focused_role"] as? String)
                XCTAssertEqual(st.borderOpacity, (border["opacity"] as? NSNumber)?.doubleValue)
                XCTAssertEqual(st.borderGradient, (border["gradient"] as? [NSNumber])?.map(\.doubleValue))
                XCTAssertEqual(st.fill.tintRole, fill["tint_role"] as? String)
                XCTAssertEqual(st.fill.tintOpacity, num(fill, "tint_opacity"))
                XCTAssertEqual(st.fill.opacity, num(fill, "opacity"))
                XCTAssertEqual(st.fill.adjustable, fill["adjustable"] as? Bool)
                XCTAssertEqual(st.fill.material, fill["material"] as? String)
                XCTAssertEqual(st.fill.blur, fill["material"] is String, "blur is the material")
                if let sh = t["shadow"] as? [String: Any] {
                    XCTAssertEqual(st.shadow, ThemeSpec.Shadow(radius: num(sh, "radius"), y: num(sh, "y"), opacity: num(sh, "opacity")))
                } else {
                    XCTAssertNil(st.shadow, "\(id) has no shadow")
                }
                XCTAssertEqual(st.font.family, font["family"] as? String)
                XCTAssertEqual(st.font.size, num(font, "size"))
                XCTAssertEqual(st.font.weight, font["weight"] as? String)
                XCTAssertEqual([st.gap, st.padding, st.tile], [num(space, "gap"), num(space, "padding"), num(space, "tile")])
                XCTAssertEqual(st.indicator.rawValue, t["indicator"] as? String)
                let m = st.motion
                XCTAssertEqual([m.inMs, m.outMs, m.listInMs, m.listOutMs, m.rowMs, m.scaleFrom, m.lift],
                               ["in_ms", "out_ms", "list_in_ms", "list_out_ms", "row_ms", "scale_from", "lift"].map { num(motion, $0) })
            }
        }
    }

    func testThePanelsOfEveryThemeAreWhatTheThemeSays() throws {
        let themes = try raw()
        for id in ThemeID.allCases {
            let t = themes[id.rawValue]!
            let fill = t["fill"] as! [String: Any]
            // Every palette of the catalog, so a named palette that is ignored (or misspelled) fails.
            for name in PaletteCatalog.shared.names {
                let look = Look(theme: id, palette: name, accent: AccentPreset.red.rgb)
                XCTAssertFalse(look.isAuto, "\(name) is a palette")
                let p = PanelLook.make(.dockBar, look: look, settings: AppearanceSettings(), accent: AccentPreset.red.rgb)
                XCTAssertEqual(p.blur, fill["material"] is String, "\(id) \(name)")
                XCTAssertEqual(p.shadow == nil, t["shadow"] is NSNull, "\(id) \(name)")
                XCTAssertEqual(p.fill, PaletteCatalog.shared.named(name)?.color(fill["tint_role"] as! String), "\(id) \(name)")
                let border = t["border"] as! [String: Any]
                if (border["role"] as? String) != "light" {
                    XCTAssertEqual(p.border.color, PaletteCatalog.shared.named(name)?.color(border["role"] as! String), "\(id) \(name)")
                }
                if (fill["adjustable"] as? Bool) == false {
                    XCTAssertEqual(p.fillOpacity, num(fill, "tint_opacity") * num(fill, "opacity"), "\(id) \(name)")
                }
            }
        }
    }

    // MARK: Light palettes

    func testTextReadsOnItsFillInEveryThemeAndPalette() {
        let accent = AccentPreset.red.rgb
        for id in ThemeID.allCases {
            for name in PaletteCatalog.shared.names + [AppearanceSettings.autoPalette] {
                let look = Look(theme: id, palette: name, accent: accent)
                XCTAssertFalse(look.textPairs(accent: accent).isEmpty)
                for pair in look.textPairs(accent: accent) {
                    XCTAssertGreaterThanOrEqual(pair.text.contrast(with: pair.fill), 4.5, "\(id) / \(name): \(pair.name)")
                }
            }
        }
    }

    func testTheShippedGraysWouldFailOnALightPalette() {
        // Why the overview's fills come from the palette: the white palette's text on the shipped dark gray.
        let white = PaletteCatalog.shared.named("white")!
        XCTAssertLessThan(white.color("foreground")!.contrast(with: RGB(r: 0.13, g: 0.13, b: 0.13)), 4.5)
        let look = Look(theme: .baneyspaces, palette: "white", accent: AccentPreset.red.rgb)
        XCTAssertFalse(look.isShipped)
        XCTAssertEqual(look.tileFill(target: false), white.color("surface"))
        XCTAssertEqual(look.tileFill(target: true), white.color("selection"))
        XCTAssertEqual(look.liftedFill, white.color("selection"))
        // Auto keeps the grays it always drew.
        let shipped = Look(theme: .baneyspaces, palette: "auto", accent: AccentPreset.red.rgb)
        XCTAssertTrue(shipped.isShipped)
        XCTAssertEqual(shipped.tileFill(target: false), RGB(r: 0.13, g: 0.13, b: 0.13))
        XCTAssertEqual(shipped.tileFill(target: true), RGB(r: 0.19, g: 0.19, b: 0.19))
        XCTAssertEqual(shipped.liftedFill, RGB(r: 0.26, g: 0.26, b: 0.26))
    }

    func testTextOnAWorkspaceTintReadsInThemesThatPickIt() {
        let s = AppearanceSettings()
        for id in [ThemeID.omarchy, .minimal] {
            for name in PaletteCatalog.shared.names + ["auto"] {
                let look = Look(theme: id, palette: name, accent: AccentPreset.red.rgb)
                for n in 1...9 {
                    let tint = s.workspaceColor(n, accent: AccentPreset.red.rgb).rgb
                    XCTAssertGreaterThanOrEqual(look.text(onTint: tint).contrast(with: tint), 4.5, "\(id) \(name) \(n)")
                }
            }
        }
        // The BaneySpaces theme keeps the white its tints were made for.
        let look = Look(theme: .baneyspaces, palette: "white", accent: AccentPreset.red.rgb)
        XCTAssertEqual(look.text(onTint: AccentPreset.green.rgb), RGB(r: 1, g: 1, b: 1))
    }

    func testShadowsAndTheDimAreBlackWhateverThePalette() {
        for name in PaletteCatalog.shared.names {
            XCTAssertEqual(Look(theme: .baneyspaces, palette: name, accent: AccentPreset.red.rgb).color("dark"), RGB(r: 0, g: 0, b: 0))
        }
    }

    // MARK: Source scan

    /// The files that draw a surface. `Theming.swift` is the theme layer: the only place a shipped
    /// value of the BaneySpaces theme may be written down.
    private let surfaceFiles = ["WorkspaceDock", "WorkspaceSwitcher", "Launcher", "Viewer", "SwitchHUD", "Setup", "Appearance"]

    /// What an agent shows keeps its own colors (the agent cursor, the spinner and its badges), so
    /// agent activity is never mistaken for yours: the dock's source from this line on.
    private let agentBadgeStart = "struct AgentStatusBadge: View"

    private let banned: [(String, String)] = [
        (#"cornerRadius:\s*[0-9]"#, "a corner radius"),
        (#"lineWidth:\s*[0-9]"#, "a border width"),
        (#"duration(:|\s*=)\s*[0-9]"#, "a duration"),
        (#"Color\(\s*(white|red|hue|\.sRGB|\.display)"#, "a color"),
        (#"Color\.(white|black)\b"#, "a color"),
        (#"NSColor\.(white|black)"#, "a color"),
        (#"(?<![A-Za-z0-9_.])\.(white|black)\b"#, "a color"),
        // A shadow is the theme's: `Chrome.shadow` is clear where the theme has none; a panel's comes from its `PanelLook`.
        (#"\.shadow\(color:\s*+(?!Chrome\.shadow\(|shadow,)"#, "a shadow the theme doesn't gate"),
        (#"\.systemFont\("#, "a font"),
        (#"\.system\(size:"#, "a font"),
    ]

    func testNoSurfaceHardCodesARadiusColorBorderDurationOrFont() throws {
        var found: [String] = []
        for file in surfaceFiles {
            var code = try Repo.code("Sources/BaneySpaces/\(file).swift")
            if file == "WorkspaceDock", let r = code.range(of: agentBadgeStart) { code = String(code[..<r.lowerBound]) }
            // Appearance.swift holds the model's own conversions (RGB to Color) before the panel.
            if file == "Appearance", let r = code.range(of: "struct PanelBackground") { code = String(code[r.lowerBound...]) }
            for (n, line) in code.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                // An SF Symbol's size is not text.
                if line.contains("systemName") { continue }
                for (pattern, what) in banned where line.range(of: pattern, options: .regularExpression) != nil {
                    found.append("\(file).swift:\(n + 1): \(what): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertEqual(found, [], "a surface must take this from the theme (Chrome), not write it down")
    }

    func testTheScanSeesAHardCodedLiteral() {
        let line = "RoundedRectangle(cornerRadius: 12)"
        XCTAssertNotNil(line.range(of: banned[0].0, options: .regularExpression))
        XCTAssertNotNil("Color.white.opacity(0.5)".range(of: banned[4].0, options: .regularExpression))
        XCTAssertNotNil(".foregroundStyle(.white)".range(of: banned[6].0, options: .regularExpression))
        XCTAssertNil("Chrome.shape(.dockTile)".range(of: banned[0].0, options: .regularExpression))
    }

    func testEverySurfaceFileReadsTheTheme() throws {
        for file in surfaceFiles where file != "Appearance" {
            let code = try Repo.code("Sources/BaneySpaces/\(file).swift")
            XCTAssertTrue(code.contains("Chrome."), "\(file) draws without Chrome")
        }
        // The panel is the one place the fill, border and shadow are drawn, from `PanelLook`.
        let panel = try Repo.code("Sources/BaneySpaces/Appearance.swift")
        XCTAssertTrue(panel.contains("PanelLook.make"))
        // The dock's measurements are the theme's.
        let dock = try Repo.code("Sources/BaneySpaces/WorkspaceDock.swift")
        XCTAssertTrue(dock.contains("Chrome.tileScale"))
        XCTAssertTrue(dock.contains("Chrome.style(.dockBar).gap"))
        XCTAssertTrue(dock.contains("Chrome.style(.dockBar).padding"))
    }

    /// `.primary` and `.secondary` text follows the color scheme: a light palette's panels need the light scheme,
    /// or the overview's text is white on a pale tile.
    func testEverySurfaceSetsTheColorSchemeFromThePalette() throws {
        for file in ["WorkspaceDock", "WorkspaceSwitcher", "Launcher", "Viewer", "SwitchHUD"] {
            let code = try Repo.code("Sources/BaneySpaces/\(file).swift")
            XCTAssertTrue(code.contains("\\.colorScheme, Chrome.scheme"), "\(file) pins the scheme instead of following the palette")
        }
    }

    func testTheSwitcherLauncherOverviewHudAndIndicatorTakeTheirPanelsFromTheTheme() throws {
        let want: [(String, [String])] = [
            ("WorkspaceSwitcher", [".switcherPanel", ".switcherTile", ".switcherWindow"]),
            ("Launcher", [".launcherPanel", ".launcherRow", ".launcherThumb"]),
            ("Viewer", [".overviewTile", ".overviewChip"]),
            ("SwitchHUD", [".hudPanel", ".hudCell"]),
            ("WorkspaceDock", [".dockBar", ".dockList", ".dockTile", ".dockRow", ".dockButton"]),
            ("Setup", [".settingsTile", ".settingsCallout", ".settingsCell"]),
        ]
        for (file, surfaces) in want {
            let code = try Repo.code("Sources/BaneySpaces/\(file).swift")
            for s in surfaces { XCTAssertTrue(code.contains(s), "\(file) doesn't use \(s)") }
        }
        let app = try Repo.code("Sources/BaneySpaces/AppDelegate.swift")
        XCTAssertTrue(app.contains("MenuBarMark.image"), "the menu bar indicator draws the theme's indicator")
    }
}
