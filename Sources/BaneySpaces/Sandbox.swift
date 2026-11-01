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

    /// Nothing of the sandbox outlives the app.
    func shutdown() {
        timer?.invalidate()
        service.manager.shutdown()
    }

    /// Deletes VMs a crash left behind, once, in the background, if the sandbox is on.
    func cleanupAtLaunch() {
        guard SandboxSettings.load().enabled else { return }
        DispatchQueue.global(qos: .utility).async { [service] in
            do { try service?.manager.startupCleanup() } catch { NSLog("BaneySpaces sandbox: %@", "\(error)") }
        }
    }

    // MARK: SandboxWindowHost (called off the main thread; they hop to it)

    func agentWorkspace() -> Int? { DispatchQueue.main.sync { Spaces.agentWorkspace } }

    func claim(pid: Int32, workspace: Int) {
        DispatchQueue.main.sync { spacesProvider()?.claimNextWindow(of: pid, for: workspace, within: 40, newProcess: true) }
    }

    func windows(of pid: Int32) -> [SandboxWindows.Window] {
        DispatchQueue.main.sync { spacesProvider()?.windowsOf(pid: pid) ?? [] }
    }

    func move(window: UInt32, to workspace: Int) {
        DispatchQueue.main.sync { spacesProvider()?.move(window, to: workspace) }
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
