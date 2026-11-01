import Foundation

/// A place macOS keeps preferences, as far as this file needs: a number per domain and key, absent
/// when unset. The app reads and writes the real ones (`CFPreferences`); the tests use a fake.
public protocol PreferenceStore: AnyObject {
    func value(_ domain: String, _ key: String) -> NSNumber?
    /// nil removes the key.
    func set(_ domain: String, _ key: String, _ value: NSNumber?)
}

/// Where BaneySpaces keeps what it saved before changing macOS, as its own setting. nil is no record.
public protocol SavedRecord: AnyObject {
    var saved: [String: NSNumber]? { get set }
    /// Makes what `saved` holds durable: on disk, where the launch agent can read it after a
    /// crash. False when it couldn't be.
    func flush() -> Bool
}

public extension SavedRecord {
    func flush() -> Bool { true }
}

/// The record as a file of its own, which the launch agent and `uninstall.sh` read when the app's
/// settings don't have it (a crash before they reached the disk). Written to a temporary file,
/// flushed, then renamed over the old one, so it is whole or not there.
public enum DurableRecord {
    public static let fileName = "mc-record.plist"

    public static func write(_ record: [String: NSNumber], to url: URL) -> Bool {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: record, format: .xml, options: 0) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.appendingPathExtension("tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { return false }
        let wrote = data.withUnsafeBytes { raw -> Bool in
            var done = 0
            while done < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + done, raw.count - done)
                if n <= 0 { return false }
                done += n
            }
            return true
        }
        // F_FULLFSYNC asks the drive to flush too; plain fsync where that isn't supported.
        let flushed = wrote && (fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0)
        close(fd)
        guard flushed, rename(temp.path, url.path) == 0 else { unlink(temp.path); return false }
        let dir = open(url.deletingLastPathComponent().path, O_RDONLY)
        if dir >= 0 { _ = fsync(dir); close(dir) }
        return true
    }

    public static func read(from url: URL) -> [String: NSNumber]? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: NSNumber] else { return nil }
        return plist
    }

    public static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("tmp"))
    }
}

/// Switches macOS's Mission Control off, so BaneySpaces' overview is the only one: the Dock's own
/// switch (`mcx-expose-disabled`, which also keeps Mission Control and App Exposé from the
/// trackpad and the keys) and any hot corner set to Mission Control, which BaneySpaces answers
/// itself (`HotCorners`).
///
/// What was there is saved first, as a record that survives a crash, and goes back exactly: a
/// setting that wasn't there is saved as absent and removed again; one the person changed since
/// BaneySpaces wrote it is their newer choice and stays. The same record is what `uninstall.sh`
/// reads when the app is gone, so the key names below are part of that contract.
public struct MissionControlTakeover {
    public static let domain = "com.apple.dock"
    /// The Dock's switch for Mission Control.
    public static let flag = "mcx-expose-disabled"
    /// The Dock's hot corners and what each does: 2 is Mission Control, 1 does nothing.
    public static let missionControl = 2
    public static let nothing = 1

    public enum Corner: String, CaseIterable, Sendable {
        case topLeft = "tl", topRight = "tr", bottomLeft = "bl", bottomRight = "br"
        public var key: String { "wvous-\(rawValue)-corner" }
        public var modifierKey: String { "wvous-\(rawValue)-modifier" }
    }

    /// The record's key for a setting; `uninstall.sh` looks these up by name.
    public static func id(_ key: String) -> String { domain + "/" + key }

    public static let recordKey = "systemMissionControlSaved"

    private let prefs: PreferenceStore
    private let record: SavedRecord

    public init(prefs: PreferenceStore, record: SavedRecord) {
        self.prefs = prefs
        self.record = record
    }

    /// BaneySpaces holds Mission Control off: the record is there.
    public var isTakenByUs: Bool { record.saved != nil }

    private func read(_ key: String) -> NSNumber? { prefs.value(Self.domain, key) }
    private func isOff() -> Bool { read(Self.flag)?.boolValue == true }
    private func isNothing(_ key: String) -> Bool { read(key)?.intValue == Self.nothing }

