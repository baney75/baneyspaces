#!/usr/bin/env swift
// Phase 4 probe: keys and a pointer to agent windows that are not in front, by process, with delivery proof,
// without taking focus, raising anything or moving the real pointer.
//
//   swift scripts/agent-keys-probe.swift      (needs BaneySpaces installed with phase 4, and the agent workspace on)
//
// It runs only when you have been idle 10 minutes (`ioreg -c IOHIDSystem`, HIDIdleTime >= 600 s). Otherwise it
// prints "untested live" and exits 3. There is no flag that lowers the bar. It also exits 3 when the installed
// BaneySpaces predates phase 4, when the agent workspace is off, or when you come back while it runs.
//
// What it does, all through `baneyspaces agent ...` on processes BaneySpaces starts (`agent open`):
//   1. TextEdit, with another app in front, one line of plain text: cmd+a then typing a replacement, option+Left and
//      shift+option+Right (the selected range read back through AXSelectedTextRange), Return making a new line; and, in an
//      RTF document, cmd+a then cmd+b checked through the text's attributes (and the saved file). Each answered
//      "verified" by BaneySpaces and then checked again here, by this probe's own reading of the same window.
//   2. The bench tasks marked phase 4 that these routes can run, replayed from bench/tasks/*.json: calculator-keys,
//      textedit-select-all-replace, textedit-bold-save-rtf. Each prints PASS or FAIL against the task's own check.
//      The others (textedit-save-sheet: a Save sheet is never driven; finder-*: Finder is once-per-user and
//      never started for an agent) print SKIP and why.
//   3. A canvas: the small test app built into the BaneySpaces bundle (Resources/probe, scripts/canvas-probe-app.swift) is
//      drawn on from behind with `drag` and `click-at`; the stroke is checked by pixels, from captures this probe makes itself.
//   4. Watching, the whole time, every 50 ms: the front app, BaneySpaces' current workspace, the real pointer,
//      the key window, and any window of the probed apps that shows on another workspace. Zero changes allowed.
//      A listen-only event tap also counts input: an event from anywhere but this probe or BaneySpaces' own
//      process is you coming back (the run stops), and any event BaneySpaces' process posts that reaches the
//      session is a failure: events must go to the one process.
import AppKit
import ApplicationServices
import Foundation

let home = FileManager.default.homeDirectoryForCurrentUser
let cli = home.appendingPathComponent(".local/bin/baneyspaces").path
let supportDir = home.appendingPathComponent("Library/Application Support/BaneySpaces")
let statePath = supportDir.appendingPathComponent("state.json").path
let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let benchTasks = scriptDir.deletingLastPathComponent().appendingPathComponent("bench/tasks")

var startedPids: [Int] = []
var runDir: URL?
/// Quits only the processes this run started and removes its folder. Called before every exit (exit skips `defer`).
func cleanup() {
    startedPids.forEach { kill(pid_t($0), SIGTERM) }
    startedPids = []
    if let d = runDir { try? FileManager.default.removeItem(at: d) }
}
func untested(_ why: String) -> Never {
    cleanup()
    print("untested live: \(why)")
    exit(3)
}

// MARK: the idle bar

func hidIdleSeconds() -> Double {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
    p.arguments = ["-c", "IOHIDSystem"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return 0 }
    let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    guard let r = text.range(of: #""HIDIdleTime" = \d+"#, options: .regularExpression),
          let n = Double(text[r].split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? "") else { return 0 }
    return n / 1_000_000_000
}
let idle = hidIdleSeconds()
if idle < 600 { untested("you were active \(Int(idle)) s ago; the probe needs 10 idle minutes (HIDIdleTime >= 600)") }
guard FileManager.default.isExecutableFile(atPath: cli) else { untested("\(cli) is not installed") }
guard AXIsProcessTrusted() else { untested("this terminal is not allowed Accessibility, which the probe needs to read AXSelectedTextRange") }

// MARK: talking to BaneySpaces

func agent(_ args: [String]) -> [String: Any] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cli)
    p.arguments = ["agent"] + args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return ["ok": false] }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? ["ok": false]
}
func isOK(_ r: [String: Any]) -> Bool { (r["ok"] as? Bool) == true }
func data(_ r: [String: Any]) -> [String: Any] { r["data"] as? [String: Any] ?? [:] }
func errorCode(_ r: [String: Any]) -> String { (r["error"] as? [String: Any])?["code"] as? String ?? "" }
func errorText(_ r: [String: Any]) -> String {
    let e = r["error"] as? [String: Any] ?? [:]
    return "\(e["code"] as? String ?? "?"): \(e["message"] as? String ?? "")"
}

