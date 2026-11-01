import Foundation

/// The hook for the guest hands daemon: the same commands as the host's `baneyspaces agent`, run inside
/// the sandbox. Phase 2 defines the interface and ships a stub that answers `status`; the real daemon
/// (the engine from phase 1, #105) replaces the stub without changing anything above this file.
///
/// Transport: `tart exec -i <vm> <daemon> --stdio`. The request is one JSON line on stdin; the daemon
/// answers with one JSON line on stdout and exits. No ssh, no password and no network path into the
/// guest: Tart's guest agent is a channel the host owns. The wire format is `docs/sandbox.md`.
public enum GuestHands {
    public static let protocolVersion = 1
    /// Where the real daemon will live in the guest once phase 1 lands. Until then `exec` runs the stub.
    public static let daemonPath = "/usr/local/bin/baneyspaces-hands"

    public struct Request: Codable, Equatable, Sendable {
        public var v: Int
        public var id: String
        /// `status` today; the agent verbs (`snapshot`, `click`, `type`, …) with the daemon.
        public var verb: String
        public var args: [String: String]
        public init(id: String = UUID().uuidString, verb: String, args: [String: String] = [:]) {
            self.v = GuestHands.protocolVersion; self.id = id; self.verb = verb; self.args = args
        }
    }

    public struct Failure: Codable, Equatable, Sendable {
        public var code: String
        /// `safe`, `after_snapshot` or `never`, as in the host's envelope.
        public var retry: String
        public var suggestion: String
    }

    public struct Reply: Codable, Equatable, Sendable {
        public var v: Int
        public var id: String
        public var ok: Bool
        public var data: [String: String]?
        public var error: Failure?
    }

    /// What a daemon (or the stub) reports for `status`.
    public static let statusKeys = ["daemon", "protocol", "macos", "host", "user", "handoff", "uptime_s"]

    /// The stub, run through `bash -c`. It reads one request line, answers `status` with facts about the
    /// guest and refuses every other verb with `not_implemented` and a suggestion. Nothing is
    /// installed in the guest.
    public static let stubScript = #"""
    IFS= read -r line
    id=$(printf '%s' "$line" | sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p')
    verb=$(printf '%s' "$line" | sed -n 's/.*"verb" *: *"\([^"]*\)".*/\1/p')
    esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
    if [ "$verb" = status ]; then
      boot=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*sec = \([0-9]*\).*/\1/p')
      up=$(( $(date +%s) - ${boot:-$(date +%s)} ))
      h=none; [ -d "/Volumes/My Shared Files/handoff" ] && h=mounted
      printf '{"v":1,"id":"%s","ok":true,"data":{"daemon":"stub","protocol":"1","macos":"%s","host":"%s","user":"%s","handoff":"%s","uptime_s":"%s"}}\n' \
        "$(esc "$id")" "$(esc "$(sw_vers -productVersion 2>/dev/null)")" "$(esc "$(scutil --get LocalHostName 2>/dev/null)")" "$(esc "$(id -un)")" "$h" "$up"
    else
      printf '{"v":1,"id":"%s","ok":false,"error":{"code":"not_implemented","retry":"never","suggestion":"the guest hands daemon ships after agent phase 1 (#105); only status works in the sandbox for now"}}\n' "$(esc "$id")"
    fi
    """#

    /// Sends one request to the guest through `tart exec` and decodes the answer.
    public static func call(_ request: Request, vm: String, tart: SandboxTart, timeout: TimeInterval = 30) -> Reply {
        guard let line = try? JSONEncoder().encode(request), let text = String(data: line, encoding: .utf8) else {
            return failure(request.id, "bad_request", "could not encode the request")
        }
        let r = tart.guest(vm, stubScript, stdin: text + "\n", timeout: timeout, limit: maxReplyBytes + 1)
        if r.truncated { return failure(request.id, "bad_reply", "rejected the guest's reply: larger than \(maxReplyBytes) bytes", retry: "safe") }
        guard r.ok else { return failure(request.id, "transport", "tart exec failed (\(r.status))", retry: "safe") } // the guest's own words are not echoed
        return decode(r.stdout, id: request.id)
    }

    /// Everything the guest says is untrusted: it is size-capped, parsed as data against a fixed schema,
    /// never passed to a shell or AppleScript, and labeled `guest-asserted` wherever it is shown. A
    /// reply that breaks any rule is rejected whole (`bad_reply`), not repaired.
    public static let source = "guest-asserted"
    public static let maxReplyBytes = 64 << 10
    public static let maxDataEntries = 32, maxValueBytes = 512, maxKeyBytes = 32

    public static func decode(_ output: String, id: String) -> Reply {
        func bad(_ why: String) -> Reply { failure(id, "bad_reply", "rejected the guest's reply: \(why)", retry: "safe") }
        guard output.utf8.count <= maxReplyBytes else { return bad("larger than \(maxReplyBytes) bytes") }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count == 1, let data = lines[0].data(using: .utf8) else { return bad("not exactly one JSON line") }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return bad("not a hands reply") }
        guard reply.v == protocolVersion else { return failure(id, "version", "the guest speaks protocol \(reply.v), this host \(protocolVersion)") }
        guard reply.id == id else { return bad("answers a different request") }
        func clean(_ s: String, max: Int) -> Bool { s.utf8.count <= max && !s.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f } }
        if reply.ok {
            guard reply.error == nil else { return bad("ok with an error") }
            let d = reply.data ?? [:]
            guard d.count <= maxDataEntries else { return bad("too many fields") }
            for (k, v) in d {
                guard k.utf8.count <= maxKeyBytes, k.range(of: #"\A[a-z_][a-z0-9_]*\z"#, options: .regularExpression) != nil else { return bad("bad field name") }
                guard clean(v, max: maxValueBytes) else { return bad("field \(k) is too long or has control characters") }
            }
        } else {
            guard let e = reply.error, reply.data == nil else { return bad("failure without an error") }
            guard e.code.range(of: #"\A[a-z_]{1,32}\z"#, options: .regularExpression) != nil,
                  ["safe", "after_snapshot", "after", "never"].contains(e.retry),
                  clean(e.suggestion, max: maxValueBytes) else { return bad("malformed error") }
        }
        return reply
    }

    /// Text that came from the guest, made safe to print and log: control characters dropped, length capped.
    public static func sanitize(_ text: String, max: Int = 160) -> String {
        let kept = text.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }
        return String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces).prefix(max).description
    }

    static func failure(_ id: String, _ code: String, _ message: String, retry: String = "never") -> Reply {
        Reply(v: protocolVersion, id: id, ok: false, data: nil, error: Failure(code: code, retry: retry, suggestion: message))
    }
}
