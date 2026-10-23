import XCTest

/// uninstall.sh against a made-up home folder: everything BaneySpaces added goes, everything the
/// person had stays. Commands that would touch this Mac's real settings, permissions or
/// processes only print (BANEYSPACES_UNINSTALL_TEST).
final class UninstallTests: XCTestCase {
    private let fm = FileManager.default
    private var home: URL!

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appendingPathComponent("bs-uninstall-\(UUID().uuidString)").resolvingSymlinksInPath()
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: home) }

    private func path(_ p: String) -> URL { home.appendingPathComponent(p) }

    private func write(_ p: String, _ text: String) throws {
        try fm.createDirectory(at: path(p).deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: path(p), atomically: true, encoding: .utf8)
    }

    private func uninstall(status: Int32 = 0, prefs: [String: Any]? = nil, macOS: String? = nil) throws -> String {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("uninstall.sh")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        var env = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "BANEYSPACES_UNINSTALL_TEST": "1"]
        if let prefs {
            let file = home.appendingPathComponent("prefs.plist")
            try PropertyListSerialization.data(fromPropertyList: prefs, format: .xml, options: 0).write(to: file)
            env["BANEYSPACES_UNINSTALL_PREFS"] = file.path
        }
        if let macOS { env["BANEYSPACES_UNINSTALL_MACOS"] = macOS }
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, status, out)
        return out
    }

    func testRemovesWhatItAddedAndKeepsWhatWasThere() throws {
        let app = "Applications/BaneySpaces.app"
        try write("\(app)/Contents/MacOS/BaneySpaces", "#!/bin/sh\n")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path("\(app)/Contents/MacOS/BaneySpaces").path)
        try write("Library/Application Support/BaneySpaces/state.json", "{}")
        try write("Library/Caches/com.baney.baneyspaces/x", "")
        try write(".claude/skills/baneyspaces/SKILL.md", "skill")
        try write(".claude/skills/other/SKILL.md", "theirs")
        try write(".grok/hooks/baneyspaces.json", "{}")
        try write(".grok/hooks/theirs.json", "{}")
        // Settings kept in a dotfiles folder, linked in, private to the owner.
        let ours = "'/Users/x/.local/bin/baneyspaces' hook claude 2>/dev/null || true"
        let settings: [String: Any] = [
            "model": "opus",
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": "say done"]]],
                         ["hooks": [["type": "command", "command": ours, "async": true]]]],
                "Notification": [["hooks": [["type": "command", "command": ours]]]],
                "PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "guard.sh"],
                                                             ["type": "command", "command": ours]]]],
            ],
        ]
        try write("dotfiles/settings.json", String(decoding: try JSONSerialization.data(withJSONObject: settings), as: UTF8.self))
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path("dotfiles/settings.json").path)
        try fm.createDirectory(at: path(".claude"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: path(".claude/settings.json"), withDestinationURL: path("dotfiles/settings.json"))
        try fm.createDirectory(at: path(".local/bin"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: path(".local/bin/baneyspaces").path, withDestinationPath: path("\(app)/Contents/Resources/bin/baneyspaces").path)
        try fm.createSymbolicLink(atPath: path(".local/bin/ghostdeck").path, withDestinationPath: "/old/BaneySpaces.app/Contents/Resources/bin/baneyspaces")
        try fm.createSymbolicLink(atPath: path(".local/bin/claude").path, withDestinationPath: "/opt/claude")

        let out = try uninstall()

        // Gone: the app, its data, its command, its skill, Grok's hook file.
        for gone in [app, "Library/Application Support/BaneySpaces", "Library/Caches/com.baney.baneyspaces",
                     ".claude/skills/baneyspaces", ".grok/hooks/baneyspaces.json", ".local/bin/baneyspaces", ".local/bin/ghostdeck"] {
            XCTAssertNil(try? fm.attributesOfItem(atPath: path(gone).path), "\(gone) is still there")
        }
        // Kept: other skills, other Grok hooks, other commands.
        for kept in [".claude/skills/other/SKILL.md", ".grok/hooks/theirs.json"] {
            XCTAssertTrue(fm.fileExists(atPath: path(kept).path), "\(kept) was removed")
        }
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: path(".local/bin/claude").path), "/opt/claude")

        // Claude Code's settings: still a link to the same private file, our hooks gone, theirs kept.
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: path(".claude/settings.json").path))
        XCTAssertEqual((try fm.attributesOfItem(atPath: path("dotfiles/settings.json").path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path("dotfiles/settings.json"))) as? [String: Any])
        XCTAssertEqual(after["model"] as? String, "opus")
        let hooks = try XCTUnwrap(after["hooks"] as? [String: Any])
        XCTAssertNil(hooks["Notification"], "an event left with only our hook goes")
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 1)
        XCTAssertEqual(((stop[0]["hooks"] as? [[String: Any]])?.first?["command"]) as? String, "say done")
        let pre = try XCTUnwrap((hooks["PreToolUse"] as? [[String: Any]])?.first)
        XCTAssertEqual(pre["matcher"] as? String, "Bash")
        XCTAssertEqual((pre["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String }, ["guard.sh"])

        // The Mac-wide steps it would take, each once.
        for step in ["--restore-shortcuts", "--restore-dock", "--unregister-login", "defaults delete com.baney.baneyspaces",
                     "tccutil reset Accessibility com.baney.baneyspaces"] {
            XCTAssertTrue(out.contains("would run: ") && out.contains(step), "missing \(step):\n\(out)")
        }
    }

    /// r2: the app already in the Trash (emptied) can't turn the shortcuts back on. It says so,
    /// exits 2, and keeps its record of them instead of deleting it.
    func testWithoutTheAppItSaysWhatsStillOffAndKeepsTheRecord() throws {
        let out = try uninstall(status: 2, prefs: ["freedShortcuts": [28, 29]])
        XCTAssertTrue(out.contains("screenshot or Spotlight shortcuts are still off"), out)
        XCTAssertFalse(out.contains("defaults delete com.baney.baneyspaces"), out)
        XCTAssertFalse(out.contains("back as they were"), out)
    }

    /// Without the app, Mission Control and fill-the-screen for a drag to the top still go back:
    /// one saved as on is turned on, one that wasn't set is unset again.
    func testWithoutTheAppItPutsTheTopDragSettingsBack() throws {
        let saved = ["com.apple.dock/enterMissionControlByTopWindowDrag": true]
        let out = try uninstall(prefs: ["systemTopDragSaved": saved], macOS: "0")
        XCTAssertTrue(out.contains("would run: defaults write com.apple.dock enterMissionControlByTopWindowDrag -bool true"), out)
        XCTAssertTrue(out.contains("would run: defaults delete com.apple.WindowManager EnableTopTilingByEdgeDrag"), out)
        XCTAssertTrue(out.contains("would run: killall Dock") && out.contains("would run: killall WindowManager"), out)
    }

    /// One switched back on since in System Settings is the person's choice and stays.
    func testLeavesATopDragSettingTurnedOnSince() throws {
        let out = try uninstall(prefs: ["systemTopDragSaved": [String: Bool]()], macOS: "1")
        XCTAssertFalse(out.contains("enterMissionControlByTopWindowDrag"), out)
    }

    /// r2: one in the Trash still counts as the app.
    func testUsesTheAppFromTheTrash() throws {
        try write(".Trash/BaneySpaces 2.app/Contents/MacOS/BaneySpaces", "#!/bin/sh\n")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path(".Trash/BaneySpaces 2.app/Contents/MacOS/BaneySpaces").path)
        let out = try uninstall(prefs: ["freedShortcuts": [28]])
        XCTAssertTrue(out.contains("BaneySpaces 2.app/Contents/MacOS/BaneySpaces --restore-shortcuts"), out)
    }

    /// r2: the installer stops AeroSpace opening at login, and writes that down; uninstalling
    /// puts both back.
    func testPutsAeroSpaceBack() throws {
        try write(".aerospace.toml", "after-login-command = []\nstart-at-login = false\n")
        try write("Library/Application Support/BaneySpaces/aerospace-start-at-login", "")
        try write("Applications/AeroSpace.app/Contents/Info.plist", "")
        try write("Library/Application Support/BaneySpaces/aerospace-login-item", path("Applications/AeroSpace.app").path)
        let out = try uninstall()
        XCTAssertTrue(try String(contentsOf: path(".aerospace.toml"), encoding: .utf8).contains("start-at-login = true"))
        XCTAssertTrue(out.contains("make login item") && out.contains("AeroSpace.app"), out)
    }

    /// r4: AeroSpace gone from where it was: said so, not skipped quietly behind "back as they were".
    func testSaysWhenAeroSpaceMoved() throws {
        try write("Library/Application Support/BaneySpaces/aerospace-login-item", "/nowhere/AeroSpace.app")
        let out = try uninstall(status: 2)
        XCTAssertTrue(out.contains("isn't any more"), out)
    }

    /// r4: a failed removal is listed once, with what to do.
    func testAnAppThatWontGoIsListedOnce() throws {
        try write("Applications/BaneySpaces.app/Contents/MacOS/BaneySpaces", "#!/bin/sh\n")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path("Applications/BaneySpaces.app/Contents/MacOS/BaneySpaces").path)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path("Applications/BaneySpaces.app/Contents").path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path("Applications/BaneySpaces.app/Contents").path) }
        let out = try uninstall(status: 2)
        XCTAssertEqual(out.components(separatedBy: "Couldn't remove").count - 1, 1, out)
        XCTAssertFalse(out.contains("A step failed"), out)
    }

    /// Never told: AeroSpace's own choice stays.
    func testLeavesAeroSpaceAloneWithoutARecord() throws {
        try write(".aerospace.toml", "start-at-login = false\n")
        _ = try uninstall()
        XCTAssertTrue(try String(contentsOf: path(".aerospace.toml"), encoding: .utf8).contains("start-at-login = false"))
    }

    /// r3: a hook whose path is in double quotes, which JSON writes as \".
    func testRemovesAHookWithADoubleQuotedPath() throws {
        let settings: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": "\"/Users/x/.local/bin/baneyspaces\" hook claude"]]]]]]
        try write(".claude/settings.json", String(decoding: try JSONSerialization.data(withJSONObject: settings), as: UTF8.self))
        _ = try uninstall()
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path(".claude/settings.json"))) as? [String: Any])
        XCTAssertNil(after["hooks"])
    }

    /// r3: a step that fails partway doesn't stop the rest or get called "stopped before
    /// removing anything": everything else goes, and the exit is 2.
    func testAFailedStepIsListedAndTheRestStillGoes() throws {
        try write(".aerospace.toml", "start-at-login = false\n")
        try write("Library/Application Support/BaneySpaces/aerospace-start-at-login", "")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path(".aerospace.toml").path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path(".aerospace.toml").path) }
        try write(".claude/skills/baneyspaces/SKILL.md", "skill")
        let out = try uninstall(status: 2)
        XCTAssertTrue(out.contains("set start-at-login = true"), out)
        XCTAssertFalse(fm.fileExists(atPath: path(".claude/skills/baneyspaces").path))
        XCTAssertFalse(fm.fileExists(atPath: path("Library/Application Support/BaneySpaces").path))
    }

    /// r3: an empty record (nothing was ever turned off) isn't "still off".
    func testAnEmptyShortcutRecordIsNothingToRestore() throws {
        let out = try uninstall(prefs: ["freedShortcuts": [Int]()])
        XCTAssertTrue(out.contains("defaults delete com.baney.baneyspaces"), out)
    }

    /// Nothing installed at all: it still finishes cleanly, so running it twice is safe.
    func testRunsOnAnEmptyHome() throws {
        let out = try uninstall()
        XCTAssertTrue(out.contains("BaneySpaces is removed."), out)
    }
}
