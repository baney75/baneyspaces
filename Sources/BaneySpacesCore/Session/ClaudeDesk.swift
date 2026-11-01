import Foundation

/// The Claude tab that `claude-desk` (⌘⇧A) tiles sessions into, and the terminals it made there:
/// the tab's ID on the first line, then one terminal ID per line, in creation order, in
/// `~/.local/state/claude-desk/tiles`. The session engine's sparkle button reads and writes the same file, so
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

    /// The state after `claudeTile` timed out, from `frontTab`'s answer: a tab's ID, then its
    /// terminals' IDs. `frontTab` follows the branch `claudeTile` took, so the tab it names is
    /// the state's own tab after a split, or the new tab or window after a new one.
    ///
    /// The state's own tab: exactly one terminal the state doesn't know is the pane that opened late
    /// and is appended. None: the state minus terminals that closed. More than one: don't guess which
    /// is ours, keep the state. Any other tab (a new tab, a new window): `claudeTile` leaves one
    /// terminal in it, so one terminal starts the state over from it and any other count writes
    /// nothing. A pane another app split into the state's tab during the wait looks like ours; that
    /// can't be told apart. An empty answer (no window) writes nothing.
    public static func recovered(prior: [String], front: [String]) -> [String] {
        guard let tab = front.first else { return [] }
        let terminals = Array(front.dropFirst())
        guard prior.first == tab else { return terminals.count == 1 ? [tab] + terminals : [] }
        let known = prior.dropFirst().filter { terminals.contains($0) }
        let unknown = terminals.filter { !prior.contains($0) }
        switch unknown.count {
        case 0: return [tab] + known
        case 1: return [tab] + known + unknown
        default: return prior
        }
    }

    /// Whether a pane may still land, or already has, after `claudeTile` timed out. `progress` is
    /// `tileProgress`'s answer: this press's token, then the last step the script reached. A timeout
    /// stops the script at the Apple event that timed out and sends nothing after it. "creating"
    /// means that event opens the pane; "done" means the pane opened and a later read timed out, so
    /// it's there but not in the state. Any step before them, or another press's token, means
    /// nothing opened and nothing is owed to the state.
    public static func paneMayLand(progress: String, token: String) -> Bool {
        let lines = parse(progress)
        return lines.count == 2 && lines[0] == token && (lines[1] == "creating" || lines[1] == "done")
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

/// Whether a New Claude press is let through. After `claudeTile` times out with a pane that may
/// still land, Ghostty is still busy with it; a second press then could open a second pane, and
/// recovery could adopt the wrong one. Presses wait until `frontTab` has answered (which Ghostty
/// does only after the pane exists) or `limit` seconds have passed, whichever is first.
public struct TileGate: Equatable, Sendable {
    public static let limit: TimeInterval = 35
    private var since: TimeInterval?

    public init() {}

    /// A tile timed out at `now` with a pane that may still land.
    public mutating func timedOut(at now: TimeInterval) { since = now }
    /// `frontTab` answered: the pane is there, or nothing was coming.
    public mutating func settled() { since = nil }
    public func blocks(now: TimeInterval) -> Bool {
        guard let since else { return false }
        return now - since < Self.limit
    }
}
