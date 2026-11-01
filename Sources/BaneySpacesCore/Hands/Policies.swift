import Foundation

/// Apps that exist once per user and hold his data. An agent never opens them on his Mac: that work
/// goes to the sandbox (phase 2) unless Donovan lends the app.
public enum OncePerUserApps {
    public static let bundles: Set<String> = [
        "com.apple.Safari", "com.apple.Notes", "com.apple.mail", "com.apple.MobileSMS", "com.apple.iCal",
        "com.apple.Photos", "com.apple.reminders", "com.apple.AddressBook", "com.apple.Music", "com.apple.FaceTime",
    ]
    /// Office apps hold his open documents: refused only while they are running.
    public static let whileRunning: Set<String> = ["com.microsoft.Excel", "com.microsoft.Word", "com.microsoft.Powerpoint"]

    public static func refuses(bundle: String, running: Bool) -> Bool {
        bundles.contains(bundle) || (running && whileRunning.contains(bundle))
    }

    public static func error(app: String) -> HandsError {
        HandsError(.needsSandbox, "\(app) holds Donovan's own data, so an agent doesn't open it on his Mac",
                   suggestion: "Do this work in the sandbox (arrives in phase 2), or ask Donovan to lend \(app) and be away from it while you work.", retry: .never)
    }
}

/// Which files an agent may hand to an app: only ones inside the agent handoff folder.
public enum HandoffPath {
    /// The path, resolved through symlinks, when it exists inside `folder`; nil otherwise.
    public static func resolve(_ target: String, in folder: URL) -> URL? {
        let expanded = (target as NSString).expandingTildeInPath
        let base = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : folder.appendingPathComponent(expanded)
        let url = base.standardizedFileURL.resolvingSymlinksInPath()
        let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
        guard url.path.hasPrefix(root + "/"), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    public static func error(_ target: String, folder: URL) -> HandsError {
        HandsError(.badArguments, "\(target) isn't a file in the agent handoff folder",
                   suggestion: "Put the file in \(folder.path) and pass its path. Agents don't open files from anywhere else, and URLs wait for the agent browser profiles.", retry: .safe)
    }

    /// A shot's file name: a plain name, no folder, no dot-dot.
    public static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 120 && !name.contains("/") && !name.contains("\\") && !name.hasPrefix(".") && !name.contains("\0")
    }
}

/// Whether a typed value shows the typing happened: changed from before, and now holds the text.
public enum ValueCheck {
    public static func typed(before: String, after: String, text: String) -> Bool {
        after != before && after.contains(text) && after.count >= text.count
    }
    public static func set(before: String, after: String, expected: String) -> (verified: Bool, changed: Bool) {
        (after == expected, after != before)
    }
}

/// When the user last used each app, so a lent app he is using is left alone.
public struct UserUse: Equatable, Sendable {
    public static let quiet: TimeInterval = 30
    private var leftAt: [Int32: Date] = [:]
    private var front: Int32?

    public init() {}

    /// `pid` came to the front (the app before it just left).
    public mutating func activated(_ pid: Int32, now: Date) {
        if let old = front, old != pid { leftAt[old] = now }
        front = pid
        leftAt[pid] = nil
    }

    /// Whether `pid` is in front (`frontNow`, read from the system), or was within the last 30 s.
    public func inUse(_ pid: Int32, frontNow: Int32?, now: Date) -> Bool {
        if frontNow == pid || front == pid { return true }
        if let t = leftAt[pid] { return now.timeIntervalSince(t) < Self.quiet }
        return false
    }
}
