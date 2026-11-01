import Foundation
import BaneySpacesCore

/// Listens on the Unix socket for `baneyspaces` commands and hook events. Each connection carries one
/// JSON line in and one out. Requests are handled on the main thread, where the engine lives.
final class Server {
    var handle: (Wire.Request) -> Wire.Reply = { _ in Wire.Reply(ok: false, error: "not ready") }
    /// Agent computer-use commands run on the connection's own thread, not the main one: a snapshot
    /// of a slow app must never freeze the menu bar, the dock or a workspace switch. The hands
    /// hop to the main thread only for the few reads that need it.
    var handleHands: (Wire.Request) -> Wire.Reply = { _ in Wire.Reply(ok: false, error: "not ready") }
    /// Sandbox requests take seconds to a minute (a VM boots), so they never run on the main thread:
    /// the session engine, the dock and the hotkeys stay responsive while one waits.
    var handleSandbox: (Wire.Request) -> Wire.Reply = { _ in Wire.Reply(ok: false, error: "not ready") }
    private var listeners: [(fd: Int32, path: String, source: DispatchSourceRead)] = []
    private let io = DispatchQueue(label: "baneyspaces.socket", attributes: .concurrent)

    func stop() {
        for l in listeners { l.source.cancel(); close(l.fd); unlink(l.path) }
        listeners = []
    }

    /// Listens on the current socket and on the old `deck.sock`, so a client started before the update still connects.
    func start() {
        guard listeners.isEmpty else { return }
        try? FileManager.default.createDirectory(at: Wire.supportDir, withIntermediateDirectories: true)
        for path in Wire.socketCandidates() { listen(on: path) }
    }

    private func listen(on path: String) {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var addr = Wire.address(path: path) else { return NSLog("BaneySpaces session: no socket") }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else { close(fd); return NSLog("BaneySpaces session: socket bind failed (%d)", errno) }
        chmod(path, 0o600)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: io)
        src.setEventHandler { [weak self] in self?.accept(fd) }
        src.resume()
        listeners.append((fd, path, src))
    }

    private func accept(_ fd: Int32) {
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
            // The socket is open to every process of this user: what only Donovan may decide is refused here.
            if let why = SocketPolicy.refusal(for: req) {
                Trace.log("refused on the socket: \(req.op.rawValue) \(req.text ?? "") \((req.args ?? []).joined(separator: " "))")
                reply = Wire.Reply(ok: false, error: why)
            } else {
                if req.op == .sandbox {
                    reply = handleSandbox(req)
                } else {
                    reply = req.op == .hands ? handleHands(req) : DispatchQueue.main.sync { handle(req) }
                }
            }
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
/// reaches the session engine: nothing a remote caller sends can change what you see.
final class RemoteServer {
    var handle: (Wire.Request) -> Wire.Reply = { _ in Wire.Reply(ok: false, error: "not ready") }
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let io = DispatchQueue(label: "baneyspaces.session.remote", attributes: .concurrent)
    private(set) var address: String?
    /// At most this many remote requests at once; more are closed straight away, so slow or
    /// endless connections can't use up the app's file descriptors.
    private let slots = DispatchSemaphore(value: 8)

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
    static func tailnetAddress() -> String? { Remote.tunnelAddresses().first }

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
            guard client >= 0 else {
                // Out of descriptors: pause instead of spinning on a backlog that stays readable.
                if errno == EMFILE || errno == ENFILE, let s = source {
                    s.suspend()
                    io.asyncAfter(deadline: .now() + 1) { s.resume() }
                }
                return
            }
            guard slots.wait(timeout: .now()) == .success else { close(client); continue }
            io.async { [weak self] in
                defer { self?.slots.signal() }
                self?.serve(client)
            }
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
        // One deadline for the whole request, however slowly its bytes arrive.
        if let line = Wire.readLine(client, limit: 64 << 10, deadline: Date().addingTimeInterval(5)),
           var req = try? JSONDecoder().decode(Wire.Request.self, from: line) {
            // 256 random bits: nothing to gain from guessing, so no delay that would hold a slot.
            if !Remote.tokensMatch(req.token ?? "", Self.token()) {
                reply = Wire.Reply(ok: false, error: "wrong token")
            } else if !Remote.allows(req) {
                reply = Wire.Reply(ok: false, error: "not allowed from another machine")
            } else {
                // Logged as who it says it is, under the token it came with (never the token).
                req.caller = "remote \(Remote.fingerprint(req.token ?? "")) (\(req.caller ?? "unnamed"))"
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
