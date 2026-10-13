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
