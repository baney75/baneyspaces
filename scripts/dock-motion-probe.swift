// How the Workspace Dock and its "+N" list move (2026-10-31).
//
// Donovan's recording showed the dock and the list popping in and out, and the dock panel jumping
// when the list opened. This shows the dock with BaneySpaces' own URL commands (no pointer, no
// keys, no clicks), opens and closes the first tile's "+N" list, hides the dock, and samples the
// window server's list of BaneySpaces' panels about 250 times a second the whole way: each
// panel's frame and alpha. It reports, for the dock coming in, the list opening, the list closing
// and the dock going out:
//   - how long the motion took, and how many distinct states the window server showed (a pop is
//     one or two; a 180 ms ease is about ten at 60 Hz),
//   - the longest gap between two states, and the frames dropped (gaps over 1.5 frames at 60 Hz),
// and fails if the dock panel's frame changes at all while the list opens or closes.
//
// The dock is pinned (`dock/show`), so this is the pinned path the tick takes; a list `dock/more` opens
// is held until `dock/lessmore`, since the probe never moves the pointer and the 250 ms grace would
// otherwise close it at once. The grace itself (and Esc, and a click outside) need a pointer and
// are covered by unit tests and the steps in the PR.
//
// It needs `defaults write com.baney.baneyspaces dockURLCommands -bool true` (the checks switch the
// other dock probes use) and a workspace with more than four apps, so a tile shows "+N". The dock
// is on screen for about four seconds, so it runs only when the Mac has been idle 10 minutes
// (HIDIdleTime) unless you pass --now. Exit 0 = smooth and still; 1 = a failure; 2 = couldn't run.
//
//   swift scripts/dock-motion-probe.swift [--now]
import AppKit
import CoreGraphics

func idleSeconds() -> Double {
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"), &iter) == KERN_SUCCESS else { return 0 }
    defer { IOObjectRelease(iter) }
    let entry = IOIteratorNext(iter)
    defer { IOObjectRelease(entry) }
    var props: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let dict = props?.takeRetainedValue() as? [String: Any], let ns = dict["HIDIdleTime"] as? Int64 else { return 0 }
    return Double(ns) / 1e9
}

func run(_ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    try? p.run()
    p.waitUntilExit()
    return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

func command(_ c: String) { _ = run(["open", "-g", "baneyspaces://dock/\(c)"]) }

struct Sample { let t: Double; let id: Int; let frame: CGRect; let alpha: Double }

/// BaneySpaces' panels at the status bar level, now.
func panels() -> [(id: Int, frame: CGRect, alpha: Double)] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let level = Int(CGWindowLevelForKey(.statusWindow))
    return list.compactMap { w in
        guard (w[kCGWindowOwnerName as String] as? String) == "BaneySpaces", (w[kCGWindowLayer as String] as? Int) == level,
              let id = w[kCGWindowNumber as String] as? Int,
              let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) else { return nil }
        return (id, r, w[kCGWindowAlpha as String] as? Double ?? 1)
    }
}

var samples: [Sample] = []
let t0 = Date()
func now() -> Double { Date().timeIntervalSince(t0) }

/// Samples for `seconds`, the first `after` of them following `action` (run once, at the start).
func record(_ seconds: Double, action: () -> Void) -> Double {
    let start = now()
    action()
    while now() - start < seconds {
        let t = now()
        for p in panels() { samples.append(Sample(t: t, id: p.id, frame: p.frame, alpha: p.alpha)) }
        usleep(3000)
    }
    return start
}

func fail(_ why: String, code: Int32 = 1) -> Never {
    command("hide")
    print(why)
    exit(code)
}

if !CommandLine.arguments.contains("--now") && idleSeconds() < 600 {
    print("not run: the Mac has been idle \(Int(idleSeconds())) s, under 10 minutes; the dock would show on screen for about four seconds. Pass --now to run anyway.")
    exit(2)
}
guard run(["defaults", "read", "com.baney.baneyspaces", "dockURLCommands"]).trimmingCharacters(in: .whitespacesAndNewlines) == "1" else {
    print("not run: turn on the checks switch first: defaults write com.baney.baneyspaces dockURLCommands -bool true")
    exit(2)
}
guard panels().isEmpty else { print("not run: a BaneySpaces panel is already on screen"); exit(2) }

let tShow = record(0.8) { command("show") }
guard let dockID = samples.last(where: { $0.t >= tShow })?.id, samples.contains(where: { $0.id == dockID }) else {
    fail("FAIL: the dock never came up (is the Workspace Dock on?)")
}
let tMore = record(0.9) { command("more") }
let ids = Set(samples.filter { $0.t >= tMore }.map(\.id))
let listID = ids.subtracting([dockID]).first
let tLess = record(0.7) { command("lessmore") }
let tHide = record(0.8) { command("hide") }

/// The states of a panel in [from, to): consecutive samples with a different frame or alpha.
func states(_ id: Int, _ from: Double, _ to: Double) -> [(t: Double, frame: CGRect, alpha: Double)] {
    var out: [(t: Double, frame: CGRect, alpha: Double)] = []
    for s in samples where s.id == id && s.t >= from && s.t < to {
        if let last = out.last, last.frame == s.frame, abs(last.alpha - s.alpha) < 0.005 { continue }
        out.append((s.t, s.frame, s.alpha))
    }
    return out
}

var failed = false
func report(_ name: String, _ id: Int?, _ from: Double, _ to: Double, minStates: Int) {
    guard let id else { print("\(name): FAIL no panel seen"); failed = true; return }
    let st = states(id, from, to)
    guard st.count >= 2 else { print("\(name): FAIL \(st.count) state: it popped"); failed = true; return }
    let span = st.last!.t - st.first!.t
    let gaps = zip(st, st.dropFirst()).map { $1.t - $0.t }
    let worst = gaps.max() ?? 0
    let dropped = gaps.filter { $0 > 1.5 / 60 }.count
    let verdict = st.count >= minStates ? "ok" : "FAIL: too few states, it popped"
    print(String(format: "%@: %d states over %.0f ms, longest gap %.0f ms, %d dropped frames (>25 ms): %@",
                 name, st.count, span * 1000, worst * 1000, dropped, verdict))
    if st.count < minStates { failed = true }
}

report("dock in   ", dockID, tShow, tMore, minStates: 4)
report("list open ", listID, tMore, tLess, minStates: 3)
if let listID {
    let outStates = states(listID, tLess, tHide)
    report("list close", listID, tLess, tHide, minStates: 3)
    _ = outStates
}
report("dock out  ", dockID, tHide, tHide + 0.8, minStates: 3)

// The bar doesn't move for the list: the dock panel's frame is the same before the list opens, while
// it's open, and after it closes.
let frames = Set(samples.filter { $0.id == dockID && $0.t >= tShow + 0.4 && $0.t < tHide }.map { "\($0.frame)" })
if frames.count != 1 {
    print("dock frame: FAIL \(frames.count) different frames while the list opened and closed: \(frames.sorted())")
    failed = true
} else {
    print("dock frame: ok, one frame the whole time the list opened and closed")
}
if listID == nil { print("list: FAIL no second panel appeared (is there a tile with more than four apps?)"); failed = true }
exit(failed ? 1 : 0)
