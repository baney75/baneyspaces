import Foundation

/// The app and the `baneyspaces` command talk over a Unix socket, one JSON line each way. The socket
/// is in the user's Application Support folder, so only this user's processes can reach it.
public enum Wire {
    public static var supportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/BaneySpaces")
    }
    public static var socketPath: String { supportDir.appendingPathComponent("deck.sock").path }
    public static var statePath: String { supportDir.appendingPathComponent("deck.json").path }

    public struct Request: Codable, Equatable, Sendable {
        public enum Op: String, Codable, Sendable {
            /// An agent's hook event (`event` set).
            case event
            /// Every item, as JSON.
            case list
            /// Bring an item forward: `target` is an item ID or a search.
            case focus
            /// Open `target` (a URL) in the default browser.
            case open
            /// Type `text` into the terminal `target`, as if pasted. Ghostty only.
            case send
            /// Mark `target` (or the caller's row) as needing you.
            case notify
            case ping
            /// The agent workspace: `text` is status, on, off, open, run or move; `args` the rest.
            case agent
            /// Remote machines (local callers only): `text` is on, off or status.
            case remote
            /// An agent computer-use command (`baneyspaces agent snapshot|click|…`): `text` is a
            /// HandsRequest as JSON, the reply's `info["envelope"]` the JSON envelope. Local only:
            /// `Remote.allows` refuses it, so no other machine can act on this one.
            case hands
        }
        public var op: Op
        public var target: String?
        public var text: String?
        public var event: AgentEvent?
        public var args: [String]?
        /// Required from remote machines; ignored on the local socket.
        public var token: String?

        public init(op: Op, target: String? = nil, text: String? = nil, event: AgentEvent? = nil, args: [String]? = nil, token: String? = nil) {
            self.op = op; self.target = target; self.text = text; self.event = event; self.args = args; self.token = token
        }
    }

    public struct Reply: Codable, Equatable, Sendable {
        public var ok: Bool
        public var error: String?
        public var items: [Item]?
        public var info: [String: String]?

        public init(ok: Bool, error: String? = nil, items: [Item]? = nil, info: [String: String]? = nil) {
            self.ok = ok; self.error = error; self.items = items; self.info = info
        }
    }

    /// Sends one request and waits up to `timeout` seconds for the reply. Nil when the app isn't running.
    public static func call(_ request: Request, timeout: Double = 2, path: String = socketPath) -> Reply? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        guard var addr = address(path: path) else { return nil }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0, var data = try? JSONEncoder().encode(request) else { return nil }
        data.append(0x0A)
        guard writeAll(fd, data) else { return nil }
        guard let line = readLine(fd) else { return nil }
        return try? JSONDecoder().decode(Reply.self, from: line)
    }

    public static func address(path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        return addr
    }

    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
    }

    /// Reads up to the first newline, at most `limit` bytes (4 MB unless a caller asks for less),
    /// giving up at `deadline` however slowly the bytes trickle in.
    public static func readLine(_ fd: Int32, limit: Int = 4 << 20, deadline: Date = .distantFuture) -> Data? {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while out.count < limit {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return nil }
            if deadline != .distantFuture {
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&p, 1, Int32(min(left, 60) * 1000)) > 0 else { return nil }
            }
            let n = read(fd, &buf, min(buf.count, limit - out.count))
            if n <= 0 { return out.isEmpty ? nil : out }
            if let nl = buf[0..<n].firstIndex(of: 0x0A) {
                out.append(contentsOf: buf[0..<nl])
                return out
            }
            out.append(contentsOf: buf[0..<n])
        }
        return nil
    }
}
