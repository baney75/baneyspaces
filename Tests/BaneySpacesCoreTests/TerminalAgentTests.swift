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
    func testTheTypedCommandIsTheQuotedPathAndRefusesWhatTheScriptRefuses() {
        XCTAssertEqual(TerminalAgent.all[0].typedCommand(at: "/Users/a b/.local/bin/codex"), "'/Users/a b/.local/bin/codex'")
        for bad in ["codex", "/x/'; rm -rf ~; '", "/x/$(evil)", "/x/a\nb"] { XCTAssertNil(TerminalAgent.all[0].typedCommand(at: bad), bad) }
    }

    func testGhosttyIsNeverHandedAScriptFileWhenItCanBeScripted() throws {
        let launcher = try HandsSourceTests.code("Sources/BaneySpaces/Launcher.swift")
        let open = try XCTUnwrap(HandsSourceTests.block(after: "static func open(_ agent: TerminalAgent, at path: String, in terminal: URL)", in: launcher))
        let ghostty = try XCTUnwrap(open.range(of: "if isGhostty(terminal), let ghostty, let typed = agent.typedCommand(at: path)"))
        XCTAssertTrue(ghostty.lowerBound < open.range(of: "openScript(agent, at: path, in: terminal)\n    }")!.lowerBound, "Ghostty first, the script only as the fallback")
        XCTAssertFalse(open.contains("NSWorkspace.shared.open("), "the script is opened only in openScript")
        let brew = try XCTUnwrap(HandsSourceTests.block(after: "private static func runInTerminal(_ command: String)", in: launcher))
        XCTAssertTrue(brew.contains("Terminals.isGhostty(Terminals.handler()), let ghostty = Terminals.ghostty"))
        let engine = try HandsSourceTests.code("Sources/BaneySpaces/Session/Engine.swift")
        let run = try XCTUnwrap(HandsSourceTests.block(after: "func runInGhostty(", in: engine))
        XCTAssertTrue(run.contains("s.call(\"newWindow\", [dir ?? \"\", command])") && run.contains("orElse()"))
        XCTAssertTrue(try HandsSourceTests.code("Sources/BaneySpaces/AppDelegate.swift").contains("self.session.engine.runInGhostty(in: dir, command: command, orElse: orElse)"))
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
