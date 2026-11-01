import XCTest
@testable import BaneySpacesCore

final class OverviewFilterTests: XCTestCase {
    private func filter(_ rows: [(WindowID, Int, String, String)]) -> OverviewFilter {
        OverviewFilter(rows.map { OverviewFilter.Item(id: $0.0, workspace: $0.1, app: $0.2, title: $0.3) })
    }

    private let donovan: [(WindowID, Int, String, String)] = [
        (1, 1, "Microsoft Word", "Document1"), (2, 1, "Helium", "Question 1 of 13 - Week 10: SN2 and E2 - Helium"),
        (3, 1, "Obsidian", "Dashboard - BaneyVault - Obsidian 1.14.5"), (4, 1, "T3 Code (Nightly)", ""),
        (5, 1, "Microsoft Excel", "Acetate_Distillation_Unknowns_B_and_C"), (6, 1, "Grok Bot", ""), (7, 1, "Terminal", ""),
    ]

    func testExcFindsExcelAndReturnGoesThere() {
        let r = filter(donovan).match("exc")
        XCTAssertEqual(r.best, 5)
        XCTAssertTrue(r.matches(5))
        XCTAssertFalse(r.matches(1))
        XCTAssertFalse(r.matches(2), "letters scattered through a long title don't light a window")
    }

    func testTheTitleCountsAsWellAsTheApp() {
        let r = filter(donovan).match("distill")
        XCTAssertEqual(r.best, 5)
        XCTAssertEqual(filter(donovan).match("quiz").best, nil)
        XCTAssertEqual(filter(donovan).match("quest").best, 2)
    }

    func testInitialsAndLooseAppLettersMatchLikeTheLauncher() {
        XCTAssertEqual(filter(donovan).match("mw").matches(1), true, "initials of Microsoft Word")
        XCTAssertEqual(filter(donovan).match("tmnl").best, 7, "letters in order, as the launcher finds Safari from sfr")
        XCTAssertEqual(filter(donovan).match("t3").best, 4)
    }

    func testNothingMatchesAndAnEmptyQueryPicksNothing() {
        let none = filter(donovan).match("zzqx")
        XCTAssertTrue(none.isEmpty)
        XCTAssertNil(none.best)
        let all = filter(donovan).match("")
        XCTAssertNil(all.best)
        XCTAssertEqual(all.scores.count, 7, "no filter, every card lit")
    }

    func testATieGoesToTheWorkspaceShownThenTheLowerOne() {
        let f = filter([(1, 4, "Ghostty", "a"), (2, 2, "Ghostty", "b"), (3, 7, "Ghostty", "c")])
        XCTAssertEqual(f.match("ghostty", prefer: 7).best, 3)
        XCTAssertEqual(f.match("ghostty", prefer: 1).best, 2)
    }

    func testAccentsAndCaseFoldAway() {
        let f = filter([(1, 1, "Café", "Menü")])
        XCTAssertEqual(f.match("CAFE").best, 1)
        XCTAssertEqual(f.match("menu").best, 1)
    }

