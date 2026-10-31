import AppKit

/// Settings' and the menu's Uninstall: runs the same uninstall.sh as the README's curl command,
/// from the copy inside the app, so what's removed and put back is the same either way.
enum Uninstaller {
    static let command = "curl -fsSL https://raw.githubusercontent.com/baney75/baneyspaces/main/uninstall.sh | bash"

    static let summary = """
        BaneySpaces quits first, which brings every hidden window and app back. Then it puts back \
        the macOS Dock, Mission Control for a window dragged to the top (and fill-the-screen, if an older BaneySpaces turned it off; if BaneySpaces gave up turning it back on, this tries once more), the screenshot and Spotlight shortcuts and your Claude Code settings as \
        they were, and removes the app, its settings, its login item, its command and its \
        Accessibility permission. Your own hooks and settings stay.
        """

    static var log: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/BaneySpaces-uninstall.log")
    }

    /// Starts the script on its own, out of the app it's about to delete: a copy in a temporary
    /// folder, so removing the app can't pull it out from under bash. The caller quits next.
    static func start() throws {
        guard let script = Bundle.main.url(forResource: "uninstall", withExtension: "sh") else {
            throw NSError(domain: "BaneySpaces", code: 1, userInfo: [NSLocalizedDescriptionKey: "uninstall.sh is missing from the app."])
        }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("baneyspaces-uninstall-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent("uninstall.sh")
        try fm.copyItem(at: script, to: copy)
        try fm.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: log.path, contents: nil)
        let out = try FileHandle(forWritingTo: log)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        // When it's done, say so: the app that asked is gone by then.
        let say = "osascript -e 'on run argv' -e 'display dialog (item 1 of argv) buttons {\"OK\"} default button 1 with title \"BaneySpaces\"' -e 'end run' \"$m\""
        let run = """
            /bin/bash "$0"; s=$?
            case $s in
              0) m="BaneySpaces is removed. Your windows, Dock, shortcuts and agent settings are back as they were." ;;
              2) m="BaneySpaces is removed, but some settings need a hand. The list is at $1" ;;
              *) m="The uninstaller stopped before removing anything. Its log is at $1" ;;
            esac
            \(say) >/dev/null 2>&1
            exit $s
            """
        // Started in the background with nohup, so it's on its own the moment this bash exits:
        // nothing ties it to the app that's about to quit.
        p.arguments = ["-c", "nohup /bin/bash -c \"$2\" \"$0\" \"$1\" </dev/null >>\"$1\" 2>&1 &", copy.path, log.path, run]
        var env = ProcessInfo.processInfo.environment
        env["BANEYSPACES_APP"] = Bundle.main.bundleURL.path
        env.removeValue(forKey: "BANEYSPACES_UNINSTALL_TEST")
        p.environment = env
        p.standardOutput = out
        p.standardError = out
        try p.run()
        p.waitUntilExit()
    }
}