// An installed build from before phase 4 answers "unknown agent command" for click-at.
let capability = agent(["click-at"])
if errorText(capability).contains("unknown agent command") { untested("the installed BaneySpaces predates phase 4 (no click-at); it runs on main after the merge") }
let windowsNow = agent(["windows"])
guard isOK(windowsNow), data(windowsNow)["agent_workspace"] is Int else { untested("the agent workspace is off (baneyspaces agent on) or BaneySpaces is not running") }

let probedBundles = ["TextEdit", "Calculator", "Canvas Probe", "CanvasProbe"]

// MARK: watching

struct Sample: Equatable {
    var front: pid_t
    var workspace: Int
    var pointer: CGPoint
    var keyWindow: Int
    var strays: Set<Int>
}
func pointerNow() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }
func sample() -> Sample {
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
    var current = -1
    var strays: Set<Int> = []
    if let d = FileManager.default.contents(atPath: statePath), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
        current = j["current"] as? Int ?? -1
        let agentWS = j["agentWorkspace"] as? Int ?? 0
        for (ws, list) in j["workspaces"] as? [String: [[String: Any]]] ?? [:] where Int(ws) != agentWS {
            for w in list where probedBundles.contains(w["app"] as? String ?? "") { if let id = w["id"] as? Int { strays.insert(id) } }
        }
    }
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let top = list.first { ($0[kCGWindowLayer as String] as? Int) == 0 }?[kCGWindowNumber as String] as? Int ?? -1
    return Sample(front: front, workspace: current, pointer: pointerNow(), keyWindow: top, strays: strays)
}

let baneySpacesPid: pid_t = NSWorkspace.shared.runningApplications.first { $0.bundleURL?.lastPathComponent == "BaneySpaces.app" }?.processIdentifier ?? -1
let lock = NSLock()
var running = true
var changes: [String] = []
var failures: [String] = []
var samples = 0
var inputFromElsewhere = 0
var leakedToSession = 0
var eventsSeen = 0

// A listen-only tap reads the source process of every key, mouse and scroll event in the session.
let eventMask: CGEventMask = [CGEventType.keyDown, .keyUp, .flagsChanged, .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                              .rightMouseDown, .rightMouseUp, .rightMouseDragged, .otherMouseDown, .otherMouseUp, .scrollWheel]
    .reduce(0) { $0 | (1 << $1.rawValue) }
let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: eventMask,
                            callback: { _, _, event, _ in
                                let source = pid_t(event.getIntegerValueField(.eventSourceUnixProcessID))
                                lock.lock()
                                eventsSeen += 1
                                if source == baneySpacesPid { leakedToSession += 1 }       // per-process posts must not reach the session
                                else if source != getpid() { inputFromElsewhere += 1 }      // hardware is pid 0: you are back
                                lock.unlock()
                                return Unmanaged.passUnretained(event)
                            }, userInfo: nil)
if let tap {
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    let t = Thread {
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        while true { lock.lock(); let go = running; lock.unlock(); if !go { break }; CFRunLoopRunInMode(.defaultMode, 0.1, false) }
    }
    t.start()
} else {
    print("note: no Input Monitoring for this terminal, so the tap is off; any HID activity during the run will stop it")
}

