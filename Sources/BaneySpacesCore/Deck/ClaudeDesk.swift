import Foundation

/// The Claude tab that `claude-desk` (⌘⇧A) tiles sessions into, and the terminals it made there:
/// the tab's ID on the first line, then one terminal ID per line, in creation order, in
/// `~/.local/state/claude-desk/tiles`. The Deck's sparkle button reads and writes the same file, so
/// either one adds the next tile to the same grid.
public enum ClaudeDesk {
    public static var stateFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/claude-desk/tiles")
    }
    /// Where a new session starts, as `claude-desk` has it.
    public static var workDir: String { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects").path }
    /// Claude in an interactive login shell, which loads the PATH and keys `.zshrc` exports for its
    /// tools; when Claude exits, the pane drops to a shell instead of closing.
    public static let paneCommand = "/bin/zsh -lic 'claude; exec /bin/zsh -l'"

    /// The file's lines, blanks dropped.
    public static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public static func read() -> [String] {
        (try? String(contentsOf: stateFile, encoding: .utf8)).map(parse) ?? []
    }

    /// Saves what the tiling script returned; nothing when it returned nothing.
    public static func write(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        try? FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: stateFile, atomically: true, encoding: .utf8)
    }
}