    /// 200 windows, a keystroke at a time: under 8 ms each (spec/overview.md, Speed).
    func testEachKeystrokeAnswersWithin8MillisecondsFor200Windows() {
        let apps = ["Safari", "Notes", "Terminal", "Microsoft Excel", "Ghostty", "Obsidian", "Helium", "Mail", "Calendar", "Preview"]
        let words = ["quarterly report", "Swift documentation", "~/Projects/baneyspaces", "Question 1 of 13 - Week 10: SN2 and E2", "Inbox (42)",
                     "Acetate_Distillation_Unknowns_B_and_C", "Pull request #126", "Untitled", "Dashboard - BaneyVault", "Launch checklist"]
        var rows: [(WindowID, Int, String, String)] = []
        for i in 0..<200 { rows.append((WindowID(i + 1), i % 9 + 1, apps[i % apps.count], "\(words[(i * 7) % words.count]) \(i)")) }
        let f = filter(rows)
        var slowest: Double = 0
        for q in ["e", "ex", "exc", "exce", "excel", "x", "term", "t", "tr", "ghost", "swift doc", "zzzzzzzz", "q", "qu", "quarterly rep"] {
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = f.match(q, prefer: 1)
            slowest = max(slowest, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        XCTAssertLessThan(slowest, 8, "the slowest keystroke took \(slowest) ms")
    }

    func testDimmedCardsAreAQuarter() {
        XCTAssertEqual(OverviewFilter.dimmedOpacity, 0.25)
    }
}

final class OverviewHelpTests: XCTestCase {
    func testTheLineHidesAfterTwentyOpensAndQuestionMarkShowsItAgain() {
        var h = OverviewHelp()
        XCTAssertEqual(OverviewHelp.line, "1–9 go · type to find · drag to move · esc")
        for _ in 0..<19 { h.opened() }
        XCTAssertTrue(h.visible, "the 19th open still shows it")
        h.opened()
        XCTAssertEqual(h.opens, 20)
        XCTAssertFalse(h.visible, "hidden once it has been opened 20 times")
        h.toggle()
        XCTAssertTrue(h.visible, "? shows it again")
        h.toggle()
        XCTAssertFalse(h.visible)
        h.toggle()
        h.opened()
        XCTAssertFalse(h.visible, "the next visit starts hidden again")
    }
}

final class OverviewMotionTests: XCTestCase {
    private func spec(_ id: ThemeID) -> ThemeSpec { ThemeCatalog.shared.spec(id) }

    func testCardsTravelFromTheirWindowsWithPreviewsInAThemeThatMoves() {
        XCTAssertEqual(OverviewMotion.plan(spec: spec(.baneyspaces), previews: true, reduceMotion: false), .travel)
    }

    func testWithoutPreviewsTheyFadeAndScaleFromNinetySixPercent() {
        XCTAssertEqual(OverviewMotion.plan(spec: spec(.baneyspaces), previews: false, reduceMotion: false), .scale(from: 0.96))
    }

    func testOmarchyAndMinimalOnlyFade() {
        for id in [ThemeID.omarchy, .minimal] {
            XCTAssertEqual(OverviewMotion.plan(spec: spec(id), previews: true, reduceMotion: false), .fade, "\(id)")
            XCTAssertEqual(OverviewMotion.plan(spec: spec(id), previews: false, reduceMotion: false), .fade, "\(id)")
        }
    }

    func testReduceMotionIsNone() {
        for id in ThemeID.allCases { XCTAssertEqual(OverviewMotion.plan(spec: spec(id), previews: true, reduceMotion: true), .none) }
    }

    func testTheSpringSettlesAboutWhenConfigMdSays() {
        // config.md: a 180 ms transition has a 0.32 s response.
        let s = OverviewSpring.opening(spec: spec(.baneyspaces))
        XCTAssertEqual(s.response, 0.324, accuracy: 0.01)
        XCTAssertEqual(s.damping, 0.86)
        XCTAssertGreaterThan(s.stiffness, 0)
        XCTAssertEqual(s.dampingCoefficient, 2 * s.damping * s.stiffness.squareRoot(), accuracy: 1e-9)
        XCTAssertLessThan(OverviewSpring.closing(spec: spec(.baneyspaces)).response, 0.5)
    }
}

/// The workspace you're on, per theme: the theme's focused border in accent (spec/overview.md).
final class OverviewMarkTests: XCTestCase {
    func testTheCurrentWorkspaceIsMarkedInAccentInEveryThemeAndNeverUrgent() {
        for id in ThemeID.allCases {
            let m = OverviewMark.current(ThemeCatalog.shared.spec(id), theme: id)
            XCTAssertEqual(m.role, "accent", "\(id)")
            XCTAssertNotEqual(m.role, "urgent", "red means something is wrong")
        }
    }

    func testBaneySpacesIsASoftGlowOmarchyTwoPixelsMinimalOne() throws {
        let t = { (id: ThemeID) in OverviewMark.current(ThemeCatalog.shared.spec(id), theme: id) }
        XCTAssertTrue(t(.baneyspaces).glow)
        XCTAssertFalse(t(.omarchy).glow)
        XCTAssertFalse(t(.minimal).glow)
        XCTAssertEqual(t(.omarchy).width, 2)
        XCTAssertEqual(t(.minimal).width, 1)
        // Read from themes.json afresh, so the numbers can't drift from the spec.
        let json = try JSONSerialization.jsonObject(with: Repo.text("spec/themes.json").data(using: .utf8)!) as! [String: Any]
        let themes = json["themes"] as! [String: [String: Any]]
        for id in [ThemeID.omarchy, .minimal] {
            let border = themes[id.rawValue]!["border"] as! [String: Any]
            XCTAssertEqual(t(id).width, (border["focused_width"] as! NSNumber).doubleValue)
            XCTAssertEqual(border["focused_role"] as? String, "accent")
        }
    }

    func testEveryPaletteGivesTheMarkItsOwnAccent() {
        for id in ThemeID.allCases {
            for name in PaletteCatalog.shared.names {
                let look = Look(theme: id, palette: name, accent: AccentPreset.blue.rgb)
                let m = OverviewMark.current(look.spec, theme: id)
                XCTAssertEqual(look.color(m.role), PaletteCatalog.shared.named(name)?.color("accent"), "\(id) \(name)")
            }
            // Auto: the accent chosen in Settings.
            let auto = Look(theme: id, palette: "auto", accent: AccentPreset.teal.rgb)
            XCTAssertEqual(auto.color(OverviewMark.current(auto.spec, theme: id).role), AccentPreset.teal.rgb)
        }
    }

    func testTheOverviewSurfacesTakeTheirRadiusAndBorderFromEveryTheme() {
        let surfaces: [Surface] = [.overviewTile, .overviewChip, .overviewCard, .overviewSlot]
        for id in ThemeID.allCases {
            let spec = ThemeCatalog.shared.spec(id)
            for s in surfaces {
                let st = SurfaceStyle.make(s, theme: id, spec: spec)
                XCTAssertEqual(st.radius, s.shippedRadius * (spec.radius.value(s.kind) / ThemeCatalog.shared.spec(.baneyspaces).radius.value(s.kind)), accuracy: 1e-9)
                if id == .omarchy { XCTAssertEqual(st.radius, 0, "\(s) is square in Omarchy") }
                if id != .baneyspaces { XCTAssertEqual(st.focusedBorderWidth, spec.border.focusedWidth) }
            }
        }
    }

    func testTheOverviewMetricsFollowEachThemesDensity() {
        let b = OverviewMetrics.make(spec: ThemeCatalog.shared.spec(.baneyspaces))
        let o = OverviewMetrics.make(spec: ThemeCatalog.shared.spec(.omarchy))
        let m = OverviewMetrics.make(spec: ThemeCatalog.shared.spec(.minimal))
        XCTAssertEqual(b.slot, 64, "a strip slot is a dock tile")
        XCTAssertEqual(o.slot, 48)
        XCTAssertEqual(m.slot, 40)
        XCTAssertGreaterThan(b.tileGap, o.tileGap)
        XCTAssertGreaterThan(o.tileGap, m.tileGap)
    }
}
