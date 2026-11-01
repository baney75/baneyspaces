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
            let look = Look(theme: id, palette: "dracula", accent: AccentPreset.red.rgb)
            let p = PanelLook.make(.dockBar, look: look, settings: AppearanceSettings(), accent: AccentPreset.red.rgb)
            XCTAssertEqual(p.blur, fill["material"] is String, "\(id)")
            XCTAssertEqual(p.shadow == nil, t["shadow"] is NSNull, "\(id)")
            XCTAssertEqual(p.fill, look.color(fill["tint_role"] as! String))
            if (fill["adjustable"] as? Bool) == false {
                XCTAssertEqual(p.fillOpacity, num(fill, "tint_opacity") * num(fill, "opacity"), "\(id)")
            }
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

    func testTheSwitcherLauncherOverviewHudAndIndicatorTakeTheirPanelsFromTheTheme() throws {
        let want: [(String, [String])] = [
            ("WorkspaceSwitcher", [".switcherPanel", ".switcherTile", ".switcherWindow"]),
            ("Launcher", [".launcherPanel", ".launcherRow", ".launcherThumb"]),
            ("Viewer", [".overviewTile", ".overviewChip"]),
            ("SwitchHUD", [".hudPanel", ".hudCell"]),
            ("WorkspaceDock", [".dockBar", ".dockList", ".dockTile", ".dockRow", ".dockButton"]),
            ("Setup", [".settingsPanel", ".settingsTile"]),
        ]
        for (file, surfaces) in want {
            let code = try Repo.code("Sources/BaneySpaces/\(file).swift")
            for s in surfaces { XCTAssertTrue(code.contains(s), "\(file) doesn't use \(s)") }
        }
        let app = try Repo.code("Sources/BaneySpaces/AppDelegate.swift")
        XCTAssertTrue(app.contains("MenuBarMark.image"), "the menu bar indicator draws the theme's indicator")
    }
}
