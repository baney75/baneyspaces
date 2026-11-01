#!/usr/bin/env swift
// Proves the agent hands never change what you see: opens TextEdit and Calculator on the agent
// workspace with `baneyspaces agent open`, does 200 mixed actions through the CLI, and samples every
// 50 ms the frontmost app, BaneySpaces' current workspace (state.json), the pointer location and the
// frontmost window. PASS needs zero changes to all four, zero stray windows, every open and snapshot to
// work, and at least 90 successful mutating actions: a skipped or failed edit is a failure, never swapped
// for a read.
//
//   swift scripts/agent-hands-probe.swift           (needs BaneySpaces installed and the agent workspace on)
//   swift scripts/agent-hands-probe.swift --force   (skip the idle check: for a Mac nobody is using)
//
// It refuses to run unless you have been idle for 10 minutes: any key or mouse move of yours is a
// "change" it can't tell from the hands'. A new window of those apps on any workspace but the agent's
// counts as a failure too (a "stray window"). Actions write only into a temporary TextEdit document in the
// agent handoff folder; Calculator gets reads and button clicks. Never Finder, Notes or
// any once-per-user app.
import AppKit
import Foundation

let force = CommandLine.arguments.contains("--force")
let home = FileManager.default.homeDirectoryForCurrentUser
let cli = home.appendingPathComponent(".local/bin/baneyspaces").path
let statePath = home.appendingPathComponent("Library/Application Support/BaneySpaces/state.json").path

func idleSeconds() -> Double {
    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
}
if !force && idleSeconds() < 600 {
    print("untested live: you were active \(Int(idleSeconds())) s ago; the probe needs 10 idle minutes (or --force on an unused Mac)")
    exit(3)
}

func agent(_ args: [String]) -> [String: Any] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cli)
    p.arguments = ["agent"] + args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    try? p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? ["ok": false]
}
func isOK(_ r: [String: Any]) -> Bool { (r["ok"] as? Bool) == true }
func data(_ r: [String: Any]) -> [String: Any] { r["data"] as? [String: Any] ?? [:] }

let probedApps: Set<String> = ["TextEdit", "Calculator"]
struct Sample: Equatable {
    var front: pid_t
    var workspace: Int
    var pointer: CGPoint
    var keyWindow: Int
    /// Windows of the probed apps that are on a workspace other than the agent's.
    var strays: Set<Int>
}
func sample() -> Sample {
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
    var current = -1
    var strays: Set<Int> = []
    if let d = FileManager.default.contents(atPath: statePath), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
        current = j["current"] as? Int ?? -1
        let agentWS = j["agentWorkspace"] as? Int ?? 0
        for (ws, list) in j["workspaces"] as? [String: [[String: Any]]] ?? [:] where Int(ws) != agentWS {
            for w in list where probedApps.contains(w["app"] as? String ?? "") { if let id = w["id"] as? Int { strays.insert(id) } }
        }
    }
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let top = list.first { ($0[kCGWindowLayer as String] as? Int) == 0 }?[kCGWindowNumber as String] as? Int ?? -1
    return Sample(front: front, workspace: current, pointer: NSEvent.mouseLocation, keyWindow: top, strays: strays)
}

