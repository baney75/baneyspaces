import AppKit
import BaneySpacesCore
import IOKit

/// macOS's Mission Control, kept off only while BaneySpaces is there to replace it. The settings
/// are saved first and put back when the switch goes off, when BaneySpaces quits or loses
/// Accessibility, and when it's uninstalled (`MissionControlTakeover` has the rules; `uninstall.sh`
/// reads the same record). Two things cover a BaneySpaces that stops without doing it: a quit for
/// an update leaves the settings for the new build, and a launch agent (`MissionControlWatchdog`)
/// puts them back if no BaneySpaces has run for a minute (30 seconds after an update's quit).
enum SystemMissionControl {
    private final class Prefs: PreferenceStore {
        func value(_ domain: String, _ key: String) -> NSNumber? {
            CFPreferencesAppSynchronize(domain as CFString)
            return CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? NSNumber
        }
        func set(_ domain: String, _ key: String, _ value: NSNumber?) {
            CFPreferencesSetAppValue(key as CFString, value, domain as CFString)
            CFPreferencesAppSynchronize(domain as CFString)
        }
    }

    /// The record lives in BaneySpaces' settings and, flushed to disk, in a file of its own that the
    /// launch agent reads too: if the app dies before its settings reach the disk, the file is
    /// still there (and is read back as the record on the next launch).
    private final class Record: SavedRecord {
        private var file: URL { Spaces.folder.appendingPathComponent(DurableRecord.fileName) }

        var saved: [String: NSNumber]? {
            get {
                (UserDefaults.standard.dictionary(forKey: MissionControlTakeover.recordKey) as? [String: NSNumber])
                    ?? DurableRecord.read(from: file)
            }
            set {
                if let newValue { UserDefaults.standard.set(newValue, forKey: MissionControlTakeover.recordKey) }
                else {
                    UserDefaults.standard.removeObject(forKey: MissionControlTakeover.recordKey)
                    DurableRecord.remove(file)
                }
            }
        }

        func flush() -> Bool {
            let record = UserDefaults.standard.dictionary(forKey: MissionControlTakeover.recordKey) as? [String: NSNumber]
            CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
            guard let record else { DurableRecord.remove(file); return true }
            return DurableRecord.write(record, to: file)
        }
    }

    private static var takeover: MissionControlTakeover { MissionControlTakeover(prefs: Prefs(), record: Record()) }

    static var isTakenByUs: Bool { takeover.isTakenByUs }

    /// Whether the Dock's switch is still on. Off while BaneySpaces holds Mission Control means the
    /// person (or a profile) turned it back on.
    static var isOffAtDock: Bool { takeover.isOffAtDock }

    /// Whether the launch agent is still loaded. Safe off the main thread.
    static var isArmed: Bool { installer.isArmed() }

    /// The hot corners that opened Mission Control, which BaneySpaces answers now.
    static func answeredCorners() -> [(corner: MissionControlTakeover.Corner, modifiers: Int)] { takeover.answeredCorners() }

    /// Why Mission Control couldn't be taken over, for Settings; nil while it is, or isn't wanted.
    private(set) static var problem: String?

    private static var installer: WatchdogInstaller {
        WatchdogInstaller(
            folder: Spaces.folder,
            agentPlist: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(MissionControlWatchdog.plistName)"),
            restoreSource: Bundle.main.url(forResource: "uninstall", withExtension: "sh"),
            uid: getuid(), launchctl: launchctl)
    }

