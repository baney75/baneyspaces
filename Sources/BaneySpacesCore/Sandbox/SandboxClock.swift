import Foundation

/// Time the sandbox code reads and waits on, so tests run a 10-second budget in no time.
public protocol SandboxClock: AnyObject {
    func now() -> TimeInterval
    func sleep(_ seconds: TimeInterval)
}

public final class SystemClock: SandboxClock {
    public init() {}
    public func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    public func sleep(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }
}

/// What a child process answered.
public struct ProcessResult: Equatable, Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    /// The child wrote more than the caller allowed; it was stopped and the rest dropped.
    public var truncated: Bool
    public init(status: Int32, stdout: String = "", stderr: String = "", timedOut: Bool = false, truncated: Bool = false) {
        self.status = status; self.stdout = stdout; self.stderr = stderr; self.timedOut = timedOut; self.truncated = truncated
    }
    public var ok: Bool { status == 0 && !timedOut && !truncated }
    public var tail: String { String((stderr.isEmpty ? stdout : stderr).trimmingCharacters(in: .whitespacesAndNewlines).suffix(200)) }
}

/// A child that keeps running after it was started (`tart run`).
public protocol RunningProcess: AnyObject {
    var pid: Int32 { get }
    var isRunning: Bool { get }
    func terminate()
    func kill()
    /// Lets a process started with `hold: true` go. It has executed nothing of the real program until this.
    func release()
    /// True once it has exited, false if `timeout` ran out first.
    func waitForExit(timeout: TimeInterval) -> Bool
}

/// The only way the sandbox starts a program. Tests give it a fake `tart`.
public protocol ProcessRunning: AnyObject {
    /// `outputLimit`: bytes of stdout or stderr kept; a child that writes more is stopped and the result is `truncated`.
    func run(_ exe: String, _ args: [String], env: [String: String], stdin: String?, timeout: TimeInterval, outputLimit: Int) -> ProcessResult
    /// `hold`: the child waits, before running `exe`, until `release()` is called on it, so a caller can
    /// register a window claim for its pid before the program can show a window.
    func spawn(_ exe: String, _ args: [String], env: [String: String], logPath: String?, hold: Bool) throws -> RunningProcess
}

public final class SystemProcessRunner: ProcessRunning {
    public init() {}

    public func run(_ exe: String, _ args: [String], env: [String: String], stdin: String?, timeout: TimeInterval, outputLimit: Int) -> ProcessResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = env
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = stdin != nil ? inp : FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch {
            return ProcessResult(status: 127, stderr: "\(exe): \(error.localizedDescription)")
        }
        var outData = Data(), errData = Data()
        let over = OverflowFlag()
        let readers = DispatchGroup()
        readers.enter(); readers.enter()
        func drain(_ h: FileHandle, into sink: @escaping (Data) -> Void) {
            Thread.detachNewThread {
                var got = Data()
                while let chunk = try? h.read(upToCount: 65536), !chunk.isEmpty {
                    if got.count + chunk.count > outputLimit {
                        got.append(chunk.prefix(outputLimit - got.count))
                        over.set()
                        break
                    }
                    got.append(chunk)
                }
                sink(got)
                readers.leave()
            }
        }
        drain(out.fileHandleForReading) { outData = $0 }
        drain(err.fileHandleForReading) { errData = $0 }
        if let stdin {
            try? inp.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
            try? inp.fileHandleForWriting.close()
        }
        var timedOut = false
        // A child that floods its output is stopped as soon as the reader gives up on it.
        let deadline = Date().addingTimeInterval(timeout)
        while done.wait(timeout: .now() + 0.05) == .timedOut {
            if over.isSet { p.terminate(); break }
            if Date() >= deadline { break }
        }
        if p.isRunning {
            timedOut = true
            p.terminate()
            if done.wait(timeout: .now() + 3) == .timedOut { Darwin.kill(p.processIdentifier, SIGKILL); _ = done.wait(timeout: .now() + 3) }
        }
        _ = readers.wait(timeout: .now() + 3)
        return ProcessResult(status: timedOut ? 124 : p.terminationStatus,
                             stdout: String(decoding: outData, as: UTF8.self), stderr: String(decoding: errData, as: UTF8.self),
                             timedOut: timedOut && !over.isSet, truncated: over.isSet)
    }

    public func spawn(_ exe: String, _ args: [String], env: [String: String], logPath: String?, hold: Bool) throws -> RunningProcess {
        let p = Process()
        var fifo: String?
        if hold {
            // A FIFO the shell reads before it execs the real program: nothing of `exe` runs until release().
            let path = NSTemporaryDirectory() + "bsx-hold-\(UUID().uuidString)"
            guard mkfifo(path, 0o600) == 0 else { throw SandboxError("run_failed", "could not make the launch barrier") }
            fifo = path
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "IFS= read -r _ < \"$1\"; shift; exec \"$@\"", "sh", path, exe] + args
        } else {
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
        }
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        var log: FileHandle?
        if let logPath {
            try? FileManager.default.createDirectory(atPath: (logPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let fd = open(logPath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
            if fd >= 0 { log = FileHandle(fileDescriptor: fd, closeOnDealloc: true) }
        }
        p.standardOutput = log ?? FileHandle.nullDevice
        p.standardError = log ?? FileHandle.nullDevice
        do { try p.run() } catch { if let fifo { unlink(fifo) }; throw error }
        try? log?.close()
        return SystemRunning(p, fifo: fifo)
    }
}

final class OverflowFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    func set() { lock.lock(); v = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return v }
}

final class SystemRunning: RunningProcess {
    let p: Process
    private var fifo: String?
    private let lock = NSLock()
    init(_ p: Process, fifo: String? = nil) { self.p = p; self.fifo = fifo }
    func release() {
        lock.lock(); let path = fifo; fifo = nil; lock.unlock()
        guard let path else { return }
        defer { unlink(path) }
        // The shell opens the FIFO for reading first; a non-blocking open for writing fails until it has.
        for _ in 0..<200 {
            let fd = open(path, O_WRONLY | O_NONBLOCK)
            if fd >= 0 { _ = write(fd, "\n", 1); close(fd); return }
            if !p.isRunning { return }
            Thread.sleep(forTimeInterval: 0.025)
        }
    }
    var pid: Int32 { p.processIdentifier }
    var isRunning: Bool { p.isRunning }
    func terminate() { if p.isRunning { p.terminate() } }
    func kill() {
        if p.isRunning { Darwin.kill(p.processIdentifier, SIGKILL) }
        lock.lock(); let path = fifo; fifo = nil; lock.unlock()
        if let path { unlink(path) }
    }
    func waitForExit(timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while p.isRunning {
            if Date() >= end { return false }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return true
    }
}
