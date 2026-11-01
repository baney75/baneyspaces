import BaneySpacesCore
import Foundation

/// Hooks that report each agent session's state to BaneySpaces: Claude Code's go in
/// ~/.claude/settings.json beside your own, Grok's in a file of their own in ~/.grok/hooks.
/// They run async, so the agent never waits on them, and `baneyspaces hook` exits 0 whatever happens.
enum Hooks {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static var claudeURL: URL { home.appendingPathComponent(".claude/settings.json") }
    static var grokURL: URL { home.appendingPathComponent(".grok/hooks/baneyspaces.json") }
    static var grokInstalled: Bool { FileManager.default.fileExists(atPath: home.appendingPathComponent(".grok").path) }

    /// The installed command, via the stable symlink so app updates don't break the path.
    static func command(_ agent: String) -> String {
        let link = home.appendingPathComponent(".local/bin/baneyspaces").path
        // Always an absolute path: a relative one would fail silently behind `|| true`.
        let path = FileManager.default.isExecutableFile(atPath: link) ? link
            : (Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? link)
        return "'\(path.replacingOccurrences(of: "'", with: "'\\''"))' hook \(agent) 2>/dev/null || true"
    }

    static func load(_ url: URL) -> [String: Any]? {
        guard let d = FileManager.default.contents(atPath: url.path) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    static func save(_ obj: [String: Any], to url: URL, backup: Bool) throws {
        let fm = FileManager.default
        // The first backup is the settings from before BaneySpaces touched them; later runs keep it.
        let b = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".baneyspaces-backup")
        if backup, fm.fileExists(atPath: url.path), !fm.fileExists(atPath: b.path) {
            try fm.copyItem(at: url.resolvingSymlinksInPath(), to: b)
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        // Through a symlink (settings kept in a dotfiles repo) to the file it points at, keeping
        // that file's permissions: an atomic write would replace the link with a new file.
        let target = url.resolvingSymlinksInPath()
        let mode = (try? fm.attributesOfItem(atPath: target.path)[.posixPermissions]) as? NSNumber
        try data.write(to: target, options: .atomic)
        try fm.setAttributes([.posixPermissions: mode ?? NSNumber(value: 0o600)], ofItemAtPath: target.path)
    }

    static func install() -> String {
        var lines: [String] = []
        if let settings = load(claudeURL) {
            do {
                try save(HookSettings.adding(settings, command: command("claude")), to: claudeURL, backup: true)
                lines.append("Claude Code: \(HookSettings.events.count) hooks in ~/.claude/settings.json (backup beside it)")
            } catch { lines.append("Claude Code: couldn't write settings: \(error.localizedDescription)") }
        } else {
            lines.append("Claude Code: ~/.claude/settings.json isn't valid JSON; left it alone")
        }
        if grokInstalled {
            do {
                try save(HookSettings.adding([:], command: command("grok")), to: grokURL, backup: false)
                lines.append("Grok: ~/.grok/hooks/baneyspaces.json")
            } catch { lines.append("Grok: couldn't write hooks: \(error.localizedDescription)") }
        }
        return lines.joined(separator: "\n") + "\nNew sessions report to BaneySpaces."
    }

    static func uninstall() -> String {
        var lines: [String] = []
        if let settings = load(claudeURL) {
            do {
                // No backup: the one worth keeping is from before BaneySpaces, made when it installed.
                try save(HookSettings.removing(settings), to: claudeURL, backup: false)
                lines.append("removed BaneySpaces' hooks from ~/.claude/settings.json")
            } catch { lines.append("couldn't write settings: \(error.localizedDescription)") }
        }
        if FileManager.default.fileExists(atPath: grokURL.path) {
            try? FileManager.default.removeItem(at: grokURL)
            lines.append("removed ~/.grok/hooks/baneyspaces.json")
        }
        return lines.joined(separator: "\n")
    }

    static func status() -> String {
        var parts: [String] = []
        let claude = load(claudeURL).map(HookSettings.installed) ?? []
        parts.append(claude.count == HookSettings.events.count ? "Claude Code on" : claude.isEmpty ? "Claude Code off" : "Claude Code partly on")
        if grokInstalled {
            let grok = load(grokURL).map(HookSettings.installed) ?? []
            parts.append(grok.count == HookSettings.events.count ? "Grok on" : "Grok off")
        }
        let all = !parts.contains { $0.hasSuffix("off") || $0.hasSuffix("partly on") }
        return parts.joined(separator: ", ") + (all ? "" : " (baneyspaces hooks install)")
    }
}

/// The agent skill: tells Claude Code, Grok or any agent that reads skills how to use BaneySpaces.
enum Skill {
    static var dest: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills/baneyspaces/SKILL.md")
    }

    /// The copy in the app bundle, next to this binary (Contents/Resources/bin/baneyspaces).
    static var source: URL? {
        // The real binary, not argv[0]: run from PATH, argv[0] is just "baneyspaces".
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let c = exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("skill/SKILL.md")
        return FileManager.default.fileExists(atPath: c.path) ? c : nil
    }

    static func install() -> String {
        guard let src = source, let data = FileManager.default.contents(atPath: src.path) else {
            return "couldn't find SKILL.md beside the binary; install BaneySpaces with make install"
        }
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: dest, options: .atomic)
        } catch { return "couldn't write \(dest.path): \(error.localizedDescription)" }
        return "installed \(dest.path)"
    }
}
