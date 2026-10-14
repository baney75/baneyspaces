import Foundation
import BaneySpacesCore

/// Listens on the Unix socket for `baneyspaces` commands and hook events. Each connection carries one
/// JSON line in and one out. Requests are handled on the main thread, where the engine lives.
final class Server {
    var handle: (Wire.Request) -> Wire.Reply = { _ in Wire.Reply(ok: false, error: "not ready") }
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let io = DispatchQueue(label: "deck.socket", attributes: .concurrent)

    func start() {
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
