import BaneySpacesCore
import Darwin
import Foundation

// `baneyspaces`: the command line side of BaneySpaces' Deck, for you, for agents and for hooks.
// Foundation only, no AppKit, so a hook costs a few milliseconds. Talks to the running app over
// its socket. Also installed as `ghostdeck`, the Deck's old name.

let me = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "baneyspaces"

let usage = """
usage: \(me) <command>

  ls [--json]                 everything the Deck wraps: terminals, agents, browser tabs
  focus <id | words>          bring it forward (an ID from ls, or a fuzzy search)
  open <url>                  open in your default browser
  send <id | words> <text>    type text into a Ghostty terminal, as if pasted
  notify [message]            flag the terminal this runs in as needing you
  layout free|stack|split     how wrapped windows sit beside the docked sidebar
  tile | sidebar | palette    tile windows, toggle the sidebar, open the switcher
  state                       the Deck's live state as JSON
  agent status|on [N]|off     the agent workspace: agents drive apps there while you work here
  agent open <app> [file…]    open an app (or files in it) there, without switching you
  agent run [--dir D] -- CMD  run a command (claude, grok…) in a Ghostty window there
  agent move <id | words>     send a row's window there
  phone ls|ui|shot|tap|swipe|type|key|shell|mirror   phones for agents (phone help)
  remote on|off|status|token  let your other machines (tailnet only) send agent work here
  --on HOST <command>         run ls or agent status|open|run on another machine
  hook claude|grok            for agent hooks: reads the hook JSON on stdin
  event --state S [--agent A] [--session ID] [--cwd DIR] [--message M]
                              report any agent's state (working, waiting, idle, end)
  hooks install|uninstall|status   Claude Code and Grok hooks
  skill install               the agent skill into ~/.claude/skills/baneyspaces
  doctor                      what's working and what isn't
"""

func fail(_ msg: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

func out(_ s: String) { print(s) }

/// The controlling terminal of this process ("/dev/ttys004"), or "".
func controllingTTY() -> String {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return "" }
    let dev = info.kp_eproc.e_tdev
    guard dev != -1, dev != 0, let name = devname(dev, S_IFCHR) else { return "" }
    return "/dev/" + String(cString: name)
}

/// The app this runs under: macOS sets it for every process an app starts (Ghostty, Grok Bot…).
var launchingApp: String { ProcessInfo.processInfo.environment["__CFBundleIdentifier"] ?? "" }

/// `--on HOST`: send the command to BaneySpaces on another machine on your tailnet.
var remoteHost: String?

/// The token for `host`: $BANEYSPACES_TOKEN, or ~/.config/baneyspaces/remotes.json ({"host": "token"}).
func remoteToken(_ host: String) -> String? {
    if let t = ProcessInfo.processInfo.environment["BANEYSPACES_TOKEN"], !t.isEmpty { return t }
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/baneyspaces/remotes.json")
    guard let d = FileManager.default.contents(atPath: url.path),
          let map = (try? JSONSerialization.jsonObject(with: d)) as? [String: String] else { return nil }
    return map[host]
}

func call(_ r: Wire.Request, timeout: Double = 2) -> Wire.Reply {
    if let host = remoteHost {
        guard let token = remoteToken(host) else {
            fail("no token for \(host): run `baneyspaces remote token` there, then put it in ~/.config/baneyspaces/remotes.json as {\"\(host)\": \"…\"} or in $BANEYSPACES_TOKEN")
        }
        var r = r
        r.token = token
        guard let reply = Wire.callRemote(host: host, r, timeout: max(timeout, 5)) else { fail("\(host) didn't answer: is BaneySpaces running there with `baneyspaces remote on`?") }
        if !reply.ok { fail(reply.error ?? "failed") }
        return reply
    }
    guard let reply = Wire.call(r, timeout: timeout) else { fail("BaneySpaces isn't running, or its Deck is off.") }
    if !reply.ok { fail(reply.error ?? "failed") }
    return reply
}

