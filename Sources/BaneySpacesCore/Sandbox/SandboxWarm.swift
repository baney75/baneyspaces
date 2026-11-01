import Darwin
import Foundation

/// Where the warm clean clone is kept.
/// - `memory`: booted, checked and left running (about as much RAM as the VM has). A reset promotes it: no state
///   to restore from disk, so the swap takes well under a second of waiting on the guest.
/// - `disk`: suspended (`tart suspend`): no RAM, but a reset has to restore the saved state, which took
///   4.8 to 12 s depending on how busy the Mac was.
public enum WarmLocation: String, Sendable { case memory, disk }

/// Free memory on this Mac, behind a protocol so tests can make it tight.
public protocol MemoryReading: AnyObject {
    func availableBytes() -> UInt64
}

/// Free, inactive and speculative pages: what the system can hand a new VM without pushing apps out.
public final class SystemMemory: MemoryReading {
    public init() {}
    public func availableBytes() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return 0 } // unreadable: assume none, so the warm clone goes to disk
        let pages = UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.speculative_count)
        return pages * UInt64(vm_kernel_page_size)
    }
}

/// When the warm clone may sit in memory. Pure, so the state machine is tested without a Mac.
public enum SandboxWarmPolicy {
    /// Memory is held only while the sandbox is in use: a sandbox command (up, reset, down, view, guest)
    /// in the last 15 minutes. `status` is a look, not use.
    public static let idleLimit: TimeInterval = 15 * 60
    /// Left free for the Mac beyond the VM's own memory.
    public static let headroomBytes: UInt64 = 4 << 30

    /// `resident`: the VM is already running, so its memory is already out of `available` and only the
    /// headroom is left to check (counting it twice would send every warm clone to disk the moment it booted).
    public static func hasRoom(available: UInt64, vmMemoryGB: Int, resident: Bool = false) -> Bool {
        available >= (resident ? 0 : UInt64(vmMemoryGB) << 30) + headroomBytes
    }

    public static func location(lastActivity: TimeInterval?, now: TimeInterval, available: UInt64, vmMemoryGB: Int, resident: Bool = false) -> WarmLocation {
        guard let last = lastActivity, now - last < idleLimit, hasRoom(available: available, vmMemoryGB: vmMemoryGB, resident: resident) else { return .disk }
        return .memory
    }
}

/// How long resets take, over this run. The budget (10 s) is for the 90th percentile.
public struct SandboxResetStats: Equatable, Sendable {
    public var count: Int
    public var p50: TimeInterval
    public var p90: TimeInterval
    public init(samples: [TimeInterval]) {
        let s = samples.sorted()
        count = s.count
        func rank(_ p: Double) -> TimeInterval { s.isEmpty ? 0 : s[min(s.count - 1, max(0, Int((p * Double(s.count)).rounded(.up)) - 1))] }
        p50 = rank(0.5); p90 = rank(0.9)
    }
    public var p90WithinBudget: Bool { count > 0 && p90 <= SandboxPin.resetBudget }
    public var summary: String { count == 0 ? "no resets yet" : String(format: "n=%d p50=%.1f s p90=%.1f s (p90 budget %d s)", count, p50, p90, Int(SandboxPin.resetBudget)) }
}
