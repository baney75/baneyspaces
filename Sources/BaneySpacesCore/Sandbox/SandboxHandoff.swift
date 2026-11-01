import Foundation

/// Where the sandbox keeps its files on the host. Everything is under one folder in Application
/// Support; the guest sees exactly one thing from the host: its own handoff slot.
public struct SandboxPaths: Equatable, Sendable {
    public var root: URL
    public init(root: URL = Wire.supportDir.appendingPathComponent("sandbox")) { self.root = root }
    /// Where a task's folder rests while no guest has it: `handoff/<task>`.
    public var handoffRoot: URL { root.appendingPathComponent("handoff") }
    /// One private folder per VM, the only host path that VM is given. A task's files are moved in when its
    /// guest takes over and copied back out, as plain files only, when it ends.
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
/// as the working guest, after the previous guest is dead.
///
/// **Nothing the guest made is ever followed or trusted on the host.** When a guest ends, its slot is walked
/// with `lstat`/`fstatat` and only regular files with one link and directories are copied out (opened with
/// `O_NOFOLLOW`, created `0600`/`0700`, never with the guest's modes). Symlinks, hard-linked files, devices,
/// FIFOs and sockets are skipped, listed in `SANDBOX-SKIPPED.txt` beside the results, and reported. A host
/// process reading a live slot must open files with `O_NOFOLLOW` too.
///
/// **A slot is never deleted before its files are safe.** It is removed only when every entry was copied (or
/// deliberately skipped) and the registry entry is cleared; on any failure, or while its VM may still run, the
/// slot and its registry entry stay and the release is retried (`tick`, next launch). Nothing here overwrites
/// a name that exists in the task folder. A failed release takes back every file and folder it made, so a retry
/// writes the same names again instead of a second copy beside the first.
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
    /// Walk limits: a guest can make a tree of any shape.
    static let maxDepth = 64, maxEntries = 200_000

    public struct ReleaseResult: Equatable, Sendable {
        /// Every entry was copied or deliberately skipped, and the slot and its registry entry are gone.
        public var complete: Bool
        public var copied: Int
        /// Entries the guest made that were not copied (symlinks, hard links, devices, FIFOs, sockets), by relative path.
        public var skipped: [String]
        public var failure: String?
    }

    // MARK: folders and slots

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

    /// Removes a slot that never held a task's files (a warm clone's). Refuses one the registry knows.
    public static func removeUnboundSlot(_ slot: URL, paths: SandboxPaths) {
        lock.lock(); defer { lock.unlock() }
        // An unreadable registry could be hiding a bound slot: then nothing is removed.
        guard let reg = readRegistry(paths), reg[slot.lastPathComponent] == nil else { return }
        try? FileManager.default.removeItem(at: slot)
    }

    // MARK: bind

    /// Moves the task's files into `slot` (this VM takes over) and records it so a crash can put them back.
    /// All or nothing: if any entry can't move, the ones that did go back and this throws.
    public static func bind(task: String, slot: URL, paths: SandboxPaths) throws {
        let folder = try folder(for: task, paths: paths)
        lock.lock(); defer { lock.unlock() }
        guard var reg = readRegistry(paths) else { throw SandboxError("handoff_failed", "the sandbox's record of live folders (live.json) is unreadable; not touching any files") }
        reg[slot.lastPathComponent] = task
        try writeRegistry(reg, paths)
        let fm = FileManager.default
        var moved: [(URL, URL)] = []
        do {
            for name in try fm.contentsOfDirectory(atPath: folder.path) {
                let from = folder.appendingPathComponent(name), to = slot.appendingPathComponent(name)
                try fm.moveItem(at: from, to: to)
                moved.append((from, to))
            }
        } catch {
            for (from, to) in moved.reversed() { try? fm.moveItem(at: to, to: from) }
            reg[slot.lastPathComponent] = nil
            try? writeRegistry(reg, paths)
            throw SandboxError("handoff_failed", "could not hand the task's files to the sandbox: \(error.localizedDescription)")
        }
    }

    // MARK: release

