import Foundation

/// Adds and removes BaneySpaces' deck entries in a Claude Code settings object, leaving every other
/// hook exactly as it was. Pure, so it's tested against real settings shapes.
public enum HookSettings {
    public static let events = ["SessionStart", "UserPromptSubmit", "PostToolUse", "Notification", "Stop", "SessionEnd"]

    /// Ours whatever the path looks like: `'/Users/me/.local/bin/baneyspaces' hook claude 2>/dev/null || true`.
    /// Ghostdeck's hooks count too, so installing replaces them instead of doubling up.
    public static func isOurs(command: String) -> Bool {
        command.range(of: #"(ghostdeck|baneyspaces)'?"?\s+hook\s+(claude|grok)"#, options: .regularExpression) != nil
    }

    static func isOurs(_ hook: [String: Any]) -> Bool { isOurs(command: (hook["command"] as? String) ?? "") }

    /// Whether `json` (a settings file's text) has our hook anywhere. For a quick check without parsing.
    public static func mentioned(in json: String) -> Bool { isOurs(command: json) }

    public static func removing(_ settings: [String: Any]) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept = groups.compactMap { g -> [String: Any]? in
                guard let inner = g["hooks"] as? [[String: Any]] else { return g }
                let rest = inner.filter { !isOurs($0) }
                if rest.isEmpty && !inner.isEmpty { return nil }
                var g = g
                g["hooks"] = rest
                return g
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        return settings
    }

    /// Ours, once per event, appended after the user's own. Installing twice changes nothing.
    public static func adding(_ settings: [String: Any], command: String) -> [String: Any] {
        var settings = removing(settings)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for e in events {
            var groups = hooks[e] as? [[String: Any]] ?? []
            groups.append(["hooks": [["type": "command", "command": command, "timeout": 2, "async": true] as [String: Any]]])
            hooks[e] = groups
        }
        settings["hooks"] = hooks
        return settings
    }

    /// The events Ghostdeck's hook is installed for.
    public static func installed(_ settings: [String: Any]) -> [String] {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        return events.filter { e in
            ((hooks[e] as? [[String: Any]]) ?? []).contains { g in ((g["hooks"] as? [[String: Any]]) ?? []).contains(where: isOurs) }
        }
    }
}