    /// Switches Mission Control off, but only once the launch agent that puts it back is written,
    /// loaded and checked. The agent is set up off the main thread (it runs up to four launchctl
    /// calls); `completion` runs on the main thread with true when Mission Control is off, or false
    /// when it couldn't be armed, in which case it is left on (or given back) and `problem` says
    /// why. `stillWanted` is asked on the main thread once the agent is ready: if the switch went
    /// off meanwhile, nothing is changed.
    static func takeOver(stillWanted: @escaping () -> Bool, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let reason = installer.install(pid: getpid())
            DispatchQueue.main.async {
                guard stillWanted() else {
                    if !takeover.isTakenByUs { installer.remove() }
                    return completion(false)
                }
                switch MissionControlSetup.takeOver(takeover, arm: { reason }) {
                case .taken(let changed):
                    problem = nil
                    if changed {
                        Trace.log("mission control: off at the Dock (corners answered: \(answeredCorners().map(\.corner.rawValue)))")
                        restartDock()
                    }
                    completion(true)
                case .notArmed(let reason, let restored):
                    if problem != reason { Trace.log("mission control: left on, \(reason)") }
                    problem = reason
                    if restored { restartDock() }
                    completion(false)
                }
            }
        }
    }

    /// Gives Mission Control back. `keeping` is a reason it wasn't taken, which Settings goes on showing.
    /// The launch agent stays installed unless `removeAgent`, which is for the Settings switch being
    /// turned off (the uninstaller removes it itself): on a quit it finds no heartbeat and does nothing.
    /// Returns whether any saved setting changed (false: nothing to undo, or already as saved).
    @discardableResult
    static func restore(keeping why: String? = nil, removeAgent: Bool = false) -> Bool {
        problem = why
        let changed = takeover.restore()
        if removeAgent { installer.remove() } else { installer.stopHolding() }
        if changed {
            Trace.log("mission control: back as it was")
            restartDock()
        }
        return changed
    }

    /// Quitting for an update: the new build takes over where this one left off, so nothing is
    /// restored. A marker tells the launch agent to give it 30 seconds, not 60, to start.
    static func leaveForUpdate() {
        installer.leaveForUpdate(pid: getpid())
        Trace.log("mission control: left to the update")
    }

    /// Proof that BaneySpaces is alive, for the launch agent.
    static func beat() { try? installer.beatNow(pid: getpid()) }

    /// Whether launchctl exited 0. A launchd that doesn't answer in three seconds counts as no, so
    /// it can't hold the app up.
    @discardableResult
    private static func launchctl(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return false }
        if done.wait(timeout: .now() + 3) == .timedOut {
            p.terminate()
            return false
        }
        return p.terminationStatus == 0
    }

    /// The Dock reads these settings when it starts; restarting it is how System Settings applies them.
    private static func restartDock() {
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = ["Dock"]
        try? kill.run()
    }
}

/// Hot corners that used to open Mission Control, now opening the overview. macOS's own are
/// remapped to nothing (`SystemMissionControl`); this watches the pointer for them. It never
/// moves or clicks the pointer, and a mouse-moved watch needs no permission. The pointer over
/// BaneySpaces' own windows (the dock, the overview, Settings) is seen by the local watch.
final class HotCornerWatcher {
    var onOpen: () -> Void = {}
    private var corners: [(corner: MissionControlTakeover.Corner, modifiers: Int)] = []
    private var dwell = HotCornerDwell()
    private var monitors: [Any] = []
    private var timer: Timer?

    var isRunning: Bool { !monitors.isEmpty }

    /// The corners to answer. The watch starts, stops or is left alone, whichever the list needs.
    func set(corners new: [(corner: MissionControlTakeover.Corner, modifiers: Int)]) {
        let same = new.count == corners.count && zip(new, corners).allSatisfy { $0.corner == $1.corner && $0.modifiers == $1.modifiers }
        if same && isRunning == !new.isEmpty { return }
        stop()
        corners = new
        guard !new.isEmpty else { return }
        // Moving into a corner, and pressing the key a corner wants while the pointer rests in it.
        let kinds: NSEvent.EventTypeMask = [.mouseMoved, .flagsChanged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: { [weak self] _ in self?.evaluate() }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: kinds, handler: { [weak self] e in self?.evaluate(); return e }) { monitors.append(l) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        timer?.invalidate()
        timer = nil
        corners = []
        dwell = HotCornerDwell()
        last = nil
    }

    private var last: MissionControlTakeover.Corner?

    private func evaluate() {
        var corner = HotCorners.corner(at: NSEvent.mouseLocation, screens: NSScreen.screens.map(\.frame))
        // A corner macOS answered with a key held waits for that key; a drag in progress isn't a visit.
        if let c = corner {
            let wanted = corners.first { $0.corner == c }
            let held = Int(NSEvent.modifierFlags.rawValue)
            let answered = wanted.map { HotCorners.modifiersHeld(required: $0.modifiers, held: held) } ?? false
            if !answered || NSEvent.pressedMouseButtons != 0 { corner = nil }
        }
        let now = ProcessInfo.processInfo.systemUptime
        // A new visit starts a new wait; the one for the last visit is of no use.
        if corner != last { timer?.invalidate(); timer = nil; last = corner }
        if dwell.update(corner, now: now) {
            Trace.log("hot corner \(corner?.rawValue ?? "?"): overview")
            onOpen()
        } else if let left = dwell.remaining(now: now), timer == nil {
            // The pointer rests, so no more events come: look again when the dwell is up.
            timer = Timer.scheduledTimer(withTimeInterval: left + 0.02, repeats: false) { [weak self] _ in
                self?.timer = nil
                self?.evaluate()
            }
        }
    }
}
