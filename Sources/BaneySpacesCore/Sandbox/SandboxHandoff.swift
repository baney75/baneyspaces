import Foundation

/// Where the sandbox keeps its files on the host. Everything is under one folder in Application
/// Support; the guest sees exactly one thing from the host: that task's handoff folder.
public struct SandboxPaths: Equatable, Sendable {
    public var root: URL
    public init(root: URL = Wire.supportDir.appendingPathComponent("sandbox")) { self.root = root }
    public var handoffRoot: URL { root.appendingPathComponent("handoff") }
    public var logs: URL { root.appendingPathComponent("logs") }
    public var lock: URL { root.appendingPathComponent("owner.lock") }
    /// Tart's store (`TART_HOME`, else `~/.tart`).
    public static var tartHome: URL {
        if let h = ProcessInfo.processInfo.environment["TART_HOME"], !h.isEmpty { return URL(fileURLWithPath: h) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tart")
    }
}

/// One handoff folder per task, shared read-write into the guest at `SandboxPin.guestHandoffPath`.
/// It's the only thing the guest can see of this Mac: no home folder, no iCloud, no keychain, no
/// other task's folder. The folder is yours when the task ends; the sandbox never deletes it.
public enum SandboxHandoff {
    /// A task name is a plain file name: letters, digits, dot, dash, underscore, starting with a letter or digit.
    public static func valid(_ task: String) -> Bool {
        task.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil && !task.contains("..")
    }

    /// The folder a warm clone is built with: empty, and never a task's.
    public static let warmPlaceholder = "_warm"

    public static func defaultTask(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "task-" + f.string(from: now)
    }

    /// The task's folder, made (owner only) if it isn't there. Throws for a bad name, and for a folder
    /// that turns out to be a symlink, which would share somewhere else.
    public static func folder(for task: String, paths: SandboxPaths) throws -> URL {
        guard valid(task) || task == warmPlaceholder else { throw SandboxError("bad_task", "a task name is letters, digits, . - _ (up to 64): \(task)") }
        let fm = FileManager.default
        let url = paths.handoffRoot.appendingPathComponent(task)
        try fm.createDirectory(at: paths.handoffRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let attrs = try fm.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory else {
            throw SandboxError("bad_handoff", "\(url.path) is not a plain folder (a symlink would share somewhere else)")
        }
        return url
    }
}
