#!/usr/bin/env swift
// Proves the agent hands never change what you see: opens TextEdit, Finder and Notes on the agent
// workspace with `baneyspaces agent open`, does 200 mixed actions through the CLI, and samples every
// 50 ms the frontmost app, BaneySpaces' current workspace (state.json), the pointer location and the
// frontmost window. PASS only with zero changes to all four; it also prints how many actions succeeded.
//
//   swift scripts/agent-hands-probe.swift           (needs BaneySpaces installed and the agent workspace on)
//   swift scripts/agent-hands-probe.swift --force   (skip the idle check: for a Mac nobody is using)
//
// It refuses to run unless you have been idle for 10 minutes: any key or mouse move of yours is a
// "change" it can't tell from the hands'. A new window of those apps on any workspace but the agent's
// counts as a failure too (a "stray window"). Actions write only into a new TextEdit document; Finder and
// Notes get reads and scrolls, never edits.
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

struct Sample: Equatable {
    var front: pid_t
    var workspace: Int
    var pointer: CGPoint
    var keyWindow: Int
    /// Windows of the probed apps that are on a workspace other than the agent's.
    var strays: Set<Int>
}
let probedApps: Set<String> = ["TextEdit", "Finder", "Notes"]
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

// Open the three apps on the agent workspace.
var windows: [String: Int] = [:]
for app in ["TextEdit", "Finder", "Notes"] {
    let r = agent(["open", app])
    if let w = data(r)["window"] as? Int { windows[app] = w } else { print("note: no window id for \(app): \(r)") }
    Thread.sleep(forTimeInterval: 0.5)
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
    return out
}
func first(_ nodes: [[String: Any]], role: String, name: String? = nil) -> String? {
    nodes.first { ($0["role"] as? String) == role && (name == nil || ($0["name"] as? String) == name) }?["ref_id"] as? String
}

var ok = 0, total = 0
func run(_ args: [String]) {
    total += 1
    if isOK(agent(args)) { ok += 1 }
}

var te = snapshot("TextEdit"), fi = snapshot("Finder"), no = snapshot("Notes")
while total < 200 {
    let i = total
    if i % 25 == 0 { te = snapshot("TextEdit"); fi = snapshot("Finder"); no = snapshot("Notes"); total += 3; ok += (te.isEmpty ? 0 : 1) + (fi.isEmpty ? 0 : 1) + (no.isEmpty ? 0 : 1) }
    let text = first(te, role: "textfield"), bold = first(te, role: "checkbox", name: "bold")
    switch i % 8 {
    case 0: if let t = text { run(["type", t, "ab"]) } else { run(["windows"]) }
    case 1: if let t = text { run(["set-value", t, "line \(i)"]) } else { run(["windows"]) }
    case 2: if let t = text { run(["get", t, "value"]) } else { run(["windows"]) }
    case 3: if let b = bold { run(["toggle", b]) } else { run(["windows"]) }
    case 4: if let w = windows["Finder"] { run(["find", "--window", String(w), "--role", "button"]) } else { run(["windows"]) }
    case 5: if let s = first(fi, role: "scrollarea") ?? first(no, role: "scrollarea") { run(["scroll", s, "down"]) } else { run(["windows"]) }
    case 6: if let w = windows["Notes"] { run(["find", "--window", String(w), "--role", "button"]) } else { run(["windows"]) }
    default: if let b = bold { run(["click", b]) } else { run(["windows"]) }
    }
}
Thread.sleep(forTimeInterval: 1.2)   // late activations arrive after the last action
lock.lock(); running = false; lock.unlock()
Thread.sleep(forTimeInterval: 0.2)

print("samples: \(samples) (every 50 ms), actions: \(total), succeeded: \(ok)")
if changes.isEmpty {
    print("PASS: zero changes to the front app, the workspace, the pointer and the front window; \(ok)/\(total) actions succeeded")
} else {
    changes.prefix(20).forEach { print("change: \($0)") }
    print("FAIL: \(changes.count) change(s)")
    exit(1)
}