func flag(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

var argv = Array(CommandLine.arguments.dropFirst())
// Only in front of the command: `agent run -- tool --on staging` is the tool's own flag.
if argv.first == "--on", argv.count > 1 {
    remoteHost = argv[1]
    argv.removeFirst(2)
}
let args = argv
guard let cmd = args.first else { out(usage); exit(0) }
let rest = Array(args.dropFirst())

switch cmd {
case "ls", "list":
    let items = call(Wire.Request(op: .list)).items ?? []
    if rest.contains("--json") {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        out(String(data: try! enc.encode(items), encoding: .utf8)!)
    } else {
        for i in items {
            let mark = i.focused ? "*" : " "
            let state = i.activity == .shell ? "" : "[\(i.activity)] "
            let detail = i.detail.isEmpty ? "" : "  — \(i.detail)"
            let ws = i.workspace > 0 ? "  (workspace \(i.workspace))" : ""
            out("\(mark) \(i.id)\t\(i.appName)\t\(state)\(i.label)\(detail)\(ws)")
        }
    }

case "focus", "go":
    guard !rest.isEmpty else { fail("usage: \(me) focus <id | words>", code: 2) }
    let r = call(Wire.Request(op: .focus, target: rest.joined(separator: " ")))
    if let label = r.info?["label"] { out("→ \(label)") }

case "open":
    guard let url = rest.first else { fail("usage: \(me) open <url>", code: 2) }
    _ = call(Wire.Request(op: .open, target: url))

case "send":
    guard rest.count >= 2 else { fail("usage: \(me) send <id | words> <text>", code: 2) }
    _ = call(Wire.Request(op: .send, target: rest[0], text: rest.dropFirst().joined(separator: " ")))

case "notify":
    let tty = controllingTTY()
    let ev = AgentEvent(agent: "notify", session: tty.isEmpty ? UUID().uuidString : tty,
                        cwd: FileManager.default.currentDirectoryPath, tty: tty, app: launchingApp, state: .waiting,
                        message: rest.joined(separator: " "), at: Date().timeIntervalSince1970)
    _ = call(Wire.Request(op: .notify, text: rest.joined(separator: " "), event: ev))

case "layout":
    guard let l = rest.first, Deck.Layout(rawValue: l) != nil else { fail("usage: \(me) layout free|stack|split", code: 2) }
    _ = call(Wire.Request(op: .layout, text: l))

case "tile": _ = call(Wire.Request(op: .tile))
case "sidebar": _ = call(Wire.Request(op: .sidebar))
case "palette": _ = call(Wire.Request(op: .palette))

case "state":
    guard let d = FileManager.default.contents(atPath: Wire.statePath) else { fail("no state yet: is the Deck on?") }
    out(String(data: d, encoding: .utf8) ?? "")

case "remote":
    // Local only: whether other machines on your tailnet can send work here.
    guard remoteHost == nil else { fail("remote is set on each machine itself", code: 2) }
    let sub = rest.first ?? "status"
    guard ["on", "off", "status", "token"].contains(sub) else { fail("usage: \(me) remote on|off|status|token", code: 2) }
    let r = call(Wire.Request(op: .remote, text: sub))
    let info = r.info ?? [:]
    if sub == "token" { out(info["token"] ?? ""); break }
    out("remote: \(info["remote"] ?? "?")" + (info["listening"].map { " (\($0))" } ?? ""))

case "phone", "phones":
    PhoneCommand.run(rest)

case "agent":
    // The agent workspace: agents work there while you work here.
    let sub = rest.first ?? "status"
    let r = call(Wire.Request(op: .agent, text: sub, args: Array(rest.dropFirst())))
    let info = r.info ?? [:]
    if rest.contains("--json") {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        struct Out: Encodable { let info: [String: String]; let items: [Item] }
        out(String(data: try! enc.encode(Out(info: info, items: r.items ?? [])), encoding: .utf8)!)
    } else if sub == "status" || sub == "on" {
        guard let ws = info["workspace"], ws != "off" else { out("agent workspace: off (baneyspaces agent on [N])"); break }
        out("agent workspace: \(ws) (you're on \(info["current"] ?? "?"))")
        let wins = info.filter { $0.key.hasPrefix("window.") }.sorted { $0.key < $1.key }.map(\.value)
        out(wins.isEmpty ? "  no windows there yet" : wins.map { "  " + $0 }.joined(separator: "\n"))
    } else {
        out(info.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
    }

case "hook":
    // Never slow an agent down or fail its turn: short timeout, no output, always exit 0.
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let agent = rest.first ?? "claude"
    if ["claude", "grok"].contains(agent),
       let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
       let ev = AgentEvent.hook(json, agent: agent, tty: controllingTTY(), app: launchingApp, at: Date().timeIntervalSince1970) {
        _ = Wire.call(Wire.Request(op: .event, event: ev), timeout: 0.3)
    }
    exit(0)

case "event":
    guard let s = flag("--state", in: rest), let state = AgentEvent.State(rawValue: s) else {
        fail("usage: \(me) event --state working|waiting|idle|end [--agent A] [--session ID] [--cwd DIR] [--message M]", code: 2)
    }
    let tty = controllingTTY()
    let ev = AgentEvent(agent: flag("--agent", in: rest) ?? "agent",
                        session: flag("--session", in: rest) ?? (tty.isEmpty ? "default" : tty),
                        cwd: flag("--cwd", in: rest) ?? FileManager.default.currentDirectoryPath,
                        tty: tty, app: launchingApp, state: state, message: flag("--message", in: rest) ?? "",
                        at: Date().timeIntervalSince1970)
    _ = Wire.call(Wire.Request(op: .event, event: ev), timeout: 0.5)

case "hooks":
    switch rest.first {
    case "install": out(Hooks.install())
    case "uninstall": out(Hooks.uninstall())
    case "status", nil: out(Hooks.status())
    default: fail("usage: \(me) hooks install|uninstall|status", code: 2)
    }

case "skill":
    guard rest.first == "install" else { fail("usage: \(me) skill install", code: 2) }
    out(Skill.install())

case "doctor":
    let reply = Wire.call(Wire.Request(op: .ping), timeout: 1)
    out("deck:   " + (reply?.ok == true ? "running (\(reply?.info?["version"] ?? "?"))" : "not running"))
    for (k, v) in (reply?.info ?? [:]).sorted(by: { $0.key < $1.key }) where k != "version" { out("  \(k): \(v)") }
    out("hooks:  " + Hooks.status())
    out("skill:  " + (FileManager.default.fileExists(atPath: Skill.dest.path) ? "installed at \(Skill.dest.path)" : "not installed (\(me) skill install)"))

case "-h", "--help", "help": out(usage)
default: fail(usage, code: 2)
}