let baseline = sample()
var changes: [String] = []
var failures: [String] = []
var samples = 0
let lock = NSLock()
var running = true
let sampler = Thread {
    var last = baseline
    while true {
        lock.lock(); let go = running; lock.unlock()
        if !go { break }
        let s = sample()
        samples += 1
        if s != last {
            if s.front != last.front { changes.append("front app \(last.front) -> \(s.front)") }
            if s.workspace != last.workspace { changes.append("workspace \(last.workspace) -> \(s.workspace)") }
            if s.pointer != last.pointer { changes.append("pointer \(last.pointer) -> \(s.pointer)") }
            if s.keyWindow != last.keyWindow { changes.append("key window \(last.keyWindow) -> \(s.keyWindow)") }
            // A window of an app we opened that shows up anywhere but the agent workspace is a failure,
            // even one that was moved away a moment later (the user saw it).
            for id in s.strays.subtracting(baseline.strays).subtracting(last.strays) { changes.append("stray window \(id) on a non-agent workspace") }
            last = s
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
}
sampler.start()

// A temporary folder in the agent handoff folder: a text file for TextEdit.
let handoff = home.appendingPathComponent("Library/Application Support/BaneySpaces/hands/handoff")
let dir = handoff.appendingPathComponent("probe-\(Int(Date().timeIntervalSince1970))")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let doc = dir.appendingPathComponent("notes.txt")
FileManager.default.createFile(atPath: doc.path, contents: Data("probe\n".utf8))
defer { try? FileManager.default.removeItem(at: dir) }

var windows: [String: Int] = [:]
for (app, target) in [("TextEdit", doc.path), ("Calculator", "")] {
    let r = agent(target.isEmpty ? ["open", app] : ["open", app, target])
    if let w = data(r)["window"] as? Int { windows[app] = w } else { failures.append("open \(app) gave no window: \(r)") }
    Thread.sleep(forTimeInterval: 0.5)
}

// Nothing but what we handed over may be open: a window of these apps showing anything else was restored
// from the user's own documents, and the probe fails on it.
if let list = data(agent(["windows"]))["windows"] as? [[String: Any]] {
    for w in list where probedApps.contains(w["app"] as? String ?? "") {
        let title = (w["title"] as? String ?? "").lowercased()
        if !(title.contains("notes") || title.contains("calculator")) { failures.append("restored window \(w["id"] ?? "?") (\(title)) is not what we opened") }
    }
}

func refs(_ node: Any?, into out: inout [[String: Any]]) {
    guard let n = node as? [String: Any] else { return }
    if n["ref_id"] != nil { out.append(n) }
    for c in n["children"] as? [Any] ?? [] { refs(c, into: &out) }
}
func snapshot(_ app: String) -> [[String: Any]] {
    guard let w = windows[app] else { return [] }
    var out: [[String: Any]] = []
    refs(data(agent(["snapshot", "--window", String(w), "-i"]))["tree"], into: &out)
    if out.isEmpty { failures.append("snapshot of \(app) returned no refs") }
    return out
}
func first(_ nodes: [[String: Any]], role: String, name: String? = nil) -> String? {
    nodes.first { ($0["role"] as? String) == role && (name == nil || ($0["name"] as? String) == name) }?["ref_id"] as? String
}

var ok = 0, total = 0, mutatingOK = 0, mutatingTotal = 0, unverified = 0
func run(_ args: [String], mutating: Bool) {
    total += 1
    if mutating { mutatingTotal += 1 }
    let r = agent(args)
    guard isOK(r) else { return }
    ok += 1
    // A mutation counts only when the result says it was verified (value or state read back, or the tree changed).
    if mutating {
        if data(r)["verified"] as? Bool == true { mutatingOK += 1 } else { unverified += 1 }
    }
}
/// An action whose ref is missing counts as a failed action: it is never replaced by a read.
func missing(mutating: Bool) { total += 1; if mutating { mutatingTotal += 1 } }

var te = snapshot("TextEdit"), fi = snapshot("Calculator")
var text = first(te, role: "textfield"), bold = first(te, role: "checkbox", name: "bold"), area = first(te, role: "scrollarea")
if text == nil { failures.append("TextEdit has no text field ref") }
if bold == nil { failures.append("TextEdit has no bold checkbox ref") }
var i = 0
while total < 200 && failures.isEmpty {
    if i % 40 == 39 {
        te = snapshot("TextEdit"); fi = snapshot("Calculator")
        text = first(te, role: "textfield"); bold = first(te, role: "checkbox", name: "bold"); area = first(te, role: "scrollarea")
    }
    switch i % 10 {
    case 0, 9: if let t = text { run(["type", t, "ab"], mutating: true) } else { missing(mutating: true) }
    case 1: if let t = text { run(["set-value", t, "line \(i)"], mutating: true) } else { missing(mutating: true) }
    case 2: if let b = bold { run(["toggle", b], mutating: true) } else { missing(mutating: true) }
    case 3: if let b = bold { run(["click", b], mutating: true) } else { missing(mutating: true) }
    case 4: if let t = text { run(["get", t, "value"], mutating: false) } else { missing(mutating: false) }
    case 5: if let w = windows["TextEdit"] { run(["find", "--window", String(w), "--role", "checkbox"], mutating: false) } else { missing(mutating: false) }
    case 6: if let w = windows["Calculator"] { run(["find", "--window", String(w), "--role", "button"], mutating: false) } else { missing(mutating: false) }
    case 7: if let w = windows["Calculator"] { run(["snapshot", "--window", String(w), "-i"], mutating: false) } else { missing(mutating: false) }
    default: if let a = area { run(["scroll", a, "down"], mutating: false) } else { missing(mutating: false) }
    }
    i += 1
}
Thread.sleep(forTimeInterval: 1.8)   // late activations arrive after the last action
lock.lock(); running = false; lock.unlock()
Thread.sleep(forTimeInterval: 0.2)

let needed = 90
if mutatingOK < needed { failures.append("only \(mutatingOK) mutating actions succeeded and were verified (\(needed) needed, \(mutatingTotal) tried)") }
print("samples: \(samples) (every 50 ms), actions: \(total), succeeded: \(ok), mutating verified: \(mutatingOK)/\(mutatingTotal), delivered but unverified: \(unverified)")
failures.forEach { print("fail: \($0)") }
changes.prefix(20).forEach { print("change: \($0)") }
if changes.isEmpty && failures.isEmpty {
    print("PASS: zero changes to the front app, the workspace, the pointer and the front window, no stray window; \(mutatingOK) mutating actions succeeded (\(ok)/\(total) in all)")
} else {
    print("FAIL: \(changes.count) change(s), \(failures.count) failed requirement(s)")
    exit(1)
}
