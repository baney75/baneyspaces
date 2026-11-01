import XCTest
@testable import BaneySpacesCore

/// The BaneySpaces theme is what macOS drew before themes existed. Every number below is a constant
/// that was in the view code; if one of these changes, the default look changed.
final class ThemeTests: XCTestCase {
    private let t = ThemeCatalog.shared.spec(.baneyspaces)

    func testTheBaneySpacesThemeHoldsTheShippedValues() {
        XCTAssertEqual([t.radius.bar, t.radius.tile, t.radius.row, t.radius.list], [24, 16, 7, 14])
        XCTAssertEqual(t.border.width, 1)
        XCTAssertEqual(t.border.role, "light")
        XCTAssertEqual(t.border.gradient, [0.22, 0.06])
        XCTAssertEqual(t.border.focusedRole, "workspace")
        XCTAssertEqual(t.border.focusedWidth, 1.5)
        XCTAssertEqual(t.fill.material, "ultra-thin")
        XCTAssertEqual(t.fill.opacity, 0.88)
        XCTAssertEqual(t.fill.opacity, AppearanceSettings.defaultPanelOpacity)
        XCTAssertEqual(t.fill.tintOpacity, 1)
        XCTAssertTrue(t.fill.adjustable)
        XCTAssertEqual(t.shadow, ThemeSpec.Shadow(radius: 24, y: 10, opacity: 0.45))
        XCTAssertEqual(t.space.gap, 8)
        XCTAssertEqual(t.space.padding, 10)
        XCTAssertEqual(t.space.tile, 64)
        XCTAssertEqual(t.font.size, 12)
        XCTAssertEqual(t.indicator, .dot)
        XCTAssertEqual([t.motion.inMs, t.motion.outMs, t.motion.listInMs, t.motion.listOutMs, t.motion.rowMs], [180, 140, 140, 100, 80])
        XCTAssertEqual(t.motion.scaleFrom, 0.96)
        XCTAssertEqual(t.motion.lift, 1.04)
    }

    func testThePanelFillIsTheNearBlackItHasAlwaysBeen() {
        let look = Look(theme: .baneyspaces, palette: "auto", accent: AccentPreset.red.rgb)
        XCTAssertEqual(look.color(t.fill.tintRole), RGB(r: 0.07, g: 0.07, b: 0.07))
        XCTAssertEqual(look.color("light"), RGB(r: 1, g: 1, b: 1))
        XCTAssertEqual(look.color("foreground"), RGB(r: 1, g: 1, b: 1))
        XCTAssertEqual(look.color("sunken"), RGB(r: 0, g: 0, b: 0))
    }

    func testThePanelLookIsTheGlassPanelItHasAlwaysBeen() {
        let look = Look(theme: .baneyspaces, palette: "auto", accent: AccentPreset.red.rgb)
        let p = PanelLook.make(.dockBar, look: look, settings: AppearanceSettings(), accent: AccentPreset.red.rgb)
        XCTAssertTrue(p.blur)
        XCTAssertEqual(p.fill, RGB(r: 0.07, g: 0.07, b: 0.07))
        XCTAssertEqual(p.fillOpacity, 0.88)
        XCTAssertNil(p.wash)
        XCTAssertEqual(p.border.width, 1)
        XCTAssertEqual(p.border.color, RGB(r: 1, g: 1, b: 1))
        XCTAssertEqual([p.border.top, p.border.bottom], [0.22, 0.06])
        XCTAssertEqual(p.shadow, ThemeSpec.Shadow(radius: 24, y: 10, opacity: 0.45))
        XCTAssertEqual(p.radius, 24)
    }

    func testThePanelStyleSettingsStillWorkInTheBaneySpacesTheme() {
        let look = Look(theme: .baneyspaces, palette: "auto", accent: AccentPreset.red.rgb)
        var s = AppearanceSettings()
        s.panelStyle = .solid
        XCTAssertEqual(PanelLook.make(.dockBar, look: look, settings: s, accent: AccentPreset.red.rgb).fillOpacity, 1)
        s.panelStyle = .tinted
        s.panelOpacity = 0.7
        let p = PanelLook.make(.dockBar, look: look, settings: s, accent: AccentPreset.blue.rgb)
        XCTAssertEqual(p.fillOpacity, 0.7)
        XCTAssertEqual(p.wash, AccentPreset.blue.rgb)
        // Omarchy's fill isn't adjustable: opaque whatever the slider says.
        let omarchy = Look(theme: .omarchy, palette: "auto", accent: AccentPreset.red.rgb)
        let o = PanelLook.make(.dockBar, look: omarchy, settings: s, accent: AccentPreset.blue.rgb)
        XCTAssertEqual(o.fillOpacity, 1)
        XCTAssertNil(o.wash)
        XCTAssertFalse(o.blur)
    }

