import XCTest

/// install.sh and package.sh as text: the release key is pinned in both, the download is checked
/// against it before anything installs, and the source build (which needs the command line tools)
/// only runs when there is no prebuilt app. The end-to-end run is in the pull request.
final class InstallScriptTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func index(of needle: String, in text: String, file: StaticString = #filePath, line: UInt = #line) throws -> String.Index {
        try XCTUnwrap(text.range(of: needle)?.lowerBound, "missing: \(needle)", file: file, line: line)
    }

    private func requirement() throws -> String {
        try read("scripts/release-requirement.txt").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testRequirementIsThePinnedReleaseKey() throws {
        XCTAssertEqual(try requirement(),
                       #"identifier "com.baney.baneyspaces" and certificate leaf = H"d1cfbd7446f84f6c625b9db83c5bf96da33b157e""#)
    }

    func testInstallShInlinesTheSameRequirement() throws {
        XCTAssertTrue(try read("install.sh").contains("REQUIREMENT='\(try requirement())'"))
    }

    func testPackageShReadsTheRequirementAndRefusesOtherBuilds() throws {
        let package = try read("scripts/package.sh")
        XCTAssertTrue(package.contains("scripts/release-requirement.txt"))
        XCTAssertTrue(package.contains(#"codesign -v -R "=$REQ""#))
        XCTAssertLessThan(try index(of: "codesign -v -R", in: package), try index(of: "ditto -c -k --keepParent", in: package))
    }

    func testInstallShVerifiesBeforeRunningTheInstaller() throws {
        let install = try read("install.sh")
        let verify = try index(of: #"codesign -v -R "=$REQUIREMENT""#, in: install)
        XCTAssertLessThan(try index(of: "codesign --verify --strict --deep", in: install), verify)
        XCTAssertLessThan(verify, try index(of: "Resources/install-app.sh", in: install))
        // A pinned commit is checked before anything installs, too.
        XCTAssertLessThan(try index(of: "BaneySpacesCommit", in: install), try index(of: "Resources/install-app.sh", in: install))
    }

    func testCommandLineToolsAreOnlyCheckedOnTheSourcePath() throws {
        let install = try read("install.sh")
        let prebuiltExit = try index(of: "Resources/install-app.sh", in: install)
        XCTAssertLessThan(prebuiltExit, try index(of: "xcode-select -p", in: install))
        XCTAssertEqual(install.components(separatedBy: "xcode-select -p").count, 2, "checked once")
        XCTAssertTrue(install.contains("BANEYSPACES_FROM_SOURCE"))
    }

    func testBundleShShipsAndCallsTheInstallStep() throws {
        let bundle = try read("scripts/bundle.sh")
        XCTAssertTrue(bundle.contains(#"cp scripts/install-app.sh "$APP/Contents/Resources/install-app.sh""#))
        XCTAssertTrue(bundle.contains(#"scripts/install-app.sh "$APP""#))
    }
}
