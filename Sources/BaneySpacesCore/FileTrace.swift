import Foundation

/// Append-only rotating file log under a directory you choose.
/// Keeps `trace.log` plus `trace.log.1` … `trace.log.(maxFiles-1)`, each capped near `maxBytes`.
/// Lines are public by contract of the caller (no window titles, no home paths beyond `~`).
public enum FileTrace: Sendable {
    public static let defaultMaxBytes = 200_000
    public static let defaultMaxFiles = 3

    private static let lock = NSLock()

    /// Appends `line` (a newline is added). Rotates when the active file would exceed `maxBytes`.
    public static func append(
        _ line: String,
        directory: URL,
        name: String = "trace.log",
        maxBytes: Int = defaultMaxBytes,
        maxFiles: Int = defaultMaxFiles,
        fileManager: FileManager = .default
    ) throws {
        precondition(maxBytes > 0)
        precondition(maxFiles >= 1)
        lock.lock()
        defer { lock.unlock() }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let active = directory.appendingPathComponent(name)
        let text = line.hasSuffix("\n") ? line : line + "\n"
        let payload = Data(text.utf8)
        let size = (try? fileManager.attributesOfItem(atPath: active.path)[.size] as? Int) ?? 0
        if size > 0, size + payload.count > maxBytes {
            try rotateUnlocked(directory: directory, name: name, maxFiles: maxFiles, fileManager: fileManager)
        }
        if fileManager.fileExists(atPath: active.path) {
            let handle = try FileHandle(forWritingTo: active)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: payload)
        } else {
            try payload.write(to: active, options: .atomic)
        }
    }

    /// Oldest slot is deleted; each `trace.log.N` shifts up; active becomes `.1`.
    public static func rotate(
        directory: URL,
        name: String = "trace.log",
        maxFiles: Int = defaultMaxFiles,
        fileManager: FileManager = .default
    ) throws {
        precondition(maxFiles >= 1)
        lock.lock()
        defer { lock.unlock() }
        try rotateUnlocked(directory: directory, name: name, maxFiles: maxFiles, fileManager: fileManager)
    }

    private static func rotateUnlocked(
        directory: URL,
        name: String,
        maxFiles: Int,
        fileManager: FileManager
    ) throws {
        let active = directory.appendingPathComponent(name)
        if maxFiles == 1 {
            try? fileManager.removeItem(at: active)
            return
        }
        let oldest = directory.appendingPathComponent("\(name).\(maxFiles - 1)")
        try? fileManager.removeItem(at: oldest)
        if maxFiles > 2 {
            for n in stride(from: maxFiles - 2, through: 1, by: -1) {
                let src = directory.appendingPathComponent("\(name).\(n)")
                let dst = directory.appendingPathComponent("\(name).\(n + 1)")
                if fileManager.fileExists(atPath: src.path) {
                    try? fileManager.removeItem(at: dst)
                    try fileManager.moveItem(at: src, to: dst)
                }
            }
        }
        if fileManager.fileExists(atPath: active.path) {
            let first = directory.appendingPathComponent("\(name).1")
            try? fileManager.removeItem(at: first)
            try fileManager.moveItem(at: active, to: first)
        }
    }
}
