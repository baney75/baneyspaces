// Fails if opening an app from a workspace doesn't land it on that workspace (regression ledger:
// "Opening an app from a workspace takes you to the app's other workspace instead", 11-01).
//
// With apps it starts and owns (TextEdit with two temp documents, a new-window app; Calculator, a
// single-window app), it puts the app on workspace <from>, switches to the empty workspace <to>,
// opens the app through the launcher's own code path (`baneyspaces://open-here/<to>?app=…`, which
// runs `LauncherModel.open`, the call Return makes), and reads state.json:
//   TextEdit   a new window is on <to>, the two documents are still on <from>, and `current` is <to>
//   Calculator its one window moved to <to>, none is left on <from>, and `current` is <to>
// `current` is sampled every 50 ms from the open until 1.5 s after the window lands: it must never be
// anything but <to> (the bug is a trip to the app's old workspace). Photos is tried too, only when it
// is already running with a window elsewhere, and put back where it was.
//
// Idle only: it moves your screen and starts apps, so it runs after the Mac has had 10 minutes without
// a key or the pointer (HIDIdleTime). Otherwise it prints "untested live" and exits 3. The URL command
// it uses is gated by `openHereURLCommandsUntil`, a time at most a minute away that the probe renews
// before each open and removes at the end; a probe that is killed leaves a gate that lapses on its own,
// and BaneySpaces removes the key at its next launch. It also cleans up on SIGINT, SIGTERM and SIGHUP:
// it quits the apps it started, deletes its temp files and returns you to the workspace you were on.
//   swift scripts/open-here-probe.swift            workspaces 2 and 3
//   swift scripts/open-here-probe.swift 4 5        <from> <to>; <to> must be empty
import AppKit

let args = CommandLine.arguments.dropFirst().compactMap(Int.init)
let from = args.count == 2 ? args[0] : 2
let to = args.count == 2 ? args[1] : 3
guard (1...9).contains(from), (1...9).contains(to), from != to, args.count == 2 || CommandLine.arguments.count == 1 else {
    FileHandle.standardError.write("usage: swift scripts/open-here-probe.swift [<from 1-9> <to 1-9>]\n".data(using: .utf8)!)
    exit(2)
}

// MARK: Plumbing

func shell(_ path: String, _ arguments: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = arguments
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    try? p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}
func open(_ args: [String]) { _ = shell("/usr/bin/open", args) }

/// Seconds since the last key or pointer event.
func idleSeconds() -> Double {
    let text = shell("/usr/sbin/ioreg", ["-c", "IOHIDSystem", "-r", "-d", "4"])
    for line in text.split(separator: "\n") where line.contains("HIDIdleTime") {
        if let n = line.split(separator: "=").last.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }) { return n / 1e9 }
    }
    return 0
}

let stateURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/BaneySpaces/state.json")
struct Snapshot {
    var current = 0
    /// Window id to (app, workspace).
    var windows: [UInt32: (app: String, workspace: Int)] = [:]
    func ids(of app: String, on n: Int) -> Set<UInt32> { Set(windows.filter { $0.value.app == app && $0.value.workspace == n }.keys) }
    func ids(of app: String) -> Set<UInt32> { Set(windows.filter { $0.value.app == app }.keys) }
}
func state() -> Snapshot? {
    guard let data = try? Data(contentsOf: stateURL),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let ws = json["workspaces"] as? [String: [[String: Any]]] else { return nil }
    var s = Snapshot()
    s.current = (json["current"] as? NSNumber)?.intValue ?? 0
    for (n, list) in ws {
        for w in list {
            if let id = (w["id"] as? NSNumber)?.uint32Value, let app = w["app"] as? String, let wn = Int(n) { s.windows[id] = (app, wn) }
        }
    }
    return s
}
@discardableResult
func wait(_ seconds: Double, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        usleep(50_000)
    }
    return condition()
}

// MARK: Cleanup, run on every way out

let defaultsDomain = "com.baney.baneyspaces"
let gateKey = "openHereURLCommandsUntil"
/// Opens the gate for the next 50 seconds. Called before each open: nothing stays open longer than that.
func openGate() { _ = shell("/usr/bin/defaults", ["write", defaultsDomain, gateKey, "-float", String(Date().timeIntervalSince1970 + 50)]) }
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("open-here-probe-\(getpid())")
var startedPids: [pid_t] = []
var originalWorkspace = 0
var moved: [(path: String, back: Int)] = []

func cleanup() {
    for (path, back) in moved { openGate(); open(["-g", "baneyspaces://open-here/\(back)?app=\(path)"]); usleep(800_000) }
    for pid in startedPids {
        let app = NSRunningApplication(processIdentifier: pid)
        app?.terminate()
        if !wait(3, { app?.isTerminated ?? true }) { app?.forceTerminate() }
    }
    _ = shell("/usr/bin/defaults", ["delete", defaultsDomain, gateKey])
    try? FileManager.default.removeItem(at: temp)
    if originalWorkspace > 0 { open(["-g", "baneyspaces://switch/\(originalWorkspace)"]) }
}
func fail(_ s: String) -> Never { print("FAIL: \(s)"); cleanup(); exit(1) }

// A signal runs the same cleanup. The main thread is busy waiting, so the handlers run on a global queue.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    source.setEventHandler { print("interrupted (signal \(sig)); cleaning up"); cleanup(); exit(130) }
    source.resume()
    signalSources.append(source)
}

// MARK: Guards

