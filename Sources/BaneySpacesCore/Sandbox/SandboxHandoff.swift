import Foundation

/// Where the sandbox keeps its files on the host. Everything is under one folder in Application
/// Support; the guest sees exactly one thing from the host: its own handoff slot.
public struct SandboxPaths: Equatable, Sendable {
    public var root: URL
    public init(root: URL = Wire.supportDir.appendingPathComponent("sandbox")) { self.root = root }
    /// Where a task's folder rests while no guest has it: `handoff/<task>`.
    public var handoffRoot: URL { root.appendingPathComponent("handoff") }
    /// One private folder per VM, the only host path that VM is given. A task's files are moved in when its
    /// guest takes over and moved back out when it ends.
    public var slots: URL { root.appendingPathComponent("slots") }
    public var registry: URL { root.appendingPathComponent("live.json") }
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
/// other task's folder. The sandbox never deletes a task's folder: it holds the task's results.
///
/// **A folder is never shared by two guests.** A running VM can't gain a share, so every VM, the warm clone
/// included, is started with a share of its own: an empty slot folder no other guest has. The task's files
/// are moved into the slot (a rename: instant, and the guest sees them at once) only when that VM takes over
/// as the working guest, after the previous guest is dead, and moved back to `handoff/<task>` when it ends.
/// A VM that was ever bound to a task is never reused: it is deleted at the end of the task.
public enum SandboxHandoff {
    /// A task name is a plain file name: letters, digits, dot, dash, underscore, starting with a letter or digit.
    public static func valid(_ task: String) -> Bool {
        task.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z"#, options: .regularExpression) != nil && !task.contains("..")
    }

    public static func defaultTask(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "task-" + f.string(from: now)
    }

    private static let lock = NSLock()

    /// The task's resting folder, made (owner only) if it isn't there. Throws for a bad name, and for a folder
    /// that turns out to be a symlink, which would share somewhere else.
    public static func folder(for task: String, paths: SandboxPaths) throws -> URL {
        guard valid(task) else { throw SandboxError("bad_task", "a task name is letters, digits, . - _ (up to 64): \(task)") }
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

    /// A fresh, empty, private slot for `vm`.
    public static func makeSlot(vm: String, paths: SandboxPaths) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.slots, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = paths.slots.appendingPathComponent(vm)
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }

    /// Moves the task's files into `slot` (this VM takes over) and records it, so a crash can put them back.
    public static func bind(task: String, slot: URL, paths: SandboxPaths) throws {
        let folder = try folder(for: task, paths: paths)
        lock.lock(); defer { lock.unlock() }
        var reg = readRegistry(paths)
        reg[slot.lastPathComponent] = task
        try writeRegistry(reg, paths)
        try move(from: folder, to: slot)
    }

    /// Moves the files back to the task's folder and forgets the slot. Never called while a guest may still run.
    public static func release(slot: URL, paths: SandboxPaths) {
        lock.lock(); defer { lock.unlock() }
        var reg = readRegistry(paths)
        if let task = reg[slot.lastPathComponent], let folder = try? folder(for: task, paths: paths) {
            try? move(from: slot, to: folder)
        }
        reg[slot.lastPathComponent] = nil
        try? writeRegistry(reg, paths)
    }

    public static func removeSlot(_ slot: URL) { try? FileManager.default.removeItem(at: slot) }

    /// After a crash: every bound slot's files go back to their task folders, every slot goes.
    public static func recover(paths: SandboxPaths) {
        let fm = FileManager.default
        lock.lock()
        let reg = readRegistry(paths)
        lock.unlock()
        for name in reg.keys { release(slot: paths.slots.appendingPathComponent(name), paths: paths) }
        for name in (try? fm.contentsOfDirectory(atPath: paths.slots.path)) ?? [] {
            removeSlot(paths.slots.appendingPathComponent(name))
        }
    }

    /// Moves each entry of `from` into `to` by rename. A name already there gets a suffix: nothing is overwritten.
    static func move(from: URL, to: URL) throws {
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: from.path) {
            var target = to.appendingPathComponent(name)
            var n = 1
            while fm.fileExists(atPath: target.path) || (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil {
                n += 1
                target = to.appendingPathComponent("\(name) (sandbox \(n))")
            }
            try fm.moveItem(at: from.appendingPathComponent(name), to: target)
        }
    }

    static func readRegistry(_ paths: SandboxPaths) -> [String: String] {
        guard let d = try? Data(contentsOf: paths.registry), let o = try? JSONDecoder().decode([String: String].self, from: d) else { return [:] }
        return o
    }

    static func writeRegistry(_ reg: [String: String], _ paths: SandboxPaths) throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let d = try JSONEncoder().encode(reg)
        try d.write(to: paths.registry, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.registry.path)
    }
}
