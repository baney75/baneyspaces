import Foundation

/// A coding agent that runs in a terminal, offered by the launcher when its name is typed:
/// "claude" opens Claude Code in your terminal, "codex" opens Codex. Only agents found on this
/// Mac are offered.
public struct TerminalAgent: Equatable, Sendable {
    public let name: String
    /// The program to run. Fixed here, never typed, so nothing from the search reaches a shell.
    public let command: String

    public static let all = [TerminalAgent(name: "Claude Code", command: "claude"), TerminalAgent(name: "Codex", command: "codex")]

    /// Where the installers put them, for a check that doesn't need a shell.
    public static let folders = ["~/.local/bin", "~/.claude/local", "/opt/homebrew/bin", "/usr/local/bin",
                                 "~/.npm-global/bin", "~/.bun/bin", "~/.volta/bin"]

    /// The installed agents that answer `query`: by the start of a word in the name or the
    /// command ("cl", "code", "codex"), not by letters scattered through it.
    public static func matches(_ query: String, installed: some Collection<String>) -> [TerminalAgent] {
        all.filter { installed.contains($0.command) }
            .compactMap { a -> (TerminalAgent, Int)? in
                let s = max(Fuzzy.score(query, a.name) ?? -1, Fuzzy.score(query, a.command) ?? -1)
                return s >= 600 ? (a, s) : nil
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// A script that starts the agent, found at `path`, in your home folder through a login
    /// shell, so it gets the PATH your terminal has, and leaves a shell open when it quits. Not an
    /// interactive shell: a .zshrc that ends in `exec tmux` would take it over before the agent
    /// ran. Nil for a path with anything a shell would read as more than a name.
    public func script(at path: String) -> String? {
        guard path.hasPrefix("/"), path.allSatisfy({ $0.isLetter || $0.isNumber || "/._-+@ ".contains($0) }) else { return nil }
        return """
        #!/bin/zsh
        cd ~
        exec /bin/zsh -l -c "'\(path)'; exec \\"\\${SHELL:-/bin/zsh}\\" -l"

        """
    }
}

/// Which terminal the launcher opens agents in. macOS has no default-terminal setting; the app
/// that opens .command files is the nearest thing, and it stays Terminal unless changed. So
/// Terminal counts only when nothing better is installed.
public enum TerminalChoice {
    public static let terminal = "com.apple.Terminal"
    /// Terminals, best first. One is picked only when it says it opens .command files.
    public static let preferred = ["com.mitchellh.ghostty", "com.googlecode.iterm2", "com.github.wez.wezterm", "dev.warp.Warp-Stable"]
    /// Terminals used when they're what opens .command files, though not picked otherwise.
    public static let known = Set(preferred + ["com.cmuxterm.app"])

    /// `handler` opens .command files now; `capable` can open them. A handler that isn't a
    /// terminal (TextEdit, after "Always Open With") would show the script instead of running it.
    public static func pick(handler: String?, capable: Set<String>) -> String {
        if let handler, known.contains(handler) { return handler }
        return preferred.first(where: capable.contains) ?? terminal
    }
}