    func testEverySurfaceKeepsItsShippedRadiusAndBorderInTheBaneySpacesTheme() {
        for s in Surface.allCases {
            let st = SurfaceStyle.make(s, theme: .baneyspaces, spec: t)
            XCTAssertEqual(st.radius, s.shippedRadius, "\(s)")
            XCTAssertEqual(st.borderWidth, s.shippedBorder.rest, "\(s)")
            XCTAssertEqual(st.focusedBorderWidth, s.shippedBorder.focused, "\(s)")
        }
        // The values the view code had.
        XCTAssertEqual(Surface.dockBar.shippedRadius, 24)
        XCTAssertEqual(Surface.dockTile.shippedRadius, 16)
        XCTAssertEqual(Surface.switcherPanel.shippedRadius, 26)
        XCTAssertEqual(Surface.launcherPanel.shippedRadius, 22)
        XCTAssertEqual(Surface.overviewTile.shippedBorder.focused, 3)
    }

    func testTheBaneySpacesThemeLeavesDurationsFontsAndGrowthAsTheyWere() {
        for k in [MotionKind.panelIn, .panelOut, .listIn, .listOut, .row] {
            XCTAssertEqual(t.motion.seconds(0.12, k), 0.12)
        }
        XCTAssertEqual(t.font.size(10.5), 10.5)
        XCTAssertEqual(t.font.weight(.semibold), .semibold)
        XCTAssertTrue(t.motion.slides)
    }

    func testDockMotionReadsTheTheme() {
        XCTAssertEqual(DockMotion.slide, 8)
        XCTAssertEqual(DockMotion.dockIn, 0.18)
        XCTAssertEqual(DockMotion.dockOut, 0.14)
        XCTAssertEqual(DockMotion.listIn, 0.14)
        XCTAssertEqual(DockMotion.listOut, 0.10)
        XCTAssertEqual(DockMotion.rowHover, 0.08)
        XCTAssertEqual(DockMotion.settle, 0.12)
        XCTAssertEqual(DockMotion.listScale, 0.96)
        XCTAssertEqual(DockMotion.lift, 1.04)
        inTheme(.omarchy) {
            XCTAssertEqual(DockMotion.dockIn, 0.12)
            XCTAssertEqual(DockMotion.dockOut, 0.10)
            XCTAssertEqual(DockMotion.listIn, 0.10)
            XCTAssertEqual(DockMotion.listOut, 0.08)
            // Fades only: nothing slides, scales or lifts.
            XCTAssertEqual(DockMotion.slide, 0)
            XCTAssertEqual(DockMotion.listScale, 1)
            XCTAssertEqual(DockMotion.lift, 1)
            XCTAssertEqual(DockMotion.rowHover, 0)
            XCTAssertEqual(DockMotion.settle, 0)
            XCTAssertEqual(DockEdge.bottom.away, CGVector(dx: 0, dy: 0))
            // Reduce Motion still zeroes every one.
            for d in [DockMotion.dockIn, DockMotion.dockOut, DockMotion.listIn, DockMotion.listOut] {
                XCTAssertEqual(DockMotion.duration(d, reduceMotion: true), 0)
            }
        }
        inTheme(.minimal) {
            XCTAssertEqual(DockMotion.dockIn, 0.10)
            XCTAssertEqual(DockMotion.slide, 0)
        }
        XCTAssertEqual(DockMotion.dockIn, 0.18, "the theme is put back")
    }

    func testDockEnabledIsABoolWithAMacOSException() throws {
        // `default` stays a plain bool, so another platform's reader still parses it.
        let data = try Repo.text("spec/themes.json").data(using: .utf8)!
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let dock = (root["settings"] as! [String: Any])["dock.enabled"] as! [String: Any]
        XCTAssertEqual(dock["default"] as? Bool, true)
        XCTAssertEqual(dock["default_by_platform"] as? [String: Bool], ["macos": false])
        XCTAssertFalse(ThemeCatalog.shared.dockEnabled(platform: "macos"))
        XCTAssertTrue(ThemeCatalog.shared.dockEnabled(platform: "windows"))
        XCTAssertTrue(ThemeCatalog.shared.dockEnabled(platform: "linux"))
        XCTAssertTrue(ThemeCatalog.shared.dockEnabled(platform: "omarchy"))
        // The app reads it for an unset switch.
        let dockSource = try Repo.code("Sources/BaneySpaces/WorkspaceDock.swift")
        XCTAssertTrue(dockSource.contains("ThemeCatalog.shared.dockEnabled()"))
    }

