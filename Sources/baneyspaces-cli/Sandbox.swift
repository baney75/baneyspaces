import BaneySpacesCore
import Foundation

/// `baneyspaces sandbox up|down|reset|status|view|guest|images`. Goes to the running app over the deck
/// socket. `--local` runs the same code in this process with no app (headless only, no window), which
/// is how `scripts/sandbox-probe.swift` runs: `--local probe` is up, reset x3 and down, timed.
enum SandboxCommand {
    static func run(_ args: [String]) -> Never {
        var rest = args
        let local = rest.contains("--local")
        rest.removeAll { $0 == "--local" }
        let verb = rest.first ?? "status"
        if verb == "help" { print(SandboxService.usage + "\n  --local: run here, not in the app (no window; the app must not be running the sandbox)"); exit(0) }
        if local { runLocal(verb, Array(rest.dropFirst())) }
        let long = ["up", "reset", "down", "view", "images"].contains(verb)
        let req = Wire.Request(op: .sandbox, text: verb, args: Array(rest.dropFirst()))
        guard let reply = Wire.call(req, timeout: long ? 900 : 60) else {
            FileHandle.standardError.write(Data("BaneySpaces isn't running, or hasn't finished starting. (--local runs the sandbox without the app.)\n".utf8))
            exit(1)
        }
        finish(reply)
    }

    static func finish(_ reply: Wire.Reply) -> Never {
        if let json = reply.info?["json"] { print(json) }
        if !reply.ok {
            if reply.info?["json"] == nil { FileHandle.standardError.write(Data(((reply.error ?? "failed") + "\n").utf8)) }
            exit(1)
        }
        exit(0)
    }

    static func runLocal(_ verb: String, _ args: [String]) -> Never {
        // Local runs have no Settings: the sandbox is on, sized by --memory and --cpus.
        let mem = args.firstIndex(of: "--memory").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 4
        let cpu = args.firstIndex(of: "--cpus").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 4
        let cfg = SandboxSettings(enabled: true, memoryGB: mem, cpus: cpu)
        let (service, tart) = SandboxSystem.make(settings: { cfg })
        if verb == "view" { FileHandle.standardError.write(Data("view needs the app: it places the window on the agent workspace\n".utf8)); exit(2) }
        if verb == "probe" {
            let resets = args.firstIndex(of: "--resets").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 3
            let report = SandboxProbe.run(manager: service.manager, tart: tart, resets: resets, clock: SystemClock(),
                                          log: { print($0); fflush(stdout) })
            service.manager.shutdown() // the warm clone goes too: the probe leaves nothing behind
            let left = (try? tart.leftovers()) ?? ["?"]
            print("leftover bsx-* VMs: \(left.isEmpty ? "none" : left.joined(separator: ", "))")
            print(report.passed && left.isEmpty ? "sandbox-probe PASS" : "sandbox-probe FAIL")
            exit(report.passed && left.isEmpty ? 0 : 1)
        }
        // One process, one lifecycle: a lone `up` here would end with the process, so up, down and
        // reset make sense only inside `probe` (or through the app).
        if ["up", "down", "reset"].contains(verb) {
            FileHandle.standardError.write(Data("--local runs one self-contained sequence: use `sandbox --local probe`, or drop --local to use the app\n".utf8))
            exit(2)
        }
        let reply = service.handle(Wire.Request(op: .sandbox, text: verb, args: args))
        finish(reply)
    }
}