    /// Copies what the guest left in `slot` into the task's folder, plain files only, then removes the slot and
    /// its registry entry. Never called while a guest may still run. See the type comment for the rules.
    @discardableResult
    public static func release(slot: URL, paths: SandboxPaths, limitBytes: Int64 = 10 << 30) -> ReleaseResult {
        lock.lock(); defer { lock.unlock() }
        guard var reg = readRegistry(paths) else {
            return ReleaseResult(complete: false, copied: 0, skipped: [], failure: "live.json is unreadable")
        }
        guard let task = reg[slot.lastPathComponent] else {
            return ReleaseResult(complete: true, copied: 0, skipped: [], failure: nil) // nothing was bound: nothing to lose
        }
        guard let folder = try? folder(for: task, paths: paths) else {
            return ReleaseResult(complete: false, copied: 0, skipped: [], failure: "the task folder for \(task) is not usable")
        }
        var ctx = Walk(limitBytes: limitBytes)
        copyTree(from: slot.path, to: folder.path, relative: "", depth: 0, ctx: &ctx)
        guard ctx.failure == nil else {
            undo(ctx.created)
            return ReleaseResult(complete: false, copied: 0, skipped: ctx.skipped, failure: ctx.failure)
        }
        if !ctx.skipped.isEmpty { writeSkippedNote(ctx.skipped, in: folder) }
        reg[slot.lastPathComponent] = nil
        try? writeRegistry(reg, paths)
        try? FileManager.default.removeItem(at: slot) // a leftover here is only the guest's junk; the files are safe
        return ReleaseResult(complete: true, copied: ctx.copied, skipped: ctx.skipped, failure: nil)
    }

