import Foundation

/// What the sandbox runs on, pinned. A tag can move; a digest cannot, so the base image is named by
/// digest and `up` refuses anything else. The same pins are written in `sandbox/PIN`.
public enum SandboxPin {
    /// cirruslabs/macos-tahoe-base, Tahoe 26.x, resolved 2026-10-31. Not the vanilla image: vanilla has
    /// no Tart guest agent, and `tart exec` (the guest hands daemon's transport) needs it.
    public static let image = "ghcr.io/cirruslabs/macos-tahoe-base@sha256:4aaa751fa7538902d73c767f27a066fc87e83f183069da4e4b5022863abd4c77"
    public static let tartVersion = "2.41.1"
    public static let softnetVersion = "0.25.0"
    /// Every VM this code makes starts with this, so a leftover is recognized and deleted at startup.
    public static let vmPrefix = "bsx-"
    /// Where the one handoff folder appears inside the guest (Tart mounts a named share here).
    public static let handoffName = "handoff"
    public static let guestHandoffPath = "/Volumes/My Shared Files/handoff"
    /// `reset` must hand back a clean guest within this.
    public static let resetBudget: TimeInterval = 10

    /// `registry/name@sha256:<64 hex>`.
    public static func isPinnedByDigest(_ image: String) -> Bool {
        image.range(of: #"^[a-z0-9./_-]+/[a-z0-9._/-]+@sha256:[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }
}

/// The sandbox's settings (Settings > Agents). Clamped, so a hand-edited preference can't ask for a
/// VM bigger than the Mac can spare.
public struct SandboxSettings: Equatable, Sendable {
    public static let memoryChoices = [4, 6, 8, 12, 16]
    public static let cpuChoices = [2, 3, 4, 6, 8]
    public var enabled: Bool
    public var memoryGB: Int
    public var cpus: Int

    public init(enabled: Bool = false, memoryGB: Int = 4, cpus: Int = 4) {
        self.enabled = enabled
        self.memoryGB = Self.memoryChoices.contains(memoryGB) ? memoryGB : 4
        self.cpus = Self.cpuChoices.contains(cpus) ? cpus : 4
    }

    /// At most a quarter of the Mac's memory and half its CPUs: a warm clone boots beside the working VM.
    public func clamped(hostMemoryGB: Int, hostCPUs: Int) -> SandboxSettings {
        let mem = Self.memoryChoices.last { $0 <= max(2, hostMemoryGB / 4) } ?? 2
        let cpu = Self.cpuChoices.last { $0 <= max(2, hostCPUs / 2) } ?? 2
        return SandboxSettings(enabled: enabled, memoryGB: min(memoryGB, mem), cpus: min(cpus, cpu))
    }

    /// Why this Mac can't run the sandbox, nil if it can. A macOS guest needs 4 GB, and the sandbox may take
    /// at most a quarter of the Mac's memory (a warm clone runs beside the working VM), so under 16 GB it is refused
    /// instead of quietly running a VM bigger than the cap.
    public static func hostProblem(hostMemoryGB: Int) -> String? {
        hostMemoryGB >= 16 ? nil : "this Mac has \(hostMemoryGB) GB of memory; the sandbox needs 16 GB (a 4 GB macOS guest is at most a quarter of it)"
    }

    public static let enabledKey = "sandboxEnabled", memoryKey = "sandboxMemoryGB", cpuKey = "sandboxCPUs"

    public static func load(_ d: UserDefaults = .standard) -> SandboxSettings {
        SandboxSettings(enabled: d.bool(forKey: enabledKey),
                        memoryGB: d.object(forKey: memoryKey) as? Int ?? 4,
                        cpus: d.object(forKey: cpuKey) as? Int ?? 4)
    }

    public func save(_ d: UserDefaults = .standard) {
        d.set(enabled, forKey: Self.enabledKey)
        d.set(memoryGB, forKey: Self.memoryKey)
        d.set(cpus, forKey: Self.cpuKey)
    }
}
