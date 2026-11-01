import Darwin
import Foundation

/// How many bytes can be read from a pointer a private framework handed over, which is the only
/// way to bound a read when the framework gives no length.
public enum SafeBuffer {
    /// The size of the heap block that starts at `p` when it is one (exact), otherwise how far the
    /// memory mapped readable at `p` runs (an upper bound on the buffer, never past what can be
    /// read without a fault); 0 when nothing readable is there.
    public static func length(of p: UnsafeRawPointer) -> Int {
        let block = malloc_size(p)
        if block > 0 { return block }
        let start = UInt64(UInt(bitPattern: p))
        var address = mach_vm_address_t(start)
        var size: mach_vm_size_t = 0
        var info = vm_region_basic_info_data_64_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_region_basic_info_data_64_t>.size / MemoryLayout<Int32>.size)
        var object: mach_port_t = 0
        let result = withUnsafeMutablePointer(to: &info) { raw in
            raw.withMemoryRebound(to: Int32.self, capacity: Int(count)) { info in
                mach_vm_region(mach_task_self_, &address, &size, VM_REGION_BASIC_INFO_64, info, &count, &object)
            }
        }
        // The call can hand back a port for the region's memory object; every one is let go.
        if object != 0 { mach_port_deallocate(mach_task_self_, object) }
        // The call finds the next region at or after the address; one that starts later isn't ours.
        guard result == KERN_SUCCESS, address <= start, info.protection & VM_PROT_READ != 0 else { return 0 }
        return Int(address + size - start)
    }
}
