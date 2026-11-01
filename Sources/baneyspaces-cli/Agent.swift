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

    static func run(_ words: [String]) -> Never {
        switch HandsParse.command(words, session: defaultSession()) {
        case .failure(let e):
            print(HandsEnvelope.failure(e).line)
            exit(2)
        case .success(var req):
            if req.verb == "lend", req.args["session"] == nil { req.args["session"] = .string(defaultSession()) }
            let env = send(req)
            print(env.line)
            exit(env.ok ? 0 : 1)
        }
    }
}

/// `baneyspaces mcp`: a stdio MCP server, so `claude mcp add baneyspaces -- baneyspaces mcp` gives an agent
/// the same tools. When the client goes away, everything lent to it goes back.
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
        _ = HandsCLI.send(HandsRequest(verb: "return", args: ["all": true], session: session), timeout: 5)
        exit(0)
    }
}
