import Foundation

/// The result of running a tool.
public struct DeviceRun: Equatable, Sendable {
    public var status: Int32
    public var out: Data
    public var err: String
    public var timedOut: Bool
    /// False when the program could not be started at all (nothing was sent to the device).
    public var started: Bool
    public init(status: Int32 = 0, out: Data = Data(), err: String = "", timedOut: Bool = false, started: Bool = true) {
        self.status = status; self.out = out; self.err = err; self.timedOut = timedOut; self.started = started
    }
    public init(_ text: String, status: Int32 = 0) { self.init(status: status, out: Data(text.utf8)) }
    public var text: String { String(decoding: out, as: UTF8.self) }
    public var ok: Bool { started && !timedOut && status == 0 }
}

/// Runs the tools the device hands use. Every device action goes through here, so a test can answer
/// them all and a probe can count them: nothing in this file posts input to the host.
public protocol DeviceRunner: AnyObject {
    func run(_ exe: String, _ args: [String], timeout: TimeInterval) -> DeviceRun
    /// Starts a program that keeps running after this call (an emulator); its pid, or nil.
    func spawn(_ exe: String, _ args: [String]) -> Int32?
}

public final class ProcessDeviceRunner: DeviceRunner {
    public init() {}

    public func run(_ exe: String, _ args: [String], timeout: TimeInterval) -> DeviceRun {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return DeviceRun(status: 127, err: "\(error)", started: false) }
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        for (pipe, isOut) in [(out, true), (err, false)] {
            group.enter()
            DispatchQueue.global().async {
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                if isOut { outData = d } else { errData = d }
                group.leave()
            }
        }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { p.waitUntilExit(); done.signal() }
        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            if done.wait(timeout: .now() + 2) == .timedOut { kill(p.processIdentifier, SIGKILL) }
        }
        _ = group.wait(timeout: .now() + 2)
        return DeviceRun(status: p.terminationStatus, out: outData, err: String(decoding: errData, as: UTF8.self), timedOut: timedOut)
    }

    public func spawn(_ exe: String, _ args: [String]) -> Int32? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        return p.processIdentifier
    }
}

/// Where the tools are. Nothing is installed from here: a missing one is reported.
public struct DeviceTools: Equatable, Sendable {
    public var xcrun: String?
    public var adb: String?
    public var emulator: String?
    public var axe: String?

    public init(xcrun: String? = nil, adb: String? = nil, emulator: String? = nil, axe: String? = nil) {
        self.xcrun = xcrun; self.adb = adb; self.emulator = emulator; self.axe = axe
    }

    public static func locate(env: [String: String], home: String, exists: (String) -> Bool) -> DeviceTools {
        func first(_ c: [String]) -> String? { c.first(where: exists) }
        let sdk = [env["ANDROID_HOME"], env["ANDROID_SDK_ROOT"], home + "/Library/Android/sdk", home + "/Android/Sdk"].compactMap { $0 }
        let path = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        return DeviceTools(
            xcrun: first(["/usr/bin/xcrun"]),
            adb: first(sdk.map { $0 + "/platform-tools/adb" } + ["/opt/homebrew/bin/adb", "/usr/local/bin/adb", "/usr/bin/adb"] + path.map { $0 + "/adb" }),
            emulator: first(sdk.map { $0 + "/emulator/emulator" }),
            axe: first([home + "/Library/Application Support/BaneySpaces/tools/axe/bin/axe"]))
    }
}
