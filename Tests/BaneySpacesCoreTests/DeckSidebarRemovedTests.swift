import XCTest

/// Donovan removed the Deck sidebar (2026-10-30): the launcher is the one search, and ⌃⌘K opens it.
/// The app target can't be imported by tests, so this reads the source.
final class DeckSidebarRemovedTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Code only: a comment that mentions a name must not count as using it.
    private func code(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map { $0.components(separatedBy: "//")[0] }.joined(separator: "\n")
    }

    func testNoSidebarPaletteOrEdgeStripIsDeclared() throws {
        let sources = root.appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "found no sources to check")
        for file in files {
            let text = try code(file)
            // Spelled in two halves so this file doesn't name them itself.
            for name in ["Sidebar" + "Panel", "Edge" + "Trigger", "Palette" + "Panel"] {
                XCTAssertFalse(text.contains("class \(name)") || text.contains("struct \(name)") || text.contains("enum \(name)"),
                               "\(file.lastPathComponent) declares \(name), which was removed")
            }
        }
    }

    func testControlCommandKOpensTheLauncher() throws {
        let text = try code(root.appendingPathComponent("Sources/BaneySpaces/AppDelegate.swift"))
        XCTAssertTrue(text.contains("deck.onSearch = { [weak self] in self?.launcher.toggle() }"),
                      "the Deck's onSearch must open the launcher")
        XCTAssertTrue(text.contains("kVK_ANSI_K, modifiers: controlKey | cmdKey") && text.contains("self?.deck.onSearch()"),
                      "⌃⌘K must be a global shortcut that calls the Deck's onSearch")
    }

    func testNewClaudeAndNewTerminalAreLauncherCommands() throws {
        let launcher = try code(root.appendingPathComponent("Sources/BaneySpaces/Launcher.swift"))
        XCTAssertTrue(launcher.contains("\"New Claude Session\"") && launcher.contains("\"New Terminal\""))
        let app = try code(root.appendingPathComponent("Sources/BaneySpaces/AppDelegate.swift"))
        XCTAssertTrue(app.contains("a.newClaude = { [weak self] in self?.deck.newClaude() }"))
        XCTAssertTrue(app.contains("a.newTerminal = { [weak self] in self?.deck.engine.newTerminal(in: nil) }"))
    }
}
