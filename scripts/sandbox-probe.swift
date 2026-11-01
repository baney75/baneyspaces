// Proves the sandbox works end to end without touching your screen: up, the in-guest network
// self-check, reset three times (each timed against the 10 s budget), the guest hands stub, down.
// Everything runs headless (`tart run --no-graphics`), so it is safe to run at any time.
//
//   swift scripts/sandbox-probe.swift [--resets N]
//
// Run it from the repository root. It builds baneyspaces-cli, runs `baneyspaces-cli sandbox --local probe`
// (the same SandboxManager the app uses, with the real Tart), and checks that nothing you would see
// changed: the workspace you are on (state.json `current`) and the app in front, sampled every 100 ms
// while the probe runs, and that no VM window ever exists. A change you made yourself (real input in
// the last 0.4 s) is not counted. Prints "sandbox-probe PASS" and exits 0 only if the probe passed, no bsx-* VM
// is left, and nothing changed. Needs Tart and the root-owned Softnet (sandbox/PIN) and the pinned image.
import AppKit
import Foundation

let state = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/BaneySpaces/state.json")
func current() -> String {
    guard let d = try? Data(contentsOf: state), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return "?" }
    return "\(o["current"] ?? "?")"
}
func front() -> String { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? NSWorkspace.shared.frontmostApplication?.localizedName ?? "-" }
func look() -> String { "workspace \(current()), front app \(front())" }
/// Seconds since real keyboard or mouse input. Synthesized events don't count, so software can't pass for you.
func idle() -> Double { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!) }
/// Any on-screen or off-screen window owned by the VM's processes: a headless run must have none.
func vmWindows() -> Int {
    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.filter { w in
        let owner = (w[kCGWindowOwnerName as String] as? String ?? "").lowercased()
        return owner == "tart" || owner == "softnet" || owner.contains("virtual machine") || owner.contains("virtualization")
    }.count
}

func sh(_ args: [String], capture: Bool = false) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    let pipe = Pipe()
    if capture { p.standardOutput = pipe }
    try? p.run()
    let out = capture ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: out, as: UTF8.self))
}

var extra: [String] = []
if let i = CommandLine.arguments.firstIndex(of: "--resets"), i + 1 < CommandLine.arguments.count { extra = ["--resets", CommandLine.arguments[i + 1]] }

print("building baneyspaces-cli…")
guard sh(["swift", "build", "--product", "baneyspaces-cli"]).0 == 0 else { print("build failed"); exit(1) }
let bin = sh(["swift", "build", "--product", "baneyspaces-cli", "--show-bin-path"], capture: true).1.trimmingCharacters(in: .whitespacesAndNewlines) + "/baneyspaces-cli"

let before = look()
print("before: \(before)")
// A change in workspace or front app with real input in the last 0.4 s is you. One with none was made
// by software, and that is what fails the probe. Any VM window at all fails it too.
var last = before
var softwareChanges: [String] = []
var vmWindowSightings = 0
var frontWasVM = false
let lock = NSLock()
var running = true
let watcher = Thread {
    while true {
        lock.lock(); let go = running; lock.unlock()
        if !go { break }
        let now = look()
        lock.lock()
        if now != last {
            if idle() > 0.4 { softwareChanges.append("\(last) -> \(now)") }
            last = now
        }
        if vmWindows() > 0 { vmWindowSightings += 1 }
        let f = front().lowercased()
        if f == "tart" || f.contains("virtualization") { frontWasVM = true }
        lock.unlock()
        Thread.sleep(forTimeInterval: 0.1)
    }
}
watcher.start()

let t0 = Date()
let (status, _) = sh([bin, "sandbox", "--local", "probe"] + extra)
lock.lock(); running = false; lock.unlock()
Thread.sleep(forTimeInterval: 0.3)
let after = look()
print(String(format: "probe took %.0f s", Date().timeIntervalSince(t0)))
print("after:  \(after)")
lock.lock()
let changes = softwareChanges, windows = vmWindowSightings, vmFront = frontWasVM
lock.unlock()
if !changes.isEmpty { print("screen CHANGED with no input from you:\n  " + changes.joined(separator: "\n  ")) }
if windows > 0 { print("a VM window appeared (\(windows) samples)") }
if vmFront { print("a VM process came to the front") }
let quiet = changes.isEmpty && windows == 0 && !vmFront
print(quiet ? "screen: no window, no change made by software (before and after may differ if you were working: \(before) / \(after))" : "screen: FAIL")
let ok = status == 0 && quiet
print(ok ? "sandbox-probe PASS" : "sandbox-probe FAIL")
exit(ok ? 0 : 1)
