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
        let verify = try index(of: #"codesign -v -R "=$REQUIREMENT" "$APP""#, in: install)
        XCTAssertLessThan(try index(of: "codesign --verify --strict --deep", in: install), verify)
        XCTAssertLessThan(verify, try index(of: "Resources/install-app.sh", in: install))
        // A pinned commit is checked before anything installs, too.
        XCTAssertLessThan(try index(of: "BaneySpacesCommit", in: install), try index(of: "Resources/install-app.sh", in: install))
    }

    func testCommandLineToolsAreOnlyCheckedOnTheSourcePath() throws {
        let install = try read("install.sh")
        // The tools gate (the one that opens Apple's installer) sits after the prebuilt install.
        let prebuiltExit = try index(of: "Resources/install-app.sh", in: install)
        XCTAssertLessThan(prebuiltExit, try index(of: "xcode-select --install", in: install))
        XCTAssertLessThan(prebuiltExit, try index(of: "if ! have_tools; then", in: install))
        XCTAssertTrue(install.contains("BANEYSPACES_FROM_SOURCE"))
    }

    func testBundleShShipsAndCallsTheInstallStep() throws {
        let bundle = try read("scripts/bundle.sh")
        XCTAssertTrue(bundle.contains(#"cp scripts/install-app.sh "$APP/Contents/Resources/install-app.sh""#))
        XCTAssertTrue(bundle.contains(#"scripts/install-app.sh "$APP""#))
    }

    func testAnInstalledCopyWithAnotherSignerIsUpdatedFromSourceWhenToolsAreHere() throws {
        let install = try read("install.sh")
        let check = try index(of: #"codesign -v -R "=$REQUIREMENT" "$EXISTING""#, in: install)
        let source = try index(of: "FROM_SOURCE=1\n", in: install)
        XCTAssertLessThan(check, source)
        XCTAssertLessThan(source, try index(of: "latest/download/BaneySpaces.zip", in: install), "decided before any download")
        XCTAssertTrue(install.contains("macOS will ask for the Accessibility permission once more"))
    }

    func testTheDownloadUsesNoAPIAndTellsAMissingAppFromAFailure() throws {
        let install = try read("install.sh")
        XCTAssertFalse(install.contains("api.github.com"))
        XCTAssertTrue(install.contains("$BASE/latest/download/BaneySpaces.zip"))
        XCTAssertTrue(install.contains("$BASE/download/$TAG/BaneySpaces.zip"))
        XCTAssertTrue(install.contains("%{http_code}"))
        XCTAssertTrue(install.contains("404) echo"))
        XCTAssertTrue(install.contains("BANEYSPACES_FROM_SOURCE=1"))
    }

    func testTheVersionAndChecksumAreChecked() throws {
        let install = try read("install.sh")
        XCTAssertTrue(install.contains(#"CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist" 2>/dev/null)" != "${TAG#v}""#))
        XCTAssertTrue(install.contains("BaneySpaces.zip.sha256"))
        XCTAssertLessThan(try index(of: "shasum -a 256", in: install), try index(of: "Resources/install-app.sh", in: install))
    }

    func testInstallLocationFollowsTheRunningCopy() throws {
        let installApp = try read("scripts/install-app.sh")
        XCTAssertTrue(installApp.contains("BANEYSPACES_INSTALL_DIR"))
        XCTAssertLessThan(try index(of: #""$HOME/Applications" /Applications"#, in: installApp), try index(of: #"DEST="$DEST_DIR/BaneySpaces.app""#, in: installApp))
        let updater = try read("Sources/BaneySpaces/Updater.swift")
        XCTAssertTrue(updater.contains(#"env["BANEYSPACES_INSTALL_DIR"] = Bundle.main.bundleURL.deletingLastPathComponent().path"#))
    }

    func testTheAppRunsTheInPlaceStepsAtLaunch() throws {
        let delegate = try read("Sources/BaneySpaces/AppDelegate.swift")
        XCTAssertTrue(delegate.contains(#""--in-place""#))
        XCTAssertTrue(delegate.contains("linkCommandIfNeeded()"))
        XCTAssertTrue(delegate.contains("DispatchQueue.global"))
    }

    /// --in-place copies nothing and quits nothing; it only links the command into ~/.local/bin.
    func testInPlaceLinksTheCommandAndCopiesNothing() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("bs-inplace-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: home) }
        let app = home.appendingPathComponent("Apps/BaneySpaces.app")
        try fm.createDirectory(at: app.appendingPathComponent("Contents/Resources/bin"), withIntermediateDirectories: true)
        try "x".write(to: app.appendingPathComponent("Contents/Resources/bin/baneyspaces"), atomically: true, encoding: .utf8)
        let dest = home.appendingPathComponent("elsewhere")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [root.appendingPathComponent("scripts/install-app.sh").path, "--in-place", app.path]
        p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "BANEYSPACES_DEST_DIR": dest.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, out)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: home.appendingPathComponent(".local/bin/baneyspaces").path),
                       app.appendingPathComponent("Contents/Resources/bin/baneyspaces").path)
        XCTAssertFalse(fm.fileExists(atPath: dest.path), "nothing was copied")
        let script = try read("scripts/install-app.sh")
        XCTAssertLessThan(try index(of: "if [ \"$IN_PLACE\" = 0 ]; then\n  rm -rf \"$DEST\"", in: script), try index(of: #"cp -R "$APP" "$DEST""#, in: script))
    }

    func testReleaseIsADraftUntilTheUploadIsCheckedAndPublished() throws {
        let workflow = try read(".github/workflows/release.yml")
        XCTAssertTrue(workflow.contains("gh release create") && workflow.contains("--draft --verify-tag"))
        let release = try read("scripts/release.sh")
        let before = try index(of: "scripts/verify-release.sh build", in: release)
        let upload = try index(of: "gh release upload", in: release)
        let after = try index(of: #"scripts/verify-release.sh "$BACK""#, in: release)
        let publish = try index(of: "gh release edit", in: release)
        XCTAssertLessThan(before, upload)
        XCTAssertLessThan(upload, after)
        XCTAssertLessThan(after, publish)
        XCTAssertTrue(release.contains("--draft=false --latest"))
    }

    func testDiskImageToolIsPinnedByHashAndLivesOutsideBuild() throws {
        let package = try read("scripts/package.sh")
        XCTAssertTrue(package.contains("--require-hashes -r scripts/dmg-requirements.txt"))
        XCTAssertFalse(package.contains("build/.venv"))
        let pins = try read("scripts/dmg-requirements.txt")
        XCTAssertTrue(pins.contains("dmgbuild==") && pins.contains("--hash=sha256:"))
    }

    func testUninstallKeepsTheReleaseSigningKey() throws {
        let uninstall = try read("uninstall.sh")
        XCTAssertTrue(uninstall.contains("RELEASE_REQUIREMENT='\(try requirement())'"))
        XCTAssertLessThan(try index(of: "security find-certificate", in: uninstall), try index(of: "security delete-keychain", in: uninstall))
        XCTAssertTrue(uninstall.contains("BaneySpaces Release Signing"))
    }
}
