import AppKit
import BaneySpacesCore

/// The app's side of the sandbox: owns the service, answers `baneyspaces sandbox …` off the main
/// thread, and places the VM's display window on the agent workspace (never yours).
final class AppSandbox: SandboxWindowHost {
    private(set) var service: SandboxService!
    private var timer: Timer?
    var onChange: (() -> Void)?

    init(spaces: @escaping () -> Spaces?) {
        self.spacesProvider = spaces
        let (svc, _) = SandboxSystem.make(settings: { SandboxSettings.load().clamped(hostMemoryGB: Int(ProcessInfo.processInfo.physicalMemory >> 30),
                                                                                    hostCPUs: ProcessInfo.processInfo.activeProcessorCount) },
                                          windowHost: self)
        service = svc
    }
    private let spacesProvider: () -> Spaces?

    /// Every few seconds: a VM that exited on its own is deleted, a failed delete is retried.
    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.global(qos: .utility).async { self.service.manager.tick(); DispatchQueue.main.async { self.onChange?() } }
        }
    }

    /// Nothing of the sandbox outlives the app. Never waits on a lifecycle operation: processes are killed at
    /// once and the deletes run on their own thread; this waits a few seconds at most (the window host calls
    /// below give up after 1.5 s, so a view in progress can't hold it).
    func shutdown() {
        timer?.invalidate()
        service.manager.shutdown(deadline: 4)
    }

    /// Settings turned the sandbox off: every VM and the warm clone go, off the main thread.
    func disable() {
        DispatchQueue.global(qos: .utility).async { [service] in service?.manager.stopAll() }
    }

    /// At launch, sandbox on or off: deletes VMs a crash left behind and, once they are verified gone, puts back the
    /// files of any slot they held. With the sandbox off the lock is given up again straight after, so nothing else
    /// (the probe) is locked out while the app merely runs.
    func cleanupAtLaunch() {
        let keep = SandboxSettings.load().enabled
        DispatchQueue.global(qos: .utility).async { [service] in
            do { try service?.manager.startupCleanup(keepOwnership: keep) } catch { NSLog("BaneySpaces sandbox: %@", "\(error)") }
        }
    }

    // MARK: SandboxWindowHost (called off the main thread). They never wait on the main thread for long: if the
    // main thread is busy, or waiting for the sandbox to finish at quit, the call gives up and says so.

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var v: T
        init(_ v: T) { self.v = v }
        var value: T { get { lock.lock(); defer { lock.unlock() }; return v } set { lock.lock(); v = newValue; lock.unlock() } }
    }

    private func onMain<T>(_ fallback: T, timeout: TimeInterval = 1.5, _ body: @escaping () -> T) -> T {
        if Thread.isMainThread { return body() }
        let box = Box(fallback)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { box.value = body(); done.signal() }
        return done.wait(timeout: .now() + timeout) == .success ? box.value : fallback
    }

    func agentWorkspace() -> Int? { onMain(nil) { Spaces.agentWorkspace } }

    func claim(pid: Int32, workspace: Int) -> Bool {
        onMain(false, timeout: 5) { [spacesProvider] in
            guard let spaces = spacesProvider() else { return false }
            spaces.claimNextWindow(of: pid, for: workspace, within: 40, newProcess: true)
            return true
        }
    }

    func windows(of pid: Int32) -> [SandboxWindows.Window] {
        onMain([]) { [spacesProvider] in spacesProvider()?.windowsOf(pid: pid) ?? [] }
    }

    func move(window: UInt32, to workspace: Int) {
        _ = onMain(false) { [spacesProvider] in spacesProvider()?.move(window, to: workspace); return true }
    }
}

extension AppSandbox {
    /// What Settings > Agents shows, read off the main thread.
    struct Summary { var state: String; var detail: String; var running: Bool; var busy: Bool }

    func summary() -> Summary {
        let s = service.manager.snapshot()
        let disk = SandboxDisk.usage()
        let used = String(format: "%.1f GB (image %.1f, VMs up to %.1f)", SandboxDisk.gb(disk.totalBytes), SandboxDisk.gb(disk.imageBytes), SandboxDisk.gb(disk.vmBytes))
        var line: String
        switch s.phase {
        case .running: line = "Running" + (s.task.map { " for \($0)" } ?? "") + (s.graphics ? ", window on the agent workspace" : ", headless")
        case .starting: line = "Starting"
        case .resetting: line = "Resetting"
        case .stopping: line = "Stopping"
        case .error: line = "Stopped after an error: \(s.lastError ?? "see baneyspaces sandbox status")"
        case .stopped: line = "Not running"
        }
        if s.phase == .running { line += s.warm == .ready ? ". A clean clone is ready." : ". Building the next clean clone." }
        return Summary(state: line, detail: used, running: s.phase == .running, busy: [.starting, .resetting, .stopping].contains(s.phase))
    }

    func resetNow(done: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = self.service.handle(Wire.Request(op: .sandbox, text: "reset"))
            DispatchQueue.main.async { done(r.ok ? nil : r.error) }
        }
    }

    func deleteImages(done: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = self.service.handle(Wire.Request(op: .sandbox, text: "images", args: ["delete"]))
            DispatchQueue.main.async { done(r.ok ? nil : r.error) }
        }
    }
}
