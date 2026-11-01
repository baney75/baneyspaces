import Foundation

/// What puts macOS's Mission Control back when BaneySpaces isn't there to replace it: it crashed,
/// was force-quit, was dragged to the Trash without the uninstaller, or an update never started.
///
/// A launch agent runs `script` every `interval` seconds. While BaneySpaces holds Mission Control
/// off it touches a heartbeat file; when that file is older than `limit` seconds and no
/// BaneySpaces is running, the agent restores the saved values with a copy of `uninstall.sh`
/// (`--restore-mission-control`), which needs nothing from the app. A quit restores at once; a
/// quit for an update leaves a marker, and the new build has `updateLimit` seconds to start.
public enum MissionControlWatchdog {
    public static let label = "com.baney.baneyspaces.mc-watchdog"
    public static let interval = 15
    public static let limit = 60
    public static let updateLimit = 30

    /// Names inside BaneySpaces' Application Support folder.
    public static let heartbeat = "mc-heartbeat"
    public static let updating = "mc-updating"
    public static let scriptName = "mc-watchdog.sh"
    public static let restoreName = "mc-restore.sh"

    public static var plistName: String { label + ".plist" }

    /// The script the agent runs. Everything it needs is in the Application Support folder.
    public static var script: String {
        """
        #!/bin/bash
        # BaneySpaces: puts macOS's Mission Control back if BaneySpaces has stopped running without doing it.
        D="$HOME/Library/Application Support/BaneySpaces"
        [ -f "$D/\(heartbeat)" ] || exit 0
        defaults read com.baney.baneyspaces systemMissionControlSaved >/dev/null 2>&1 || exit 0
        beat=$(stat -f %m "$D/\(heartbeat)" 2>/dev/null) || exit 0
        limit=\(limit)
        [ -f "$D/\(updating)" ] && limit=\(updateLimit)
        [ $(( $(date +%s) - beat )) -gt "$limit" ] || exit 0
        pgrep -f "BaneySpaces.app/Contents/MacOS/BaneySpaces" >/dev/null && exit 0
        [ -f "$D/\(restoreName)" ] || exit 0
        exec /bin/bash "$D/\(restoreName)" --restore-mission-control
        """ + "\n"
    }

    /// The launch agent's property list.
    public static func plist(folder: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array><string>/bin/bash</string><string>\(folder)/\(scriptName)</string></array>
            <key>StartInterval</key><integer>\(interval)</integer>
            <key>ProcessType</key><string>Background</string>
        </dict>
        </plist>

        """
    }
}
