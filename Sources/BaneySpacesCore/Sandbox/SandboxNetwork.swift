import CryptoKit
import Foundation

/// The sandbox's network: the internet and nothing else. Softnet's own default already lets a VM send
/// only to globally routable IPv4 and the vmnet gateway (which is this Mac). These rules say it again,
/// out loud, and add the Mac's own addresses, so a Softnet default that changed in a release can't
/// quietly open the LAN, the tailnet or the Mac. They copy BaneyFleet's fleet-ci node
/// (`SOFTNET_BLOCK` / `SOFTNET_ALLOW`), plus RFC 1918 and the Mac's addresses.
///
/// Softnet: the longest prefix wins, and a rule with a port beats one without. `out @host` is every
/// connection to the gateway; the allow list gives back only its DNS (DHCP hands the gateway out as
/// the guest's resolver).
public enum SandboxNetwork {
    /// Private, shared (tailnet) and link-local IPv4: never reachable from the guest.
    public static let blockedRanges = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16"]
    public static let blockGateway = "out @host"
    public static let allowDNS = ["out proto udp @host port 53", "out proto tcp @host port 53"]

    public struct Rules: Equatable, Sendable {
        public var block: String
        public var allow: String
        /// Changes when anything the isolation depends on changes: the stamp of a passed self-check.
        public var hash: String {
            let data = Data("\(block)\n\(allow)\n\(SandboxPin.image)\n\(SandboxPin.tartVersion)\n\(SandboxPin.softnetVersion)".utf8)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// The rules for this Mac right now. `hostAddresses` are every IPv4 address it has (LAN, tailnet,
    /// the vmnet bridge); each becomes a /32 block, which covers a public address the ranges don't.
    public static func rules(hostAddresses: [String]) -> Rules {
        let own = Set(hostAddresses.filter(isUsableIPv4)).sorted().map { $0 + "/32" }
        return Rules(block: (blockedRanges + own + [blockGateway]).joined(separator: ","),
                     allow: allowDNS.joined(separator: ","))
    }

    /// Whether `rules` still contain everything the isolation needs. `tart run` is never started
    /// with rules that fail this (fail closed).
    public static func problems(in rules: Rules) -> [String] {
        var out: [String] = []
        let block = rules.block.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        for need in blockedRanges + [blockGateway] where !block.contains(need) { out.append("block list lacks \(need)") }
        let allow = rules.allow.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if allow.isEmpty { out.append("allow list is empty: the guest would have no DNS") }
        for a in allow where !allowDNS.contains(a) { out.append("allow list opens \(a): only the gateway's DNS may be allowed") }
        return out
    }

    public static func isUsableIPv4(_ s: String) -> Bool {
        let p = s.split(separator: ".").compactMap { UInt8($0) }
        return p.count == 4 && p[0] != 127 && p[0] != 0 && s.split(separator: ".").count == 4
    }
}
