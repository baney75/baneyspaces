import Foundation

/// A command that dies with BaneySpaces. `adb track-devices` only writes when a phone comes or goes,
/// so it never meets SIGPIPE after BaneySpaces quits, crashes or is replaced by an update, and
/// launchd keeps it forever. The wrapper is a /bin/sh that runs the real command and reads its own
/// stdin, which the caller must set to a `Pipe` whose write end it keeps open: the kernel closes that
/// end when the caller dies, even on kill -9, the read gets EOF and the wrapper kills the command.
/// The wrapper ends when the command does. SIGTERM (from `Process.terminate()`) reaches the command too.
public enum ChildGuard {
    public static let shell = "/bin/sh"

    // The trap comes first, so a signal during startup finds nothing to kill rather than a stray command.
    // The command gets /dev/null, so only the wrapper holds the pipe; the reader subshell is stopped
    // when the command ends.
    static let script = """
    trap 'kill $a $r 2>/dev/null; exit 143' TERM INT HUP
    "$@" </dev/null & a=$!
    exec 3<&0
    ( read _ <&3; kill $a 2>/dev/null ) & r=$!
    wait $a; s=$?
    kill $r 2>/dev/null
    exit $s
    """

    /// The executable and arguments to hand to `Process` instead of `command` itself. Set the process's
    /// `standardInput` to a `Pipe` and keep it for as long as the command should live.
    public static func wrap(_ command: [String]) -> (executable: String, arguments: [String]) {
        (shell, ["-c", script, "baneyspaces-guard"] + command)
    }
}