func aborted() -> Bool {
    lock.lock(); defer { lock.unlock() }
    if inputFromElsewhere > 0 { return true }
    return false
}

let baseline = sample()
let sampler = Thread {
    var last = baseline
    var lastIdle = hidIdleSeconds()
    var ticks = 0
    while true {
        lock.lock(); let go = running; lock.unlock()
        if !go { break }
        let s = sample()
        lock.lock(); samples += 1; lock.unlock()
        if s != last {
            lock.lock()
            if s.front != last.front { changes.append("front app \(last.front) -> \(s.front)") }
            if s.workspace != last.workspace { changes.append("workspace \(last.workspace) -> \(s.workspace)") }
            if s.pointer != last.pointer { changes.append("pointer \(last.pointer) -> \(s.pointer)") }
            if s.keyWindow != last.keyWindow { changes.append("key window \(last.keyWindow) -> \(s.keyWindow)") }
            for id in s.strays.subtracting(baseline.strays).subtracting(last.strays) { changes.append("stray window \(id) on a non-agent workspace") }
            lock.unlock()
            last = s
        }
        // Without the tap, a fall in HID idle time is the only sign of you coming back (checked about once a second).
        ticks += 1
        if tap == nil, ticks % 20 == 0 {
            let now = hidIdleSeconds()
            if now < lastIdle - 1 { lock.lock(); inputFromElsewhere += 1; lock.unlock() }
            lastIdle = now
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
}
sampler.start()

// MARK: fixtures

let handoff = supportDir.appendingPathComponent("hands/handoff")
let dir = handoff.appendingPathComponent("keys-probe-\(Int(Date().timeIntervalSince1970))")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
runDir = dir
let runDirURL = dir

let rtfBody = #"{\rtf1\ansi\ansicpg1252\cocoartf2700{\fonttbl\f0\fswiss Helvetica;}\f0\fs24 plain words to make bold\par}"#

func open(_ app: String, _ target: String? = nil) -> (window: Int, pid: Int)? {
    let r = agent(target.map { ["open", app, $0] } ?? ["open", app])
    guard isOK(r), let w = data(r)["window"] as? Int, let p = data(r)["pid"] as? Int else { failures.append("open \(app): \(errorText(r))"); return nil }
    startedPids.append(p)
    Thread.sleep(forTimeInterval: 0.8)
    return (w, p)
}
func quit(_ pid: Int) { kill(pid_t(pid), SIGTERM) }

struct Node { var ref: String; var role: String; var name: String; var value: String }
func nodes(_ window: Int, interactive: Bool = true) -> [Node] {
    var out: [Node] = []
    func walk(_ n: Any?) {
        guard let n = n as? [String: Any] else { return }
        if let ref = n["ref_id"] as? String {
            out.append(Node(ref: ref, role: (n["role"] as? String ?? "").lowercased(), name: n["name"] as? String ?? "", value: n["value"] as? String ?? ""))
        }
        for c in n["children"] as? [Any] ?? [] { walk(c) }
    }
    walk(data(agent(["snapshot", "--window", String(window)] + (interactive ? ["-i"] : [])))["tree"])
    return out
}
func canon(_ role: String) -> String { ["textarea": "textfield", "input": "textfield"][role] ?? role }

/// One `press`: the result line and whether it was verified.
@discardableResult
func press(_ ref: String, _ keys: String, label: String) -> Bool {
    if aborted() { return false }
    let r = agent(["press", ref, keys])
    if isOK(r), data(r)["verified"] as? Bool == true {
        let ev = data(r)["evidence"] as? [String: Any] ?? [:]
        print("  press \(keys): verified (\(ev["basis"] as? String ?? "?"), \(data(r)["transport"] as? String ?? "?"))")
        return true
    }
    failures.append("\(label): press \(keys) -> \(errorText(r))")
    print("  press \(keys): \(errorText(r))")
    return false
}
func value(_ ref: String) -> String { data(agent(["get", ref, "value"]))["value"] as? String ?? "" }

// MARK: 1. TextEdit, keys

func axCopy(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    var out: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, name as CFString, &out) == .success ? out : nil
}
/// The text element that has the keys in this process, read straight from accessibility.
func focusedElement(_ pid: Int) -> AXUIElement? {
    guard let f = axCopy(AXUIElementCreateApplication(pid_t(pid)), kAXFocusedUIElementAttribute) else { return nil }
    return (f as! AXUIElement)
}
func selectedRange(_ pid: Int) -> (Int, Int)? {
    guard let e = focusedElement(pid), let v = axCopy(e, kAXSelectedTextRangeAttribute) else { return nil }
    var r = CFRange()
    return AXValueGetValue(v as! AXValue, .cfRange, &r) ? (r.location, r.length) : nil
}
func focusedText(_ pid: Int) -> String? { focusedElement(pid).flatMap { axCopy($0, kAXValueAttribute) as? String } }
/// Whether any run of the focused text has a bold font, from its attributed string.
func hasBold(_ pid: Int) -> Bool {
    guard let e = focusedElement(pid), let text = focusedText(pid), !text.isEmpty else { return false }
    var range = CFRange(location: 0, length: text.utf16.count)
    guard let param = AXValueCreate(.cfRange, &range) else { return false }
    var out: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(e, kAXAttributedStringForRangeParameterizedAttribute as CFString, param, &out) == .success,
          let attributed = out as? NSAttributedString else { return false }
    var bold = false
    attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length), options: []) { attrs, _, _ in
        if "\(attrs)".contains("Bold") { bold = true }
    }
    return bold
}
func expect(_ label: String, _ ok: Bool) {
    print("  \(ok ? "ok  " : "FAIL") \(label)")
    if !ok { failures.append(label) }
}