    /// The slots whose files have not been given back (their VM is gone or going), by VM name and task.
    public static func pending(paths: SandboxPaths) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return readRegistry(paths) ?? [:]
    }

    struct Walk {
        var limitBytes: Int64
        var bytes: Int64 = 0
        var entries = 0
        var copied = 0
        var skipped: [String] = []
        var failure: String?
        /// Every file and folder this attempt made in the task folder, in the order made.
        var created: [String] = []
    }

    /// Takes back what a failed attempt made, newest first, so each folder is empty when its turn comes. Only
    /// `unlink` and `rmdir`: nothing is removed recursively, and nothing this attempt didn't make.
    private static func undo(_ created: [String]) {
        for path in created.reversed() {
            var st = stat()
            guard lstat(path, &st) == 0 else { continue }
            if st.st_mode & S_IFMT == S_IFDIR { rmdir(path) } else { unlink(path) }
        }
    }

    private static func note(_ ctx: inout Walk, skipping path: String, because kind: String) {
        if ctx.skipped.count < 200 { ctx.skipped.append("\(GuestHands.sanitize(path, max: 200)) (\(kind))") }
    }

    private static func copyTree(from src: String, to dst: String, relative: String, depth: Int, ctx: inout Walk) {
        guard ctx.failure == nil else { return }
        guard depth <= maxDepth else { ctx.failure = "the handoff folder is nested deeper than \(maxDepth) levels"; return }
        var dirfd = open(src, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if dirfd < 0, errno == EACCES {
            // The guest chose a mode we can't read: it is our own file (virtiofs maps it to this user), so open it up.
            _ = chmod(src, 0o700)
            dirfd = open(src, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard dirfd >= 0 else { ctx.failure = "could not open \(relative.isEmpty ? "the slot" : relative): errno \(errno)"; return }
        defer { close(dirfd) }
        guard let dir = fdopendir(dup(dirfd)) else { ctx.failure = "could not list \(relative)"; return }
        defer { closedir(dir) }
        var names: [String] = []
        while let e = readdir(dir) {
            let name = withUnsafePointer(to: &e.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) } }
            if name == "." || name == ".." { continue }
            names.append(name)
        }
        for name in names {
            guard ctx.failure == nil else { return }
            ctx.entries += 1
            if ctx.entries > maxEntries { ctx.failure = "more than \(maxEntries) entries in the handoff folder"; return }
            let rel = relative.isEmpty ? name : relative + "/" + name
            var st = stat()
            guard fstatat(dirfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { ctx.failure = "could not look at \(rel)"; return }
            switch st.st_mode & S_IFMT {
            case S_IFREG:
                if st.st_nlink > 1 { note(&ctx, skipping: rel, because: "hard link"); continue }
                copyFile(dirfd: dirfd, name: name, size: Int64(st.st_size), to: dst, relative: rel, ctx: &ctx)
            case S_IFDIR:
                let target = uniquePath(in: dst, name: name)
                guard mkdir(target, 0o700) == 0 else { ctx.failure = "could not make a folder for \(rel)"; return }
                ctx.created.append(target)
                copyTree(from: src + "/" + name, to: target, relative: rel, depth: depth + 1, ctx: &ctx)
            case S_IFLNK: note(&ctx, skipping: rel, because: "symbolic link")
            case S_IFIFO: note(&ctx, skipping: rel, because: "FIFO")
            case S_IFSOCK: note(&ctx, skipping: rel, because: "socket")
            default: note(&ctx, skipping: rel, because: "device or special file")
            }
        }
    }

    private static func copyFile(dirfd: Int32, name: String, size: Int64, to dstDir: String, relative: String, ctx: inout Walk) {
        ctx.bytes += size
        if ctx.bytes > ctx.limitBytes { ctx.failure = "the handoff folder is larger than \(ctx.limitBytes >> 30) GB; nothing more was copied out"; return }
        // O_NONBLOCK so a file swapped for a FIFO can't hang us; O_NOFOLLOW so a swapped-in link isn't followed.
        let fd = openat(dirfd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { ctx.failure = "could not open \(relative) without following links"; return }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1 else { note(&ctx, skipping: relative, because: "changed while copying"); return }
        let target = uniquePath(in: dstDir, name: name)
        let out = open(target, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard out >= 0 else { ctx.failure = "could not create \(relative) in the task folder"; return }
        ctx.created.append(target)
        defer { close(out) }
        var buf = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let n = read(fd, &buf, buf.count)
            if n == 0 { break }
            if n < 0 { ctx.failure = "could not read \(relative)"; return }
            var off = 0
            while off < n {
                let w = buf.withUnsafeBytes { write(out, $0.baseAddress! + off, n - off) }
                if w <= 0 { ctx.failure = "could not write \(relative) (disk full?)"; return }
                off += w
            }
        }
        ctx.copied += 1
    }

    /// A path in `dir` for `name` that doesn't exist: the name as is, else its stem cut to fit plus a short id,
    /// so the result is always a valid file name (at most 255 bytes) and nothing is overwritten.
    static func uniquePath(in dir: String, name: String) -> String {
        func exists(_ p: String) -> Bool { var s = stat(); return lstat(p, &s) == 0 }
        let first = dir + "/" + cut(name, to: 240)
        if !exists(first) { return first }
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        for _ in 0..<1000 {
            let id = String(UUID().uuidString.prefix(6)).lowercased()
            let candidate = dir + "/" + cut(stem, to: 200) + " (sandbox \(id))" + (ext.isEmpty ? "" : "." + cut(ext, to: 20))
            if !exists(candidate) { return candidate }
        }
        return dir + "/" + UUID().uuidString
    }

    /// `s` cut to at most `bytes` UTF-8 bytes, on a character boundary.
    static func cut(_ s: String, to bytes: Int) -> String {
        var out = ""
        for ch in s {
            if out.utf8.count + String(ch).utf8.count > bytes { break }
            out.append(ch)
        }
        return out
    }

    private static func writeSkippedNote(_ skipped: [String], in folder: URL) {
        let text = "The sandbox did not copy these entries the guest made, because they are links, hard links or special files\n"
            + "that could point at files outside the handoff folder:\n\n" + skipped.joined(separator: "\n") + "\n"
        let path = uniquePath(in: folder.path, name: "SANDBOX-SKIPPED.txt")
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = text.withCString { write(fd, $0, strlen($0)) }
    }

    // MARK: size (the slot's quota)

    /// Bytes of regular files in `slot` (their apparent size, so a sparse file counts as large), walked with `lstat`
    /// and never through a link. Stops counting once past `stopAfter`. Nil when the folder couldn't be measured
    /// (nested deeper than `maxDepth`, more than 100,000 entries, a folder that won't open, an entry that can't be
    /// looked at): a guest can build any of those, so callers treat nil as over the quota.
    public static func size(of slot: URL, stopAfter: Int64 = Int64.max) -> Int64? {
        var total: Int64 = 0
        var seen = 0
        var incomplete = false
        func walk(_ path: String, _ depth: Int) {
            guard !incomplete, total <= stopAfter else { return }
            guard depth <= maxDepth, let dir = opendir(path) else { incomplete = true; return }
            defer { closedir(dir) }
            while let e = readdir(dir) {
                let name = withUnsafePointer(to: &e.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) } }
                if name == "." || name == ".." { continue }
                seen += 1
                if seen > 100_000 { incomplete = true; return }
                var st = stat()
                guard lstat(path + "/" + name, &st) == 0 else {
                    if errno == ENOENT { continue } // deleted since it was listed: it costs nothing now
                    incomplete = true; return
                }
                switch st.st_mode & S_IFMT {
                case S_IFREG: total += Int64(st.st_size)
                case S_IFDIR: walk(path + "/" + name, depth + 1)
                default: break
                }
            }
        }
        walk(slot.path, 0)
        return incomplete ? nil : total
    }

    // MARK: registry

    /// The record of which slot holds which task's files; empty when there is no file yet, nil when it can't be read.
    static func readRegistry(_ paths: SandboxPaths) -> [String: String]? {
        guard FileManager.default.fileExists(atPath: paths.registry.path) else { return [:] }
        guard let d = try? Data(contentsOf: paths.registry), let o = try? JSONDecoder().decode([String: String].self, from: d) else { return nil }
        return o
    }

    static func writeRegistry(_ reg: [String: String], _ paths: SandboxPaths) throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let d = try JSONEncoder().encode(reg)
        try d.write(to: paths.registry, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.registry.path)
    }
}
