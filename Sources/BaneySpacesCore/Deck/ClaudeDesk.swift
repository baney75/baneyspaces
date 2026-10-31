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

    /// AppleScript's error when a `with timeout` block runs out. Ghostty may still finish the work.
    public static let timedOut = -1712

    /// The state after `claudeTile` timed out, from Ghostty's front tab: its ID, then its terminals'
    /// IDs (`front`). In the tab the state already names, the terminals it had stay first, in order
    /// (the script picks split bases by position), and any it didn't know follow, which is the
    /// pane that opened late. Any other tab starts the state over from what's in it. An empty
    /// answer (no window) writes nothing, so the state stays as it was.
    public static func recovered(prior: [String], front: [String]) -> [String] {
        guard let tab = front.first else { return [] }
        let terminals = Array(front.dropFirst())
        guard prior.first == tab else { return [tab] + terminals }
        let known = prior.dropFirst().filter { terminals.contains($0) }
        return [tab] + known + terminals.filter { !known.contains($0) }
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