print("TextEdit keys, one line of text (another app stays in front):")
if let (win, pid) = open("TextEdit", { () -> String in
    let f = runDirURL.appendingPathComponent("line.txt"); FileManager.default.createFile(atPath: f.path, contents: Data("alpha beta gamma".utf8)); return f.path }()) {
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid_t(pid) { untested("TextEdit came to the front on its own; nothing to prove from behind") }
    if let field = nodes(win).first(where: { canon($0.role) == "textfield" }) {
        var ok = true
        ok = press(field.ref, "cmd+a", label: "select all") && ok
        let all = selectedRange(pid)
        expect("cmd+a selects all 16 characters (AXSelectedTextRange \(all.map { "\($0.0),\($0.1)" } ?? "unreadable"))", all?.0 == 0 && all?.1 == 16)
        ok = press(field.ref, "n e w", label: "typing") && ok
        expect("typing replaced the selection: value is \"new\"", focusedText(pid) == "new")
        ok = press(field.ref, "alt+Left", label: "option-left") && ok
        let home = selectedRange(pid)
        expect("option+Left puts the caret at the start of the word (range \(home.map { "\($0.0),\($0.1)" } ?? "unreadable"))", home?.0 == 0 && home?.1 == 0)
        ok = press(field.ref, "shift+alt+Right", label: "shift-option-right") && ok
        let word = selectedRange(pid)
        expect("shift+option+Right selects the word (range \(word.map { "\($0.0),\($0.1)" } ?? "unreadable"))", word?.0 == 0 && word?.1 == 3)
        ok = press(field.ref, "Right", label: "collapse") && ok
        let end = selectedRange(pid)
        expect("Right collapses the selection to its end (range \(end.map { "\($0.0),\($0.1)" } ?? "unreadable"))", end?.0 == 3 && end?.1 == 0)
        ok = press(field.ref, "Return", label: "return") && ok
        expect("Return made a new line: value is \"new\\n\"", focusedText(pid) == "new\n")
        print("scenario keys-typing: \(ok ? "PASS" : "FAIL")")
    } else { failures.append("TextEdit has no text field ref") }
    quit(pid)
}

