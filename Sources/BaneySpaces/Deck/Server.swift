import Foundation
import BaneySpacesCore

/// Listens on the Unix socket for `baneyspaces` commands and hook events. Each connection carries one
/// JSON line in and one out. Requests are handled on the main thread, where the engine lives.
final class Server {
    var handle: (Wire.Request) -> Wire.Reply = { _ in Wire.Reply(ok: false, error: "not ready") }
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let io = DispatchQueue(label: "deck.socket", attributes: .concurrent)

    func stop() {
        source?.cancel()
        source = nil
        if fd >= 0 { close(fd); fd = -1 }
        unlink(Wire.socketPath)
    }

    func start() {
        guard source == nil else { return }
        let path = Wire.socketPath
        try? FileManager.default.createDirectory(at: Wire.supportDir, withIntermediateDirectories: true)
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var addr = Wire.address(path: path) else { return NSLog("BaneySpaces deck: no socket") }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { return NSLog("BaneySpaces deck: socket bind failed (%d)", errno) }
        chmod(path, 0o600)
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: io)
        src.setEventHandler { [weak self] in self?.accept() }
        src.resume()
        source = src
    }

    private func accept() {
        while true {
            let client = Darwin.accept(fd, nil, nil)
            guard client >= 0 else { return }
            io.async { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        // BSD sockets inherit O_NONBLOCK from the listener; this one should block until its line arrives.
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard let line = Wire.readLine(client) else { return }
        let reply: Wire.Reply
        if let req = try? JSONDecoder().decode(Wire.Request.self, from: line) {
            reply = DispatchQueue.main.sync { handle(req) }
        } else {
            reply = Wire.Reply(ok: false, error: "bad request")
        }
        guard var data = try? JSONEncoder().encode(reply) else { return }
        data.append(0x0A)
        _ = Wire.writeAll(client, data)
    }
}

/// Listens on this Mac's tailnet address for work from your other machines. Each request must
/// carry the token from `baneyspaces remote token`, and only what `Remote.allows` lets through
/// reaches the Deck: nothing a remote caller sends can change what you see.
final class RemoteServer {
    var handle: (Wire.Request) -> Wire.Reply = { _ in Wire.Reply(ok: false, error: "not ready") }
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let io = DispatchQueue(label: "baneyspaces.deck.remote", attributes: .concurrent)
    private(set) var address: String?

    static var tokenURL: URL { Wire.supportDir.appendingPathComponent("remote-token") }

    /// The token, made on first use and readable only by you.
    static func token() -> String {
        if let t = try? String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), t.count == 64 { return t }
        let t = Remote.newToken()
        try? FileManager.default.createDirectory(at: Wire.supportDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tokenURL.path, contents: Data(t.utf8), attributes: [.posixPermissions: 0o600])
        return t
    }

    /// This Mac's tailnet address, if Tailscale is connected.
    static func tailnetAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var p = list
        while let i = p {
            defer { p = i.pointee.ifa_next }
            guard let a = i.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(a, socklen_t(a.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if Remote.isTailnet(ip) { return ip }
        }
        return nil
    }

    /// Starts listening on the tailnet address; false when Tailscale isn't connected.
    func start() -> Bool {
        guard source == nil else { return true }
        guard let ip = Self.tailnetAddress() else { return false }
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Remote.port.bigEndian
        inet_pton(AF_INET, ip, &addr.sin_addr)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); fd = -1; return false }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: io)
        src.setEventHandler { [weak self] in self?.accept() }
        src.resume()
        source = src
        address = ip
        return true
    }

    func stop() {
        source?.cancel()
        source = nil
        if fd >= 0 { close(fd); fd = -1 }
        address = nil
    }

    private func accept() {
        while true {
            let client = Darwin.accept(fd, nil, nil)
            guard client >= 0 else { return }
            io.async { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let reply: Wire.Reply
        if let line = Wire.readLine(client, limit: 64 << 10), var req = try? JSONDecoder().decode(Wire.Request.self, from: line) {
            if !Remote.tokensMatch(req.token ?? "", Self.token()) {
                // A wrong token costs a second, so guessing gets nowhere.
                Thread.sleep(forTimeInterval: 1)
                reply = Wire.Reply(ok: false, error: "wrong token")
            } else if !Remote.allows(req) {
                reply = Wire.Reply(ok: false, error: "not allowed from another machine")
            } else {
                req.token = nil
                reply = DispatchQueue.main.sync { handle(req) }
            }
        } else {
            reply = Wire.Reply(ok: false, error: "bad request")
        }
        guard var data = try? JSONEncoder().encode(reply) else { return }
        data.append(0x0A)
        _ = Wire.writeAll(client, data)
    }
}
