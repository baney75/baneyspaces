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
    static func send(_ request: HandsRequest, timeout: Double = 180) -> HandsEnvelope {
        guard remoteHost == nil else {
            return .failure(HandsError(.badArguments, "agent commands run on this Mac only", suggestion: "Run `baneyspaces agent …` on the machine whose apps you want to drive.", retry: .never))
        }
        guard let data = try? JSONEncoder().encode(request), let text = String(data: data, encoding: .utf8) else {
            return .failure(HandsError(.badArguments, "couldn't encode the request", suggestion: "Check the arguments.", retry: .never))
        }
        guard let reply = Wire.call(Wire.Request(op: .hands, text: text), timeout: timeout) else {
            // The socket is there but the answer didn't come in time: the action may have landed.
            if Wire.socketCandidates().contains(where: { FileManager.default.fileExists(atPath: $0) }) {
                let acts = HandsTools.tool(verb: request.verb)?.acts ?? false
                return .failure(HandsError(.timeout, "BaneySpaces didn't answer in time", suggestion: acts
                    ? "The action may have landed: read the element back with `baneyspaces agent get` before trying again."
                    : "Try again in a moment.", retry: acts ? .never : .safe))
            }
            return .failure(HandsError(.notRunning, "BaneySpaces isn't running, or hasn't finished starting (it needs Accessibility)",
                                       suggestion: "Open BaneySpaces and run `baneyspaces doctor`.", retry: .safe))
        }
        if let line = reply.info?["envelope"], let env = HandsEnvelope.decode(line) { return env }
        return .failure(HandsError(.engineError, reply.error ?? "the app answered without a result", suggestion: "Update BaneySpaces and try again.", retry: .never))
    }

    /// `agent lend <app|pid> [--for 30m] [--session ID]`: asks. It sends a request to the app, which shows Donovan
    /// a sheet; only a real click on "Lend" in BaneySpaces lends anything, so running this (or an agent running
    /// it) lends nothing by itself. There is no terminal check: a program can fake one, and nothing here decides.
    /// `agent return` does not exist as a command: ask again to be offered "Take Back", or let the time run out.
    static func lendOrReturn(_ words: [String]) -> Never {
        var rest = Array(words.dropFirst())
        var duration: String?, session = ""
        if let i = rest.firstIndex(of: "--for"), i + 1 < rest.count { duration = rest[i + 1]; rest.removeSubrange(i...(i + 1)) }
        if let i = rest.firstIndex(of: "--session"), i + 1 < rest.count { session = rest[i + 1]; rest.removeSubrange(i...(i + 1)) }
        func finish(_ env: HandsEnvelope) -> Never { print(env.line); exit(env.ok ? 0 : 1) }
        guard words[0] == "lend" else {
            finish(.failure(HandsError(.needsLend, "returning an app is Donovan's, in BaneySpaces",
                                       suggestion: "Run `baneyspaces agent lend <app>` and choose Take Back in the sheet, or let the lend run out (30 minutes).", retry: .never)))
        }
        guard let app = rest.first else { finish(.failure(HandsError(.badArguments, "say which app", suggestion: "usage: baneyspaces agent lend <app|pid> [--for 30m]", retry: .safe))) }
        FileHandle.standardError.write(Data("Asking Donovan in BaneySpaces to let agents use \(app)…\n".utf8))
        guard let reply = Wire.call(Wire.Request(op: .agent, text: "lend-ask", args: [app, duration ?? "", session]), timeout: 90) else {
            finish(.failure(HandsError(.notRunning, "BaneySpaces isn't running, or didn't answer", suggestion: "Open BaneySpaces and run `baneyspaces doctor`.", retry: .safe)))
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