print("TextEdit bold, RTF (another app stays in front):")
if let (win, pid) = open("TextEdit", { () -> String in
    let f = runDirURL.appendingPathComponent("bold.rtf"); FileManager.default.createFile(atPath: f.path, contents: Data(rtfBody.utf8)); return f.path }()) {
    if let field = nodes(win).first(where: { canon($0.role) == "textfield" }) {
        let was = hasBold(pid)
        var ok = press(field.ref, "cmd+a", label: "bold: select all")
        ok = press(field.ref, "cmd+b", label: "bold: cmd+b") && ok
        let now = hasBold(pid)
        expect("cmd+b made the selected text bold, read through its attributes (was bold: \(was), now: \(now))", !was && now)
        print("scenario keys-bold: \(ok && !was && now ? "PASS" : "FAIL")")
    } else { failures.append("TextEdit (rtf) has no text field ref") }
    quit(pid)
}

// MARK: 2. The bench tasks marked phase 4

var taskResults: [(String, String)] = []

func tmpReplaced(_ s: String, _ dir: URL) -> String { s.replacingOccurrences(of: "{tmp}", with: dir.path) }

func runTask(_ id: String) {
    guard let d = FileManager.default.contents(atPath: benchTasks.appendingPathComponent("\(id).json").path),
          let task = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { taskResults.append((id, "SKIP (task file missing)")); return }
    let dir = runDirURL.appendingPathComponent(id)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let setup = task["setup"] as? [String: Any] ?? [:]
    for (name, spec) in setup["files"] as? [String: Any] ?? [:] {
        if let text = spec as? String { FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data(text.utf8)) }
        else if let o = spec as? [String: Any], o["rtf"] as? Bool == true { FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data(rtfBody.utf8)) }
    }
    var windows: [String: Int] = [:]
    var pids: [Int] = []
    for o in setup["open"] as? [[String: Any]] ?? [] {
        let app = o["app"] as? String ?? ""
        guard let alias = o["as"] as? String else { continue }
        if app == "Calculator", NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.apple.calculator" }) {
            taskResults.append((id, "SKIP (Calculator is already running; its settings are shared)")); return
        }
        let target = (o["targets"] as? [String])?.first.map { tmpReplaced($0, dir) }
        guard let (w, p) = open(app, target) else { taskResults.append((id, "FAIL (could not open \(app))")); return }
        windows[alias] = w; pids.append(p)
    }
    defer { pids.forEach(quit) }
    func refFor(_ step: [String: Any], _ window: Int) -> String? {
        let all = nodes(window)
        if let t = step["target"] as? [String: Any], let role = t["role"] as? String {
            return all.first { canon($0.role) == canon(role.lowercased()) }?.ref
        }
        return all.first { ["textfield", "table", "list", "scrollarea", "button", "outline"].contains(canon($0.role)) }?.ref
    }
    for step in task["steps"] as? [[String: Any]] ?? [] {
        if aborted() { taskResults.append((id, "ABORTED (you came back)")); return }
        switch step["do"] as? String ?? "" {
        case "wait": Thread.sleep(forTimeInterval: Double(step["ms"] as? Int ?? 0) / 1000)
        case "press":
            guard let alias = step["window"] as? String, let w = windows[alias], let ref = refFor(step, w) else { taskResults.append((id, "FAIL (no element to aim a key at)")); return }
            if !press(ref, step["key"] as? String ?? "", label: id) { taskResults.append((id, "FAIL (press refused or unverified)")); return }
        case "type":
            guard let alias = step["window"] as? String, let w = windows[alias], let ref = refFor(step, w) else { taskResults.append((id, "FAIL (no element)")); return }
            let r = agent(["type", ref, step["text"] as? String ?? ""])
            if !isOK(r) { taskResults.append((id, "FAIL (type: \(errorText(r)))")); return }
        default:
            taskResults.append((id, "SKIP (step \(step["do"] as? String ?? "?") is not covered by the probe's routes)")); return
        }
    }
    // The task's own check.
    let check = task["check"] as? [String: Any] ?? [:]
    switch check["kind"] as? String ?? "" {
    case "ax":
        guard let alias = check["window"] as? String, let w = windows[alias], let t = check["target"] as? [String: Any], let role = t["role"] as? String,
              let want = check["equals"] as? String else { taskResults.append((id, "SKIP (check not covered)")); return }
        let hit = nodes(w, interactive: false).contains { canon($0.role) == canon(role) && ($0.value == want || $0.name == want) }
        taskResults.append((id, hit ? "PASS" : "FAIL (\(role) never read \(want))"))
    case "file":
        let path = tmpReplaced(check["path"] as? String ?? "", dir)
        var pass = false
        for _ in 0..<10 {
            if let d = FileManager.default.contents(atPath: path), let text = String(data: d, encoding: .isoLatin1),
               let re = check["regex"] as? String, text.range(of: re, options: .regularExpression) != nil { pass = true; break }
            Thread.sleep(forTimeInterval: 0.3)
        }
        taskResults.append((id, pass ? "PASS" : "FAIL (\(path) never matched)"))
    default:
        taskResults.append((id, "SKIP (check kind not covered)"))
    }
}