    func testOmarchyIsBlocky() {
        let o = ThemeCatalog.shared.spec(.omarchy)
        XCTAssertEqual([o.radius.bar, o.radius.tile, o.radius.row, o.radius.list], [0, 0, 0, 0])
        XCTAssertEqual(o.border.width, 2)
        XCTAssertEqual(o.border.focusedRole, "accent")
        XCTAssertEqual(o.border.focusedWidth, 2)
        XCTAssertEqual(o.border.opacity, 1)
        XCTAssertEqual(o.fill.tintRole, "background")
        XCTAssertEqual(o.fill.opacity * o.fill.tintOpacity, 1)
        XCTAssertFalse(o.fill.blur)
        XCTAssertNil(o.shadow)
        XCTAssertEqual(o.font.family, "monospace")
        XCTAssertEqual(o.indicator, .numberBlock)
        for s in Surface.allCases {
            let st = SurfaceStyle.make(s, theme: .omarchy, spec: o)
            XCTAssertEqual(st.radius, 0, "\(s)")
            XCTAssertEqual(st.borderWidth, 2, "\(s)")
            XCTAssertEqual(st.focusedBorderWidth, 2, "\(s)")
        }
        let pl = PanelLook.make(.dockBar, look: Look(theme: .omarchy, palette: "gruvbox", accent: AccentPreset.red.rgb),
                                settings: AppearanceSettings(), accent: AccentPreset.red.rgb)
        XCTAssertEqual(pl.border.top, 1)
        XCTAssertEqual(pl.border.bottom, 1)
        XCTAssertEqual(pl.fill, PaletteCatalog.shared.named("gruvbox")?.color("background"))
    }

    func testAnyThemeTakesAnyPaletteAndAutoIsTheDefault() {
        let s = AppearanceSettings()
        XCTAssertEqual(s.theme, .baneyspaces)
        XCTAssertEqual(s.colorPalette, "auto")
        for id in ThemeID.allCases {
            for name in PaletteCatalog.shared.names + ["auto"] {
                let l = Look(theme: id, palette: name, accent: AccentPreset.red.rgb)
                XCTAssertEqual(l.isAuto, name == "auto")
                XCTAssertEqual(l.palette.colors.count, 12)
            }
        }
        // Auto follows the accent.
        XCTAssertEqual(Look(theme: .omarchy, palette: "auto", accent: AccentPreset.teal.rgb).color("accent"), AccentPreset.teal.rgb)
        // The workspace role is the workspace's own tint.
        let tint = RGB(r: 0.2, g: 0.4, b: 0.6)
        XCTAssertEqual(Look(theme: .baneyspaces, palette: "auto", accent: AccentPreset.red.rgb).color("workspace", workspace: tint), tint)
    }

    func testTheThemeAndPaletteAreSavedWithTheOtherAppearanceSettings() {
        var s = AppearanceSettings()
        s.theme = .omarchy
        s.colorPalette = "nord"
        s.panelStyle = .tinted
        let back = AppearanceSettings.decoded(s.encoded())
        XCTAssertEqual(back.theme, .omarchy)
        XCTAssertEqual(back.colorPalette, "nord")
        XCTAssertEqual(back.panelStyle, .tinted)
        // A blob from before themes existed is the default look.
        let old = AppearanceSettings.decoded(#"{"panelStyle":"solid"}"#.data(using: .utf8))
        XCTAssertEqual(old.theme, .baneyspaces)
        XCTAssertEqual(old.colorPalette, "auto")
        XCTAssertEqual(old.panelStyle, .solid)
        // A theme or palette this build doesn't know is the default, and the rest is kept.
        let odd = AppearanceSettings.decoded(#"{"theme":"vaporwave","colorPalette":"nope","dockSize":"large"}"#.data(using: .utf8))
        XCTAssertEqual(odd.theme, .baneyspaces)
        XCTAssertEqual(odd.colorPalette, "auto")
        XCTAssertEqual(odd.dockSize, .large)
    }
}
