import XCTest
@testable import BaneySpacesCore

final class TerminalAgentTests: XCTestCase {
    let both: Set<String> = ["claude", "codex"]

    func testNamesAndCommandsFindTheirAgent() {
        XCTAssertEqual(TerminalAgent.matches("claude", installed: both).map(\.command), ["claude"])
        XCTAssertEqual(TerminalAgent.matches("Claude Code", installed: both).map(\.command), ["claude"])
        XCTAssertEqual(TerminalAgent.matches("codex", installed: both).map(\.command), ["codex"])
        XCTAssertEqual(TerminalAgent.matches("cl", installed: both).map(\.command), ["claude"])
    }

    func testScatteredLettersAndOtherWordsDoNot() {
        XCTAssertEqual(TerminalAgent.matches("cdx", installed: both), [])
        XCTAssertEqual(TerminalAgent.matches("safari", installed: both), [])
        XCTAssertEqual(TerminalAgent.matches("", installed: both).count, 0)
    }

    func testOnlyInstalledAgentsAreOffered() {
        XCTAssertEqual(TerminalAgent.matches("codex", installed: ["claude"]), [])
        XCTAssertEqual(TerminalAgent.matches("claude", installed: []), [])
    }

    func testScriptRunsTheFoundPathFromHomeWithoutAnInteractiveShell() throws {
        let s = try XCTUnwrap(TerminalAgent.all[0].script(at: "/Users/a b/.local/bin/claude"))
        XCTAssertTrue(s.hasPrefix("#!/bin/zsh\ncd ~\n"))
        XCTAssertTrue(s.contains("exec /bin/zsh -l -c \"'/Users/a b/.local/bin/claude'; exec"))
        XCTAssertFalse(s.contains("-il"))
    }

    func testPathsAShellWouldReadAsMoreThanANameAreRefused() {
        for bad in ["claude", "/x/'; rm -rf ~; '", "/x/$(evil)", "/x/`evil`", "/x/\"q", "/x/a\nb"] {
            XCTAssertNil(TerminalAgent.all[0].script(at: bad), bad)
        }
    }

    /// Regression (Donovan, 2026-11-04): Codex from the launcher showed "Allow Ghostty to execute agent-codex.command?".
    func testGhosttyRunsTheScriptFileWithItsPathQuoted() {
        XCTAssertEqual(GhosttyRun.command(script: "/Users/baney/Library/Application Support/BaneySpaces/agent-codex.command"),
                       "/bin/zsh '/Users/baney/Library/Application Support/BaneySpaces/agent-codex.command'")
        XCTAssertEqual(GhosttyRun.command(script: "/a/it's.command"), "/bin/zsh '/a/it'\\''s.command'")
    }

    func testGhosttyIsNeverHandedAScriptFileWhenItCanBeScripted() throws {
        let launcher = try HandsSourceTests.code("Sources/BaneySpaces/Launcher.swift")
        let open = try XCTUnwrap(HandsSourceTests.block(after: "static func open(_ agent: TerminalAgent, at path: String, in terminal: URL)", in: launcher))
        let viaGhostty = try XCTUnwrap(open.range(of: "if isGhostty(terminal), let ghostty { return ghostty(NSHomeDirectory(), url, openFile) }"))
        let fallback = try XCTUnwrap(open.range(of: "\n        openFile()"))
        XCTAssertTrue(viaGhostty.lowerBound < fallback.lowerBound, "Ghostty first, opening the file only as the fallback")
        let brew = try XCTUnwrap(HandsSourceTests.block(after: "private static func runInTerminal(_ command: String)", in: launcher))
        let brewGhostty = try XCTUnwrap(brew.range(of: "if Terminals.isGhostty(Terminals.handler()), let ghostty = Terminals.ghostty {"))
        let brewOpen = try XCTUnwrap(brew.range(of: "\n        NSWorkspace.shared.open(url)\n    }"))
        XCTAssertTrue(brewGhostty.lowerBound < brewOpen.lowerBound, "brew: Ghostty before opening the file")
        let engine = try HandsSourceTests.code("Sources/BaneySpaces/Session/Engine.swift")
        let run = try XCTUnwrap(HandsSourceTests.block(after: "func runInGhostty(", in: engine))
        XCTAssertTrue(run.contains("let r = s.run(\"runWindow\", [dir ?? \"\", command])") && run.contains("Self.neverReached.contains(r.error)"), "only an unsent request falls back")
        let scripts = try String(contentsOf: HandsSourceTests.root.appendingPathComponent("Sources/BaneySpaces/Session/Scripts.swift"), encoding: .utf8)
        let handler = try XCTUnwrap(HandsSourceTests.between("on runWindow(dir, cmd)", "end runWindow", in: scripts))
        XCTAssertTrue(handler.contains("set command of cfg to cmd") && handler.contains("set wait after command of cfg to true"), "run as the window's command, never typed into his shell")
        XCTAssertTrue(handler.contains("with timeout of 10 seconds"), "every tell carries a timeout")
        XCTAssertTrue(handler.range(of: "activate")!.lowerBound < handler.range(of: "new window with configuration cfg")!.lowerBound, "Ghostty in front before the window is made")
        XCTAssertTrue(handler.contains("is running) then return \"not running\""), "never launches Ghostty from the script")
        XCTAssertTrue(try HandsSourceTests.code("Sources/BaneySpaces/AppDelegate.swift").contains("self.session.engine.runInGhostty(in: dir, script: script, orElse: orElse)"))
    }

    func testTerminalIsTheLastResort() {
        let ghostty = "com.mitchellh.ghostty"
        XCTAssertEqual(TerminalChoice.pick(handler: "com.apple.Terminal", capable: [ghostty, "com.apple.Terminal"]), ghostty)
        XCTAssertEqual(TerminalChoice.pick(handler: "com.googlecode.iterm2", capable: [ghostty]), "com.googlecode.iterm2")
        XCTAssertEqual(TerminalChoice.pick(handler: nil, capable: ["com.googlecode.iterm2", ghostty]), ghostty)
        XCTAssertEqual(TerminalChoice.pick(handler: "com.apple.Terminal", capable: ["com.apple.Terminal"]), "com.apple.Terminal")
        // "Always Open With TextEdit" would show the script, not run it.
        XCTAssertEqual(TerminalChoice.pick(handler: "com.apple.TextEdit", capable: [ghostty, "com.apple.TextEdit"]), ghostty)
        XCTAssertEqual(TerminalChoice.pick(handler: "com.cmuxterm.app", capable: [ghostty, "com.cmuxterm.app"]), "com.cmuxterm.app")
    }
}
