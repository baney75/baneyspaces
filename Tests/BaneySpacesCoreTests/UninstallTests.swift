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

    private func uninstall() throws -> String {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("uninstall.sh")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "BANEYSPACES_UNINSTALL_TEST": "1"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, out)
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

    /// Nothing installed at all: it still finishes cleanly, so running it twice is safe.
    func testRunsOnAnEmptyHome() throws {
        let out = try uninstall()
        XCTAssertTrue(out.contains("BaneySpaces is removed."), out)
    }
}