let idle = idleSeconds()
guard idle >= 600 else {
    print("untested live: the Mac was used \(Int(idle)) s ago; this probe moves the screen and starts apps, so it needs 10 minutes idle (HIDIdleTime)")
    exit(3)
}
guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == defaultsDomain }), let start = state() else {
    print("untested live: BaneySpaces isn't running (no state.json)")
    exit(3)
}
guard start.windows.values.allSatisfy({ $0.workspace != to }) else {
    print("untested live: workspace \(to) isn't empty; pick an empty one: swift scripts/open-here-probe.swift <from> <to>")
    exit(3)
}
originalWorkspace = start.current
try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

func running(_ bundle: String) -> NSRunningApplication? { NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundle } }
func goTo(_ n: Int) {
    open(["-g", "baneyspaces://switch/\(n)"])
    guard wait(5, { state()?.current == n }) else { fail("couldn't switch to workspace \(n) (current is \(state()?.current ?? 0))") }
    usleep(500_000)
}

/// Opens `path` the way the launcher's Return does for workspace `to`, then watches `current` until the
/// result has settled. Returns every workspace `current` was seen on after the open.
func openHere(_ path: String, settle: Bool = true) -> Set<Int> {
    var seen = Set<Int>()
    openGate()
    open(["-g", "baneyspaces://open-here/\(to)?app=\(path)"])
    let end = Date().addingTimeInterval(settle ? 5.0 : 1.0)
    while Date() < end {
        if let c = state()?.current { seen.insert(c) }
        usleep(50_000)
    }
    return seen
}

var ran: [String] = []

// MARK: A new-window app: TextEdit

if running("com.apple.TextEdit") == nil {
    let docs = ["a.txt", "b.txt"].map { temp.appendingPathComponent($0) }
    for d in docs { try? "open here probe".write(to: d, atomically: true, encoding: .utf8) }
    goTo(from)
    open(["-g", "-a", "TextEdit"] + docs.map(\.path))
    guard wait(10, { (state()?.ids(of: "TextEdit", on: from).count ?? 0) >= 2 }) else {
        fail("TextEdit's two documents never reached workspace \(from): \(state()?.windows.filter { $0.value.app == "TextEdit" } ?? [:])")
    }
    if let app = running("com.apple.TextEdit") { startedPids.append(app.processIdentifier) }
    let before = state()!.ids(of: "TextEdit")
    goTo(to)
    let seen = openHere("/System/Applications/TextEdit.app")
    guard let after = state() else { fail("state.json unreadable") }
    let fresh = after.ids(of: "TextEdit").subtracting(before)
    guard seen == [to] else { fail("TextEdit: opening it from workspace \(to) took you to workspace \(seen.subtracting([to]).sorted()) (saw \(seen.sorted()))") }
    guard !fresh.isEmpty, fresh.allSatisfy({ after.windows[$0]?.workspace == to }) else {
        fail("TextEdit: a new window should be on workspace \(to); new windows: \(fresh.map { "\($0) on \(after.windows[$0]?.workspace ?? 0)" })")
    }
    guard after.ids(of: "TextEdit", on: from) == before else { fail("TextEdit: its documents left workspace \(from): \(after.ids(of: "TextEdit", on: from)) vs \(before)") }
    ran.append("TextEdit (new window)")
} else {
    print("skipped TextEdit: it was already running, so the probe doesn't own it")
}

// MARK: A single-window app: Calculator

if running("com.apple.calculator") == nil {
    goTo(from)
    open(["-g", "-a", "Calculator"])
    guard wait(10, { !(state()?.ids(of: "Calculator", on: from).isEmpty ?? true) }) else { fail("Calculator's window never reached workspace \(from)") }
    if let app = running("com.apple.calculator") { startedPids.append(app.processIdentifier) }
    goTo(to)
    let seen = openHere("/System/Applications/Calculator.app")
    guard let after = state() else { fail("state.json unreadable") }
    guard seen == [to] else { fail("Calculator: opening it from workspace \(to) took you to workspace \(seen.subtracting([to]).sorted()) (saw \(seen.sorted()))") }
    guard !after.ids(of: "Calculator", on: to).isEmpty, after.ids(of: "Calculator", on: from).isEmpty else {
        fail("Calculator: its window should have moved from \(from) to \(to): on \(from) \(after.ids(of: "Calculator", on: from)), on \(to) \(after.ids(of: "Calculator", on: to))")
    }
    ran.append("Calculator (single window)")
} else {
    print("skipped Calculator: it was already running, so the probe doesn't own it")
}

// MARK: Photos, only if it is already open somewhere else

if running("com.apple.Photos") != nil, let s = state() {
    let there = s.ids(of: "Photos")
    if let id = there.first, let home = s.windows[id]?.workspace, home != to, there.count == 1 {
        goTo(to)
        let seen = openHere("/System/Applications/Photos.app")
        guard let after = state() else { fail("state.json unreadable") }
        moved.append(("/System/Applications/Photos.app", home))
        guard seen == [to] else { fail("Photos: opening it from workspace \(to) took you to workspace \(seen.subtracting([to]).sorted()) (saw \(seen.sorted()))") }
        guard after.windows[id]?.workspace == to else { fail("Photos: its window should be on workspace \(to), it is on \(after.windows[id]?.workspace ?? 0)") }
        ran.append("Photos (already open on \(home))")
    } else {
        print("skipped Photos: it needs exactly one window, on a workspace other than \(to)")
    }
}

cleanup()
guard !ran.isEmpty else {
    print("untested live: no test app could be started (TextEdit and Calculator were already running)")
    exit(3)
}
print("opened here: \(ran.joined(separator: ", ")) landed on workspace \(to) from workspace \(from), and current stayed \(to)")
