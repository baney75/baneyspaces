import Foundation

/// A command that dies with BaneySpaces. `adb track-devices` only writes when a phone comes or goes,
/// so it never meets SIGPIPE after BaneySpaces quits, crashes or is replaced by an update, and
/// launchd keeps it forever. The wrapper is a /bin/sh that runs the real command, watches the
/// BaneySpaces pid it was started by, and kills the command once that pid is gone or the command ends
/// by itself. SIGTERM (from `Process.terminate()`) is passed on to the command too.
public enum ChildGuard {
    public static let shell = "/bin/sh"
    /// How often the wrapper looks at its parent, in seconds: the longest a child outlives a kill -9.
    public static let pollSeconds = 2

    // $PPID is the BaneySpaces pid (read once, at startup); `sleep & wait` lets a TERM act at once.
    static let script = """
    p=$PPID; "$@" & a=$!
    trap 'kill $a 2>/dev/null; exit 143' TERM INT HUP
    while kill -0 $p 2>/dev/null && kill -0 $a 2>/dev/null; do sleep \(pollSeconds) & wait $!; done
    kill $a 2>/dev/null; wait $a
    """

    /// The executable and arguments to hand to `Process` instead of `command` itself.
    public static func wrap(_ command: [String]) -> (executable: String, arguments: [String]) {
        (shell, ["-c", script, "baneyspaces-guard"] + command)
    }
}
