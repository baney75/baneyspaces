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
    /// The heartbeat's second line. A build that doesn't write it doesn't replace Mission Control.
    public static let capability = "mission-control=1"
    public static let updating = "mc-updating"
    public static let scriptName = "mc-watchdog.sh"
    public static let restoreName = "mc-restore.sh"

    public static var plistName: String { label + ".plist" }

    /// The script the agent runs. Everything it needs is in the Application Support folder.
    /// BaneySpaces writes its process id into the heartbeat; that process, whatever its bundle is
    /// called ("BaneySpaces 2.app"), is what counts as running.
    public static var script: String {
        """
        #!/bin/bash
        # BaneySpaces: puts macOS's Mission Control back if BaneySpaces has stopped running without doing it.
        D="$HOME/Library/Application Support/BaneySpaces"
        [ -f "$D/\(heartbeat)" ] || exit 0
        # The record is in BaneySpaces' settings, or in a file of its own if a crash kept it from them.
        { defaults read com.baney.baneyspaces systemMissionControlSaved >/dev/null 2>&1 || [ -f "$D/\(DurableRecord.fileName)" ]; } || exit 0
        beat=$(stat -f %m "$D/\(heartbeat)" 2>/dev/null) || exit 0
        limit=\(limit)
        [ -f "$D/\(updating)" ] && limit=\(updateLimit)
        [ $(( $(date +%s) - beat )) -gt "$limit" ] || exit 0
        # Running means the process that wrote the heartbeat, and a build that knows this takeover.
        # Any other BaneySpaces (an older build started since) doesn't answer the swipe or the
        # corners and doesn't give Mission Control back, so it doesn't count.
        pid=$(head -n 1 "$D/\(heartbeat)" 2>/dev/null)
        if grep -qx '\(capability)' "$D/\(heartbeat)" 2>/dev/null && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null \
          && ps -p "$pid" -o comm= 2>/dev/null | grep -q BaneySpaces; then exit 0; fi
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

/// Sets up and takes down the launch agent and its files. Taking Mission Control away depends on
/// this working, so `install()` says why when it didn't.
public struct WatchdogInstaller {
    public var folder: URL
    public var agentPlist: URL
    /// The uninstall.sh to copy as the restore script; nil when the app has none.
    public var restoreSource: URL?
    public var uid: UInt32
    /// Runs launchctl; whether it exited 0.
    public var launchctl: ([String]) -> Bool

    public init(folder: URL, agentPlist: URL, restoreSource: URL?, uid: UInt32, launchctl: @escaping ([String]) -> Bool) {
        self.folder = folder
        self.agentPlist = agentPlist
        self.restoreSource = restoreSource
        self.uid = uid
        self.launchctl = launchctl
    }

    private var target: String { "gui/\(uid)/\(MissionControlWatchdog.label)" }
    private func file(_ name: String) -> URL { folder.appendingPathComponent(name) }

    /// Writes the files, loads the agent and checks it is loaded. nil when Mission Control can
    /// safely be switched off; otherwise the reason, in words for Settings.
    public func install(pid: Int32) -> String? {
        let fm = FileManager.default
        guard let source = restoreSource, fm.fileExists(atPath: source.path) else {
            return "BaneySpaces' uninstaller is missing from the app, and it is what puts Mission Control back if BaneySpaces stops."
        }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try? fm.removeItem(at: file(MissionControlWatchdog.updating))
            try beatNow(pid: pid)
            try? fm.removeItem(at: file(MissionControlWatchdog.restoreName))
            try fm.copyItem(at: source, to: file(MissionControlWatchdog.restoreName))
            try MissionControlWatchdog.script.write(to: file(MissionControlWatchdog.scriptName), atomically: true, encoding: .utf8)
            let escaped = folder.path.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            let plist = MissionControlWatchdog.plist(folder: escaped)
            let old = try? String(contentsOf: agentPlist, encoding: .utf8)
            try fm.createDirectory(at: agentPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
            try plist.write(to: agentPlist, atomically: true, encoding: .utf8)
            // A changed agent is loaded again.
            if old != plist { _ = launchctl(["bootout", target]) }
        } catch {
            return "BaneySpaces couldn't write the files that put Mission Control back if it stops (\(error.localizedDescription))."
        }
        if !launchctl(["print", target]) { _ = launchctl(["bootstrap", "gui/\(uid)", agentPlist.path]) }
        guard launchctl(["print", target]) else {
            return "macOS wouldn't load the launch agent that puts Mission Control back if BaneySpaces stops. Check System Settings › General › Login Items & Extensions for BaneySpaces."
        }
        return nil
    }

    /// The agent's files and the agent itself. The agent can be what runs this (a restore ends
    /// by calling it), and unloading it ends the job, so the unloading is last.
    public func remove() {
        let fm = FileManager.default
        try? fm.removeItem(at: agentPlist)
        for name in [MissionControlWatchdog.heartbeat, MissionControlWatchdog.updating] { try? fm.removeItem(at: file(name)) }
        _ = launchctl(["bootout", target])
    }

    /// Proof that BaneySpaces, this process, is alive, and that it is a build that holds Mission Control off.
    public func beatNow(pid: Int32) throws {
        try Data("\(pid)\n\(MissionControlWatchdog.capability)\n".utf8).write(to: file(MissionControlWatchdog.heartbeat))
    }

    /// Whether the agent is still there: its plist and script are in place and launchd has it
    /// loaded. The person can switch it off from the Background Item notice or Login Items.
    public func isArmed() -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: agentPlist.path) && fm.fileExists(atPath: file(MissionControlWatchdog.restoreName).path)
            && fm.fileExists(atPath: file(MissionControlWatchdog.scriptName).path) && launchctl(["print", target])
    }

    /// Quitting for an update: the new build gets 30 seconds to start.
    public func leaveForUpdate(pid: Int32) {
        FileManager.default.createFile(atPath: file(MissionControlWatchdog.updating).path, contents: Data())
        try? beatNow(pid: pid)
    }
}

/// Taking Mission Control off only once the way back is in place.
public enum MissionControlSetup {
    public enum Result: Equatable {
        /// Off at the Dock; `changed` when a setting was written (the Dock must restart).
        case taken(changed: Bool)
        /// Left on, or given back, because the safety net couldn't be set up.
        case notArmed(reason: String, restored: Bool)
    }

    /// `arm` sets up and checks the launch agent (nil when it works, else why not). Nothing is
    /// changed until it has; if it fails while Mission Control is already off, it is put back.
    public static func takeOver(_ takeover: MissionControlTakeover, arm: () -> String?) -> Result {
        if let reason = arm() { return .notArmed(reason: reason, restored: takeover.restore()) }
        switch takeover.takeOverDurably() {
        case .done(let changed):
            return .taken(changed: changed)
        case .recordNotSaved:
            return .notArmed(reason: "BaneySpaces couldn't save what Mission Control was set to, and it needs that to put it back.", restored: false)
        }
    }
}
