import Foundation

public struct SandboxDiskUsage: Equatable, Sendable {
    public var vmBytes: Int64
    public var imageBytes: Int64
    public var vmCount: Int
    public init(vmBytes: Int64 = 0, imageBytes: Int64 = 0, vmCount: Int = 0) {
        self.vmBytes = vmBytes; self.imageBytes = imageBytes; self.vmCount = vmCount
    }
    public var totalBytes: Int64 { vmBytes + imageBytes }
}

public enum SandboxDisk {
    /// Space the sandbox holds in Tart's store: its VMs (`bsx-*`) and the pulled base image. APFS clones
    /// share blocks with the image, so the VM figure is an upper bound.
    public static func usage(tartHome: URL = SandboxPaths.tartHome) -> SandboxDiskUsage {
        let fm = FileManager.default
        var u = SandboxDiskUsage()
        if let vms = try? fm.contentsOfDirectory(atPath: tartHome.appendingPathComponent("vms").path) {
            for v in vms where v.hasPrefix(SandboxPin.vmPrefix) {
                u.vmBytes += allocated(tartHome.appendingPathComponent("vms/\(v)"))
                u.vmCount += 1
            }
        }
        let digest = SandboxPin.image.split(separator: "@").last.map(String.init) ?? ""
        let imageDir = tartHome.appendingPathComponent("cache/OCI/ghcr.io/cirruslabs/macos-tahoe-base/\(digest)")
        if fm.fileExists(atPath: imageDir.path) { u.imageBytes = allocated(imageDir) }
        return u
    }

    static func allocated(_ url: URL) -> Int64 {
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        for case let f as URL in e {
            let v = try? f.resourceValues(forKeys: Set(keys))
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
        return total
    }

    public static func gb(_ bytes: Int64) -> Double { (Double(bytes) / 1_000_000_000 * 10).rounded() / 10 }
}
