import Foundation

/// A listener on every interface of this Mac (IPv4, or IPv6 only), on a port the OS picks.
public final class TCPProbeListener: ProbeListener {
    private var fd: Int32
    public let port: UInt16

    public init?(ipv6: Bool) {
        let family = ipv6 ? AF_INET6 : AF_INET
        let s = socket(family, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        var ok = false
        if ipv6 {
            var on: Int32 = 1
            setsockopt(s, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
            var a = sockaddr_in6()
            a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            a.sin6_family = sa_family_t(AF_INET6)
            a.sin6_addr = in6addr_any
            ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } } == 0
        } else {
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            a.sin_family = sa_family_t(AF_INET)
            a.sin_addr.s_addr = INADDR_ANY
            ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
        }
        guard ok, listen(s, 32) == 0 else { Darwin.close(s); return nil }
        var bound = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let got = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
        guard got == 0 else { Darwin.close(s); return nil }
        if ipv6 {
            port = withUnsafePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) } }
        } else {
            port = withUnsafePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) } }
        }
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
        fd = s
    }

    public func accepted() -> Int {
        var n = 0
        while fd >= 0 {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 200) > 0 else { break }
            let c = accept(fd, nil, nil)
            if c < 0 { break }
            Darwin.close(c)
            n += 1
        }
        return n
    }

    public func close() { if fd >= 0 { Darwin.close(fd); fd = -1 } }
    deinit { close() }
}

/// Reads this Mac's addresses, router, Tailscale and firewall, the way BaneyFleet's `host_facts` does.
public final class SystemHostFacts: HostFactsReading {
    let runner: ProcessRunning
    let exists: (String) -> Bool
    public static let tailscalePaths = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
    static let socketfilterfw = "/usr/libexec/ApplicationFirewall/socketfilterfw"
    let exe: String

    public init(runner: ProcessRunning, exists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                exe: String = CommandLine.arguments.first.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } ?? "") {
        self.runner = runner; self.exists = exists; self.exe = exe
    }

    public func listener() -> ProbeListener? { TCPProbeListener(ipv6: false) }

    public func read() -> HostFacts {
        var facts = HostFacts(tailscaleInstalled: Self.tailscalePaths.contains(where: exists))
        var list: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&list) == 0 {
            var p = list
            while let i = p {
                defer { p = i.pointee.ifa_next }
                guard let a = i.pointee.ifa_addr, i.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
                let name = String(cString: i.pointee.ifa_name)
                let ip = numericHost(a)
                if a.pointee.sa_family == UInt8(AF_INET) {
                    guard SandboxNetwork.isUsableIPv4(ip) else { continue }
                    if !facts.addresses.contains(where: { $0.ip == ip }) {
                        facts.addresses.append(.init("this Mac's address on \(name)", ip, iface: name))
                    }
                }
            }
            freeifaddrs(list)
        }
        let env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let route = runner.run("/sbin/route", ["-n", "get", "default"], env: env, stdin: nil, timeout: 20, outputLimit: 1 << 16)
        if route.ok, let m = route.stdout.range(of: #"gateway:\s*(\d+\.\d+\.\d+\.\d+)"#, options: .regularExpression) {
            facts.router = route.stdout[m].split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        facts.firewallProblem = firewallProblem(env: env)
        return facts
    }

    /// The Application Firewall can drop an incoming connection to the throwaway listener without a
    /// word, which would look exactly like Softnet blocking it. Nil only when the firewall is off, or
    /// on with this program allowed; anything unreadable is a problem (fail closed).
    func firewallProblem(env: [String: String]) -> String? {
        func ask(_ args: [String]) -> String? {
            let r = runner.run(Self.socketfilterfw, args, env: env, stdin: nil, timeout: 20, outputLimit: 1 << 16)
            return r.ok ? r.stdout + r.stderr : nil
        }
        guard let state = ask(["--getglobalstate"]) else {
            return "could not read the Application Firewall state (socketfilterfw): a dropped probe would pass unnoticed"
        }
        if state.range(of: #"State\s*=\s*2"#, options: .regularExpression) != nil {
            return "the Application Firewall is set to block all incoming connections: the probe's listener can't be reached, so a timeout would prove nothing"
        }
        if state.range(of: #"disabled|State\s*=\s*0"#, options: [.regularExpression, .caseInsensitive]) != nil { return nil }
        guard state.range(of: #"enabled|State\s*=\s*[12]"#, options: [.regularExpression, .caseInsensitive]) != nil else {
            return "unrecognized Application Firewall state \(state.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))"
        }
        if let answer = ask(["--getappblocked", exe]),
           answer.range(of: #"\b(permitted|allowed|unblocked)\b"#, options: [.regularExpression, .caseInsensitive]) != nil,
           answer.range(of: #"\bnot (permitted|allowed)\b|\bblocked\b"#, options: [.regularExpression, .caseInsensitive]) == nil {
            return nil
        }
        return "the Application Firewall is on and \(exe) is not allowed to accept incoming connections, so it can drop the probe to the throwaway listener and a timeout would prove nothing: allow it (sudo \(Self.socketfilterfw) --add \(exe); sudo \(Self.socketfilterfw) --unblockapp \(exe)) or turn the firewall off"
    }
}
