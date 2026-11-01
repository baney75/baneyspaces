import XCTest
@testable import BaneySpacesCore

/// The app embeds spec/themes.json and spec/palettes.json (`ThemeData`, made by
/// scripts/gen-theme-data.sh). These fail when the embedded copy and spec/ differ.
final class ThemeDataTests: XCTestCase {
    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    func testTheEmbeddedThemesAreTheSpecFile() throws {
        XCTAssertEqual(trimmed(ThemeData.themesJSON), trimmed(try Repo.text("spec/themes.json")),
                       "run scripts/gen-theme-data.sh")
    }

    func testTheEmbeddedPalettesAreTheSpecFile() throws {
        XCTAssertEqual(trimmed(ThemeData.palettesJSON), trimmed(try Repo.text("spec/palettes.json")),
                       "run scripts/gen-theme-data.sh")
    }

    func testThreeThemesAndTwentyTwoPalettesWithEveryRole() {
        XCTAssertEqual(Set(ThemeCatalog.shared.themes.keys), ["baneyspaces", "omarchy", "minimal"])
        let palettes = PaletteCatalog.shared.palettes
        XCTAssertEqual(palettes.count, 22)
        for p in palettes {
            XCTAssertEqual(Set(p.colors.keys), Set(Palette.roles), p.name)
        }
        XCTAssertEqual(palettes.map(\.name), palettes.map(\.name).sorted())
    }

    func testTheFontsHaveAMacOSList() {
        for id in ThemeID.allCases {
            let key = ThemeCatalog.shared.spec(id).font.family
            XCTAssertFalse(ThemeCatalog.shared.fontFamilies(key).isEmpty, "\(id) \(key)")
        }
    }
}