print("bench tasks marked phase 4:")
for id in ["calculator-keys", "textedit-select-all-replace", "textedit-bold-save-rtf"] { runTask(id) }
taskResults.append(("textedit-save-sheet", "SKIP (the Save As sheet is never driven on this Mac; BaneySpaces refuses a window with a sheet)"))
for id in ["finder-go-to-folder-sheet", "finder-navigate-into-folder", "finder-new-folder-key", "finder-rename"] {
    taskResults.append((id, "SKIP (Finder is once-per-user: never started for an agent, needs_sandbox)"))
}
for (id, r) in taskResults { print("task \(id): \(r)") }
for (id, r) in taskResults where r.hasPrefix("FAIL") { failures.append("task \(id): \(r)") }

// MARK: 3. The canvas, by pixels

struct Shot { var rgba: [UInt8]; var w: Int; var h: Int }
var shotCount = 0
func shot(_ window: Int) -> Shot? {
    shotCount += 1
    let r = agent(["shot", "--window", String(window), "--out", "keys-probe-\(shotCount).png"])
    guard isOK(r), let path = data(r)["path"] as? String, let rep = NSBitmapImageRep(data: (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()),
          let cg = rep.cgImage else { return nil }
    let w = cg.width, h = cg.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    let ok = bytes.withUnsafeMutableBytes { buf -> Bool in
        guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    try? FileManager.default.removeItem(atPath: path)
    return ok ? Shot(rgba: bytes, w: w, h: h) : nil
}
func dark(_ s: Shot, _ x: Int, _ y: Int) -> Bool {
    guard x >= 0, y >= 0, x < s.w, y < s.h else { return false }
    let i = (y * s.w + x) * 4
    return Int(s.rgba[i]) + Int(s.rgba[i + 1]) + Int(s.rgba[i + 2]) < 200
}
/// Whether a dark pixel sits within `r` pixels of (x, y).
func darkNear(_ s: Shot, _ x: Int, _ y: Int, _ r: Int) -> Bool {
    for dy in -r...r { for dx in -r...r where dark(s, x + dx, y + dy) { return true } }
    return false
}

print("canvas (drawn on from behind):")
// The test app ships inside the running BaneySpaces bundle (Resources/probe): the only place BaneySpaces starts it from.
let bundleURL = NSWorkspace.shared.runningApplications.first { $0.bundleURL?.lastPathComponent == "BaneySpaces.app" }?.bundleURL
let canvasApp = bundleURL?.appendingPathComponent("Contents/Resources/probe/CanvasProbe.app")
if canvasApp == nil || !FileManager.default.fileExists(atPath: canvasApp!.path) { untested("the installed BaneySpaces has no Resources/probe/CanvasProbe.app") }
var canvasPass = false
if let (win, pid) = open(canvasApp!.path) {
    if let before = shot(win) {
        let scale = Double(before.w) / 400          // the window is 400 points wide
        let from = (x: 60.0, y: 90.0), to = (x: 320.0, y: 230.0)
        let r = agent(["drag", "--window", String(win), "--x", "60", "--y", "90", "--x2", "320", "--y2", "230", "--steps", "24"])
        if isOK(r), data(r)["verified"] as? Bool == true {
            print("  drag: verified (\((data(r)["evidence"] as? [String: Any])?["basis"] as? String ?? "?"), \(data(r)["transport"] as? String ?? "?"))")
        } else { failures.append("canvas: drag -> \(errorText(r))"); print("  drag: \(errorText(r))") }
        Thread.sleep(forTimeInterval: 0.5)
        if let after = shot(win) {
            // Independent proof from this probe's own captures: dark along the line now, light there before, and the rest unchanged.
            var hits = 0, total = 0
            for i in 3...17 {
                let t = Double(i) / 20
                let x = Int((from.x + (to.x - from.x) * t) * scale), y = Int((from.y + (to.y - from.y) * t) * scale)
                total += 1
                if darkNear(after, x, y, 4), !darkNear(before, x, y, 4) { hits += 1 }
            }
            canvasPass = Double(hits) / Double(total) >= 0.9
            print("  stroke pixels: \(hits)/\(total) sample points along the line went dark")
            if !canvasPass { failures.append("canvas: only \(hits)/\(total) points along the drag turned dark") }
            // A click leaves a dot.
            let c = agent(["click-at", "--window", String(win), "--x", "80", "--y", "250"])
            Thread.sleep(forTimeInterval: 0.5)
            if let dot = shot(win), isOK(c) {
                let x = Int(80 * scale), y = Int(250 * scale)
                if darkNear(dot, x, y, 3), !darkNear(after, x, y, 3) { print("  click-at: dot drawn, verified") }
                else { failures.append("canvas: click-at drew no dot"); print("  click-at: no dot") }
            } else { failures.append("canvas: click-at -> \(errorText(c))"); print("  click-at: \(errorText(c))") }
        } else { failures.append("canvas: no capture after the drag (Screen Recording for BaneySpaces?)") }
    } else { failures.append("canvas: no capture before the drag (Screen Recording for BaneySpaces?)") }
    quit(pid)
} else { failures.append("canvas: the test app could not be started (BaneySpaces checks its signature and code hash)") }

// MARK: result

Thread.sleep(forTimeInterval: 1.8)   // late activations arrive after the last action
lock.lock(); running = false; lock.unlock()
Thread.sleep(forTimeInterval: 0.3)
cleanup()

lock.lock()
let gone = inputFromElsewhere
let leaked = leakedToSession
let seen = eventsSeen
let nSamples = samples
let nChanges = changes
lock.unlock()
print("samples: \(nSamples) (every 50 ms), session events seen: \(seen), from elsewhere: \(gone), from BaneySpaces' process: \(leaked)")
if gone > 0 { print("aborted: input from somewhere else reached the session (you came back); the run is not a pass or a fail"); untested("you came back during the run") }
if leaked > 0 { failures.append("\(leaked) event(s) posted by BaneySpaces reached the session: they must go to one process") }
failures.forEach { print("fail: \($0)") }
nChanges.prefix(20).forEach { print("change: \($0)") }
if nChanges.isEmpty && failures.isEmpty {
    print("PASS: zero changes to the front app, the workspace, the real pointer and the key window; no stray window; keys, menu-free keys and a canvas stroke verified")
} else {
    print("FAIL: \(nChanges.count) change(s), \(failures.count) failed requirement(s)")
    cleanup()
    exit(1)
}
