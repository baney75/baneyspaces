import BaneySpacesCore
import Darwin
import Foundation

/// `baneyspaces agent snapshot|find|get|click|type|set-value|press|scroll|select|toggle|shot|open|lend|return|windows`
/// and `baneyspaces mcp`. The command only parses and prints: every action runs inside the BaneySpaces
/// app (which holds Accessibility) and comes back as one JSON envelope.
enum HandsCLI {
    /// The session lends belong to: the agent's own (`--session`), else its terminal, the same default
    /// `event` uses, so the agent ending its session returns what it borrowed.
    static func defaultSession() -> String {
        let tty = controllingTTY()
        return tty.isEmpty ? "default" : tty
    }

    /// Sends one request to the app and returns its envelope. Nothing here can fail without saying why.
    static func send(_ request: HandsRequest, timeout: Double = 60) -> HandsEnvelope {
        guard remoteHost == nil else {
            return .failure(HandsError(.badArguments, "agent commands run on this Mac only", suggestion: "Run `baneyspaces agent …` on the machine whose apps you want to drive.", retry: .never))
        }
        guard let data = try? JSONEncoder().encode(request), let text = String(data: data, encoding: .utf8) else {
            return .failure(HandsError(.badArguments, "couldn't encode the request", suggestion: "Check the arguments.", retry: .never))
        }
        guard let reply = Wire.call(Wire.Request(op: .hands, text: text), timeout: timeout) else {
            return .failure(HandsError(.notRunning, "BaneySpaces isn't running, or hasn't finished starting (it needs Accessibility)",
                                       suggestion: "Open BaneySpaces and run `baneyspaces doctor`.", retry: .safe))
        }
        if let line = reply.info?["envelope"], let env = HandsEnvelope.decode(line) { return env }
        return .failure(HandsError(.engineError, reply.error ?? "the app answered without a result", suggestion: "Update BaneySpaces and try again.", retry: .never))
    }

    /// `agent lend <app|pid> [--for 30m] [--session ID]` and `agent return [app]`: Donovan's, never an agent's.
    /// Both need a terminal on stdin and stdout, and a lend asks him to type the app's name. The app does the
    /// real checks (in use, named by pid and window ids, 30 minutes by default); an agent's tool call has no
    /// terminal, and the MCP server has no lend tool at all.
    static func lendOrReturn(_ words: [String]) -> Never {
        let verb = words[0]
        var rest = Array(words.dropFirst())
        var duration: String?, session = ""
        if let i = rest.firstIndex(of: "--for"), i + 1 < rest.count { duration = rest[i + 1]; rest.removeSubrange(i...(i + 1)) }
        if let i = rest.firstIndex(of: "--session"), i + 1 < rest.count { session = rest[i + 1]; rest.removeSubrange(i...(i + 1)) }
        let app = rest.first
        func finish(_ env: HandsEnvelope) -> Never { print(env.line); exit(env.ok ? 0 : 1) }
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else { finish(.failure(HandsParse.askedForLend(app))) }
        if verb == "lend" {
            guard let app else { finish(.failure(HandsError(.badArguments, "say which app", suggestion: "usage: baneyspaces agent lend <app|pid> [--for 30m]", retry: .safe))) }
            FileHandle.standardError.write(Data("Let agents use \(app) for \(duration ?? "30m")? They can read and act on its windows until you return it. Type its name to confirm: ".utf8))
            guard let answer = readLine(), answer.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(app) == .orderedSame else {
                finish(.failure(HandsError(.permissionDenied, "not confirmed", suggestion: "Nothing was lent.", retry: .never)))
            }
        }
        let args = verb == "lend" ? [app ?? "", duration ?? "", session] : (app.map { [$0] } ?? [])
        guard let reply = Wire.call(Wire.Request(op: .agent, text: verb, args: args), timeout: 15) else {
            finish(.failure(HandsError(.notRunning, "BaneySpaces isn't running", suggestion: "Open BaneySpaces and run `baneyspaces doctor`.", retry: .safe)))
        }
        if let line = reply.info?["envelope"], let env = HandsEnvelope.decode(line) { finish(env) }
        finish(.failure(HandsError(.engineError, reply.error ?? "no answer", suggestion: "Update BaneySpaces and try again.", retry: .never)))
    }

    static func run(_ words: [String]) -> Never {
        switch HandsParse.command(words, session: defaultSession()) {
        case .failure(let e):
            print(HandsEnvelope.failure(e).line)
            exit(2)
        case .success(let req):
            let env = send(req)
            print(env.line)
            exit(env.ok ? 0 : 1)
        }
    }
}

/// `baneyspaces mcp`: a stdio MCP server, so `claude mcp add baneyspaces -- baneyspaces mcp` gives an agent
/// the same tools (no lend: that is Donovan's).
enum MCPCommand {
    static func run() -> Never {
        let session = "mcp:\(getpid())"
        let version = Wire.call(Wire.Request(op: .ping), timeout: 1)?.info?["version"] ?? "dev"
        let server = HandsMCP(version: version, session: session,
                              perform: { HandsCLI.send($0) },
                              readImage: { FileManager.default.contents(atPath: $0) })
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let reply = server.handle(line) { print(reply); fflush(stdout) }
        }
        exit(0)
    }
}