    public enum TakeOver: Equatable {
        /// Off at the Dock; `changed` when a setting was written, so the Dock must restart to notice.
        case done(changed: Bool)
        /// What was there couldn't be saved durably, so nothing was touched.
        case recordNotSaved
    }

    /// Whether the Dock's switch is on.
    public var isOffAtDock: Bool { isOff() }

    /// Saves what's there and switches Mission Control off. True when a setting changed, so the
    /// Dock must restart to notice (it reads these when it starts).
    @discardableResult
    public func takeOver() -> Bool {
        if case .done(let changed) = takeOverDurably() { return changed }
        return false
    }

    /// Like `takeOver`, but the record is on disk before any Dock setting is touched, so a crash
    /// between the two still leaves the way back; if it can't be saved, nothing is touched.
    public func takeOverDurably() -> TakeOver {
        // A setting that wasn't there is saved as absent (no entry), so restoring removes it
        // again. One that isn't ours any more since the last launch was changed in System
        // Settings since: that's the person's newer choice, and the one to put back later.
        var saved = record.saved ?? [:]
        let first = !isTakenByUs
        if first || !isOff() { saved[Self.id(Self.flag)] = read(Self.flag) }
        for c in Corner.allCases {
            let v = read(c.key)
            if v?.intValue == Self.missionControl { saved[Self.id(c.key)] = v }
        }
        // Written, and on disk, before the settings change: a crash in between still leaves a note to undo.
        let previous = record.saved
        record.saved = saved
        guard record.flush() else {
            record.saved = previous
            _ = record.flush()
            return .recordNotSaved
        }
        var changed = false
        if !isOff() { prefs.set(Self.domain, Self.flag, true as NSNumber); changed = true }
        for c in Corner.allCases where saved[Self.id(c.key)] != nil && read(c.key)?.intValue == Self.missionControl {
            prefs.set(Self.domain, c.key, Self.nothing as NSNumber)
            changed = true
        }
        return .done(changed: changed)
    }

    /// Puts back everything `takeOver` saved. True when a setting changed.
    @discardableResult
    public func restore() -> Bool {
        guard let saved = record.saved else { return false }
        var changed = false
        // Only a setting still as BaneySpaces left it goes back. A switch that was already on
        // before BaneySpaces (a managed Mac, the person's own choice) is left on: writing the same
        // value would only restart the Dock.
        if isOff(), saved[Self.id(Self.flag)]?.boolValue != true {
            prefs.set(Self.domain, Self.flag, saved[Self.id(Self.flag)])
            changed = true
        }
        for c in Corner.allCases {
            guard let was = saved[Self.id(c.key)], isNothing(c.key) else { continue }
            prefs.set(Self.domain, c.key, was)
            changed = true
        }
        record.saved = nil
        _ = record.flush()
        return changed
    }

    /// The hot corners BaneySpaces answers, each with the modifier keys macOS wanted held (0 for
    /// none): the ones set to Mission Control before it took over and still set to nothing, and any
    /// set to Mission Control since (in System Settings, while it ran). Those stay as the person set
    /// them: with the Dock's switch on they open nothing, and the next launch remaps them.
    public func answeredCorners() -> [(corner: Corner, modifiers: Int)] {
        guard let saved = record.saved else { return [] }
        return Corner.allCases.compactMap { c in
            let taken = saved[Self.id(c.key)] != nil && isNothing(c.key)
            guard taken || read(c.key)?.intValue == Self.missionControl else { return nil }
            return (c, read(c.modifierKey)?.intValue ?? 0)
        }
    }
}

/// The keys that open Mission Control, as the key watcher reads them.
public enum MissionControlKey {
    /// F3 on Apple keyboards, the key with the Mission Control icon.
    public static let missionControl: Int64 = 160
    public static let upArrow: Int64 = 126

    /// The Mission Control key, with or without a modifier, and ⌃↑ while macOS still uses it for
    /// Mission Control. ⌃↓ (App Exposé) isn't taken: switching Mission Control off at the Dock
    /// switches that off too.
    public static func matches(code: Int64, control: Bool, command: Bool, option: Bool, shift: Bool, controlUpIsMissionControl: Bool) -> Bool {
        if code == missionControl { return true }
        return controlUpIsMissionControl && code == upArrow && control && !command && !option && !shift
    }
}
