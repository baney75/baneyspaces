import XCTest
@testable import BaneySpacesCore

/// A theme's family is resolved to the face of the weight asked for (the launcher's regular search
/// text came out Light, and a Nerd Font's faces aren't named like its family).
final class FontFaceTests: XCTestCase {
    func testAFamilyResolvesToTheNearestWeight() throws {
        // Menlo ships with every Mac: a regular and a bold.
        let regular = try XCTUnwrap(FontFace.resolve(families: ["Menlo"], weight: .regular, size: 12))
        let bold = try XCTUnwrap(FontFace.resolve(families: ["Menlo"], weight: .bold, size: 12))
        XCTAssertEqual(FontFace.weight(of: regular), 0, accuracy: 0.1)
        XCTAssertEqual(FontFace.weight(of: bold), 0.4, accuracy: 0.1)
        // Semibold is nearer Bold than Regular in a family that has only those two.
        let semi = try XCTUnwrap(FontFace.resolve(families: ["Menlo"], weight: .semibold, size: 12))
        XCTAssertEqual(FontFace.weight(of: semi), FontFace.weight(of: bold), accuracy: 0.01)
        XCTAssertEqual(CTFontGetSize(regular), 12)
    }

    func testAFamilyThatIsNotInstalledIsSkippedAndNoneIsNil() throws {
        let face = try XCTUnwrap(FontFace.resolve(families: ["No Such Family 123", "Menlo"], weight: .regular, size: 13))
        XCTAssertEqual(CTFontCopyFamilyName(face) as String, "Menlo")
        XCTAssertNil(FontFace.resolve(families: ["No Such Family 123"], weight: .regular, size: 13))
    }

    func testOmarchyAtRegularAndSemiboldAreFacesOfThoseWeights() throws {
        let families = ThemeCatalog.shared.fontFamilies(ThemeCatalog.shared.spec(.omarchy).font.family)
        try XCTSkipUnless(FontFace.installedFamilies.contains(families[0]), "\(families[0]) isn't installed here")
        let regular = try XCTUnwrap(FontFace.resolve(families: families, weight: .regular, size: 12))
        let semibold = try XCTUnwrap(FontFace.resolve(families: families, weight: .semibold, size: 12))
        XCTAssertEqual(FontFace.weight(of: regular), 0, accuracy: 0.1, "regular is not Light")
        XCTAssertEqual(FontFace.weight(of: semibold), 0.3, accuracy: 0.1)
        XCTAssertLessThan(FontFace.weight(of: regular), FontFace.weight(of: semibold))
        XCTAssertEqual(CTFontCopyFamilyName(regular) as String, families[0])
    }

    func testTheViewsAskForTheFaceNotAFamilyName() throws {
        let theming = try Repo.code("Sources/BaneySpaces/Theming.swift")
        XCTAssertFalse(theming.contains(".custom("), "Font.custom takes a face name, not a family")
        XCTAssertFalse(theming.contains("convertWeight"), "a nudge from one face ignores the weight asked for")
        XCTAssertTrue(theming.contains("FontFace.resolve("))
    }
}
