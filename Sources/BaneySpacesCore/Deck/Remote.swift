import Foundation

/// Remote machines: another Mac (or a server) on your tailnet sends work to this one's agent
/// workspace. Off unless you turn it on. When on, BaneySpaces listens only on this Mac's tailnet
/// address, every request carries a 256-bit token, and a remote caller can do only what can't
/// touch your screen.
public enum Remote {
    public static let port: UInt16 = 47913

    /// What a remote caller may do: look (ping, list, agent status) and give the agent workspace
    /// work (agent open, agent run). Never focus, type into your terminals, open URLs, move your
    /// windows, or turn the agent workspace on or off: all of those change
    /// what you see.
    public static func allows(_ r: Wire.Request) -> Bool {
        switch r.op {
        case .ping, .list: return true
        case .agent: return ["status", "open", "run"].contains(r.text ?? "status")
        default: return false
        }
    }

    /// Tailscale's addresses (100.64.0.0/10), the only ones BaneySpaces listens on.
    public static func isTailnet(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 100 && (64...127).contains(parts[1])
    }

    /// This Mac's addresses on Tailscale's tunnel. Only a tunnel interface counts: some networks
    /// (Starlink, hotels) hand out 100.64/10 on Wi-Fi too.
    public static func tunnelAddresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var found: [String] = []
        var p = list
        while let i = p {
            defer { p = i.pointee.ifa_next }
            guard let a = i.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET),
                  String(cString: i.pointee.ifa_name).hasPrefix("utun") else { continue }
            let ip = numericHost(a)
            if isTailnet(ip) { found.append(ip) }
        }
        return found
    }

    /// Compares tokens in time that doesn't depend on where they differ.
    public static func tokensMatch(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count, !x.isEmpty else { return false }
        var diff: UInt8 = 0
        for i in x.indices { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    /// A fresh token: 32 random bytes as hex.
    public static func newToken() -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
    }
}

func numericHost(_ sa: UnsafePointer<sockaddr>) -> String {
    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return "" }
    return String(cString: host)
}

extension Wire {
    /// Sends one request to a BaneySpaces on another machine over TCP.
    public static func callRemote(host: String, port: UInt16 = Remote.port, _ request: Request, timeout: Double = 5) -> Reply? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let info = res else { return nil }
        defer { freeaddrinfo(res) }
        // The token only ever goes to a tailnet address, never wherever a typo or a fallen-back
        // DNS search domain resolves.
        guard let sa = info.pointee.ai_addr, Remote.isTailnet(numericHost(sa)) else { return nil }
        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        guard connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0, var data = try? JSONEncoder().encode(request) else { return nil }
        // And only through the tunnel: with Tailscale off, a 100.64/10 address routes out over
        // Wi-Fi to whoever holds it on that network.
        var local = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let mine = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) == 0 ? numericHost($0) : "" }
        }
        guard !mine.isEmpty, Remote.tunnelAddresses().contains(mine) else { return nil }
        data.append(0x0A)
        guard writeAll(fd, data), let line = readLine(fd) else { return nil }
        return try? JSONDecoder().decode(Reply.self, from: line)
    }
}
