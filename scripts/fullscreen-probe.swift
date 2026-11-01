// Fails if a window disappears in or around full screen. It opens windows of its own (three on
// workspace 1 for the sliding checks, one on workspace 2, one the size of the screen that is not in
// full screen), plus whatever Ghostty windows exist, and then, in each mode (`baneyspaces`, the
// default, and `native`):
//   1. enters full screen on one window by ⌃⌘F and by the green button (BaneySpaces mode) or by
//      macOS (native), switches workspaces 1→2→1 ten times, and checks every window after each step;
//   2. puts all three workspace-1 windows in full screen and activates them in turn through the dock
//      tile's code path (`baneyspaces://focuswindow/<id>`, what `Spaces.focusApp` ends in), sampling
//      every on-screen window every 4 ms: BaneySpaces mode must show no frame where a window is
//      half drawn and no desktop slide; native mode must never ask one to leave full screen
//      (read back from trace.log);
//   3. enters full screen while a switch is in flight;
//   4. a window that will not leave full screen (like a Chromium video), carried and then closed;
//   5. a screen-sized window that is not in full screen;
//   6. a second display, when there is one.
// At the end every window must exist, be on its workspace in state.json, and be on screen when its
// workspace is shown; a Ghostty window that existed before must still be where it was. It fails on any
// vanished window. Not run here, and listed: full-screen video in Helium (needs a page), exit from full
// screen while hidden (needs a person), Mission Control behavior (read, not changed).
//
// It types ⌃⌘F, clicks the green button and takes the pointer, so it runs only when Donovan has been
// idle 10 minutes; otherwise it prints "untested live" and exits 3. Run it with BaneySpaces (this build)
// installed and running:
//   swift scripts/fullscreen-probe.swift
// It turns BaneySpaces' own `dockURLCommands` check switch on for its run only (the dock's URL commands it
// drives) and puts it back as it found it, whatever happens; it changes `behavior.fullscreen` and puts that
// back too. It ends on workspace 1. It also asserts that a window in macOS full screen stays in the dock's model
// (state.json) before and after every switch.
import AppKit

@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopySpacesForWindows") func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ windows: CFArray) -> Unmanaged<CFArray>?
@_silgen_name("CGSCopyManagedDisplaySpaces") func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray

func say(_ s: String) { print(s); fflush(stdout) }
func run(_ path: String, _ args: [String]) -> String {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: path); p.arguments = args; p.standardOutput = pipe; p.standardError = Pipe()
    try? p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

// MARK: Idle gate

func idleSeconds() -> Double {
    for line in run("/usr/sbin/ioreg", ["-c", "IOHIDSystem"]).split(separator: "\n") where line.contains("HIDIdleTime") {
        if let n = line.split(separator: "=").last.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }) { return n / 1e9 }
    }
    return 0
}
let idle = idleSeconds()
guard idle >= 600 else {
    say("untested live: Donovan has been idle \(Int(idle)) s and this probe types ⌃⌘F, clicks the green button and takes the pointer (needs 600 s)")
    exit(3)
}

// MARK: Reading the Mac

let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/BaneySpaces")
struct State { var current = 1; var shown: Set<Int> = [1]; var ws: [UInt32: Int] = [:]; var apps: [UInt32: String] = [:] }
func state() -> State {
    guard let data = try? Data(contentsOf: support.appendingPathComponent("state.json")),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return State() }
    var s = State()
    s.current = json["current"] as? Int ?? 1
    s.shown = Set((json["displays"] as? [String: Int])?.values.map { $0 } ?? [s.current])
    for (n, list) in (json["workspaces"] as? [String: [[String: Any]]]) ?? [:] {
        for w in list { if let id = (w["id"] as? NSNumber)?.uint32Value { s.ws[id] = Int(n); s.apps[id] = w["app"] as? String } }
    }
    return s
}
func traceLines(since t: Double) -> [String] {
    let text = (try? String(contentsOf: support.appendingPathComponent("trace.log"), encoding: .utf8)) ?? ""
    return text.split(separator: "\n").compactMap { line in
        let parts = line.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let at = Double(parts[0]), at >= t else { return nil }
        return String(parts[1])
    }
}
func cg(_ id: UInt32) -> (onScreen: Bool, bounds: CGRect)? {
    let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    guard let w = info.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }) else { return nil }
    let b = (w[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
    return ((w[kCGWindowIsOnscreen as String] as? Bool) == true, b)
}
func fullScreenSpaces() -> Set<Int> {
    var out = Set<Int>()
    for d in CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]] ?? [] {
        for s in d["Spaces"] as? [[String: Any]] ?? [] where (s["type"] as? NSNumber)?.intValue == 4 {
            if let id = (s["ManagedSpaceID"] as? NSNumber)?.intValue { out.insert(id) }
        }
    }
    return out
}
func inFullScreen(_ id: UInt32) -> Bool {
    let spaces = (CGSCopySpacesForWindows(CGSMainConnectionID(), 0x7, [id] as CFArray)?.takeRetainedValue() as? [NSNumber] ?? []).map(\.intValue)
    return !Set(spaces).isDisjoint(with: fullScreenSpaces())
}
let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
func ax(_ r: NSRect) -> CGRect { CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height) }
func stranded(_ b: CGRect) -> Bool {
    let screens = NSScreen.screens.map { ax($0.frame) }
    let shown = screens.reduce(CGFloat(0)) { $0 + (b.intersection($1).isNull ? 0 : b.intersection($1).width * b.intersection($1).height) }
    return shown < b.width * b.height * 0.25
}

// MARK: Driving BaneySpaces and the windows

func open(_ url: String) { _ = run("/usr/bin/open", ["-g", url]) }
func pump(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
func until(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end { if cond() { return true }; pump(0.05) }
    return cond()
}
func switchTo(_ n: Int, wait: TimeInterval = 2.5) {
    open("baneyspaces://switch/\(n)")
    _ = until(8) { state().current == n }
    pump(wait)
}
let cli = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/baneyspaces").path
func getMode() -> String {
    let out = run(cli, ["get", "behavior.fullscreen"])
    return out.contains("native") ? "native" : "baneyspaces"
}
func setMode(_ m: String) { _ = run(cli, ["set", "behavior.fullscreen", m]); pump(1.0) }

/// BaneySpaces' own switch for the URL commands this probe drives: on for the run, then as it was.
let flagKey = "dockURLCommands"
let flagBefore = run("/usr/bin/defaults", ["read", "com.baney.baneyspaces", flagKey]).trimmingCharacters(in: .whitespacesAndNewlines)
let modeBefore = getMode()
var restored = false
func restoreSettings() {
    guard !restored else { return }
    restored = true
    if flagBefore == "1" || flagBefore.lowercased() == "true" {
        _ = run("/usr/bin/defaults", ["write", "com.baney.baneyspaces", flagKey, "-bool", "true"])
    } else if flagBefore.isEmpty {
        _ = run("/usr/bin/defaults", ["delete", "com.baney.baneyspaces", flagKey])
    } else {
        _ = run("/usr/bin/defaults", ["write", "com.baney.baneyspaces", flagKey, "-bool", "false"])
    }
    setMode(modeBefore)
}
func finish(_ code: Int32) -> Never { restoreSettings(); exit(code) }
_ = run("/usr/bin/defaults", ["write", "com.baney.baneyspaces", flagKey, "-bool", "true"])
atexit { restoreSettings() }

var failures: [String] = []
var closed = Set<String>()
var notRun: [String] = []
func fail(_ s: String) { failures.append(s); say("FAIL: \(s)") }

final class ProbeWindow: NSWindow {
    var refuseToLeave = false
    override func toggleFullScreen(_ sender: Any?) {
        if refuseToLeave && styleMask.contains(.fullScreen) { return }
        super.toggleFullScreen(sender)
    }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
var windows: [String: ProbeWindow] = [:]
func make(_ name: String, at origin: NSPoint, size: NSSize = NSSize(width: 520, height: 360)) -> ProbeWindow {
    let w = ProbeWindow(contentRect: NSRect(origin: origin, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                        backing: .buffered, defer: false)
    w.title = "bs-fullscreen-probe \(name)"
    w.collectionBehavior = [.fullScreenPrimary]
    w.isReleasedWhenClosed = false
    w.makeKeyAndOrderFront(nil)
    windows[name] = w
    return w
}
func wid(_ name: String) -> UInt32 { UInt32(windows[name]!.windowNumber) }

NSApplication.shared.setActivationPolicy(.regular)
NSApplication.shared.finishLaunching()

// The checks that end every step.
func verify(_ label: String) {
    let st = state()
    // Every window the probe made and has not closed on purpose: no exceptions. One that has vanished
    // from the window server altogether is the loudest failure there is.
    for (name, w) in windows where !closed.contains(name) {
        let id = UInt32(w.windowNumber)
        guard let seen = cg(id) else { fail("\(label): \(name) (\(id)) has vanished from the window server"); continue }
        guard let n = st.ws[id] else { fail("\(label): \(name) (\(id)) is on no workspace in state.json (the dock's model)"); continue }
        if st.shown.contains(n) {
            if !(seen.onScreen || inFullScreen(id) || w.isMiniaturized) { fail("\(label): \(name) (\(id)) is on shown workspace \(n) but not on screen") }
        } else {
            if inFullScreen(id) { fail("\(label): \(name) (\(id)) is on hidden workspace \(n) and stuck on a full-screen desktop") }
            else if seen.onScreen && !stranded(seen.bounds) { fail("\(label): \(name) (\(id)) is on hidden workspace \(n) and in plain sight") }
        }
    }
}
/// A window in macOS full screen is still in the dock's model.
func requireListed(_ name: String, _ label: String) {
    guard let w = windows[name] else { return }
    let id = UInt32(w.windowNumber)
    if state().ws[id] == nil { fail("\(label): \(name) (\(id)) is in full screen and not in the dock's model (state.json)") }
}
func waitForWorkspaceList(_ names: [String]) {
    _ = until(8) { let s = state(); return names.allSatisfy { s.ws[wid($0)] != nil } }
}

// MARK: Keys and the pointer

func pressFullScreenKey() {
    NSApplication.shared.activate(ignoringOtherApps: true)
    pump(0.3)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: 3, keyDown: down)
        e?.flags = [.maskControl, .maskCommand]
        e?.post(tap: .cghidEventTap)
        pump(0.03)
    }
}
func clickGreenButton(_ w: ProbeWindow, option: Bool = false) {
    guard let b = w.standardWindowButton(.zoomButton) else { return }
    let inWindow = b.convert(b.bounds, to: nil)
    let screen = w.convertToScreen(inWindow)
    let p = CGPoint(x: screen.midX, y: primaryHeight - screen.midY)
    let saved = CGEvent(source: nil)?.location ?? .zero
    w.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
    pump(0.3)
    CGWarpMouseCursorPosition(p)
    pump(0.15)
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
        if option { e?.flags = .maskAlternate }
        e?.post(tap: .cghidEventTap)
        pump(0.08)
    }
    CGWarpMouseCursorPosition(saved)
}
func fills(_ w: ProbeWindow) -> Bool {
    guard let s = w.screen else { return false }
    let want = s.visibleFrame, got = w.frame
    return abs(want.minX - got.minX) < 12 && abs(want.minY - got.minY) < 12 && abs(want.width - got.width) < 12 && abs(want.height - got.height) < 12
}
/// "Full screen" the way this mode does it.
func enterFullScreen(_ name: String, how: Int, mode: String) {
    guard let w = windows[name] else { return }
    w.makeKeyAndOrderFront(nil)
    if mode == "native" {
        w.toggleFullScreen(nil)
        _ = until(4) { w.styleMask.contains(.fullScreen) }
        pump(1.0)
        requireListed(name, "native, in full screen")
    } else {
        if how % 2 == 0 { pressFullScreenKey() } else { clickGreenButton(w) }
        _ = until(3) { fills(w) }
        pump(0.3)
        if !fills(w) { fail("\(mode): \(name) did not fill its workspace (by \(how % 2 == 0 ? "⌃⌘F" : "the green button"))") }
        if !fullScreenSpaces().isEmpty { fail("\(mode): \(name) went to a macOS desktop of its own") }
    }
}
func leaveFullScreen(_ name: String, mode: String) {
    guard let w = windows[name] else { return }
    if w.styleMask.contains(.fullScreen) { w.refuseToLeave = false; w.toggleFullScreen(nil); _ = until(4) { !w.styleMask.contains(.fullScreen) }; pump(1.0) }
    else if mode == "baneyspaces", fills(w) { pressFullScreenKey(); pump(0.6) }
}

// MARK: Setup

let ghosttyBefore = state().ws.filter { state().apps[$0.key] == "Ghostty" }
let originalMode = modeBefore
say("probe: BaneySpaces full screen is \(originalMode); Mission Control held off: \(run("/usr/bin/defaults", ["read", "com.apple.dock", "mcx-expose-disabled"]).trimmingCharacters(in: .whitespacesAndNewlines))")
switchTo(1)
_ = make("A", at: NSPoint(x: 60, y: 200))
_ = make("B", at: NSPoint(x: 100, y: 180))
_ = make("C", at: NSPoint(x: 140, y: 160))
waitForWorkspaceList(["A", "B", "C"])
switchTo(2)
_ = make("D", at: NSPoint(x: 80, y: 200))
waitForWorkspaceList(["D"])
switchTo(1)
let full = NSScreen.screens[0].frame
let big = make("E", at: full.origin, size: full.size)
big.setFrame(full, display: true)
waitForWorkspaceList(["E"])
let st0 = state()
for (n, want) in [("A", 1), ("B", 1), ("C", 1), ("D", 2), ("E", 1)] where st0.ws[wid(n)] != want {
    fail("setup: \(n) should be on workspace \(want) and is on \(st0.ws[wid(n)].map(String.init) ?? "none")")
}
verify("setup")

// MARK: Scenarios

for mode in ["baneyspaces", "native"] {
    setMode(mode)
    say("--- mode \(mode)")
    // 1. Ten round trips with a window in full screen, entered both ways.
    for round in 0..<10 {
        enterFullScreen("A", how: round, mode: mode)
        switchTo(2, wait: mode == "native" ? 4 : 2); verify("\(mode) round \(round + 1) at 2")
        switchTo(1, wait: mode == "native" ? 3 : 2); verify("\(mode) round \(round + 1) back at 1")
        requireListed("A", "\(mode) round \(round + 1)")
        leaveFullScreen("A", mode: mode)
    }
    say("\(mode): 10 round trips 1→2→1 done")

    // 2. Three windows in full screen on one workspace, activated in turn.
    for n in ["A", "B", "C"] { enterFullScreen(n, how: 0, mode: mode) }
    let started = Date().timeIntervalSince1970
    var half = 0, desktops = 0
    for id in ["B", "C", "A", "B", "C", "A"] {
        open("baneyspaces://focuswindow/\(wid(id))")
        let end = Date().addingTimeInterval(1.2)
        while Date() < end {
            if !fullScreenSpaces().isEmpty && mode == "baneyspaces" { desktops += 1 }
            let probeIDs = Set(windows.keys.filter { ["A", "B", "C"].contains($0) }.map { wid($0) })
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            for w in list {
                guard let num = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value, probeIDs.contains(num),
                      let b = (w[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }) else { continue }
                let target = ax(NSScreen.screens[0].visibleFrame)
                if mode == "baneyspaces", abs(b.minX - target.minX) > 12 || abs(b.width - target.width) > 12 || abs(b.height - target.height) > 12 { half += 1 }
            }
            usleep(4000)
        }
        verify("\(mode) activating \(id)")
    }
    if mode == "baneyspaces" {
        if half > 0 { fail("baneyspaces: \(half) sampled frame(s) with a window half drawn while activating full-screen windows") }
        if desktops > 0 { fail("baneyspaces: a macOS desktop of its own appeared while activating full-screen windows (a slide)") }
        say("baneyspaces: three full-screen windows activated in turn: \(half) half-drawn frames, \(desktops) desktop slides")
    } else {
        let ids = windows.keys.map { wid($0) }
        let asked = traceLines(since: started).filter { line in line.hasPrefix("fullscreen ask window=") && ids.contains { line.contains("window=\($0) ") } }
        if !asked.isEmpty { fail("native: activating full-screen windows on one workspace asked one to leave: \(asked.first!)") }
        say("native: three full-screen windows activated in turn: \(asked.count) leave-full-screen requests")
    }
    for n in ["A", "B", "C"] { leaveFullScreen(n, mode: mode) }
    switchTo(1); verify("\(mode) after the three")

    // 3. Full screen entered while a switch is in flight.
    open("baneyspaces://switch/2")
    pump(0.05)
    enterFullScreen("A", how: 1, mode: mode)
    pump(mode == "native" ? 5 : 2.5)
    verify("\(mode) full screen during a switch")
    switchTo(1, wait: mode == "native" ? 3 : 2); verify("\(mode) back after the in-flight switch")
    leaveFullScreen("A", mode: mode)

    // 4. A window that will not leave full screen, carried, then closed.
    if mode == "native" {
        windows["A"]!.makeKeyAndOrderFront(nil)
        windows["A"]!.toggleFullScreen(nil); _ = until(4) { windows["A"]!.styleMask.contains(.fullScreen) }; pump(1)
        windows["A"]!.refuseToLeave = true
        switchTo(2, wait: 7); verify("native refusing window carried to 2")
        if state().ws[wid("A")] != 2 { fail("native: the window that would not leave full screen was not carried to workspace 2 (it is on \(state().ws[wid("A")].map(String.init) ?? "none"))") }
        requireListed("A", "native refusing window carried")
        switchTo(1, wait: 4); verify("native refusing window back at 1")
        // Carried, then closed: it must leave nothing behind, and the others stay where they are.
        windows["A"]!.refuseToLeave = false
        let aID = wid("A")
        windows["A"]!.close()
        closed.insert("A")
        pump(2)
        if cg(aID).map({ $0.onScreen }) == true { fail("native: the closed window A is still on screen") }
        verify("native after closing the carried window")
    } else {
        notRun.append("baneyspaces: refused-and-carried (a window cannot refuse a resize; native mode covers it)")
    }

    // 5. A screen-sized window that is not in full screen.
    switchTo(2); verify("\(mode) screen-sized at 2")
    switchTo(1); verify("\(mode) screen-sized back at 1")
    if state().ws[wid("E")] != 1 { fail("\(mode): the screen-sized window E moved to workspace \(state().ws[wid("E")].map(String.init) ?? "none"); it was carried as if in full screen") }

    // 6. A second display.
    if NSScreen.screens.count > 1, let other = NSScreen.screens.dropFirst().first {
        windows["B"]!.setFrameOrigin(NSPoint(x: other.frame.minX + 80, y: other.frame.minY + 120)); pump(1)
        enterFullScreen("B", how: 0, mode: mode)
        switchTo(2, wait: mode == "native" ? 4 : 2); verify("\(mode) second display at 2")
        switchTo(1, wait: mode == "native" ? 3 : 2); verify("\(mode) second display back at 1")
        leaveFullScreen("B", mode: mode)
    } else if mode == "native" {
        notRun.append("second display or Sidecar: one display connected")
    }
}
notRun.append("full-screen video in Helium (a page with a video, needs a person or a page script)")
notRun.append("exit from full screen while its window is hidden or parked (needs a person)")

// MARK: The end

setMode(originalMode)
for n in [1, 2] {
    switchTo(n)
    verify("final, workspace \(n)")
    let st = state()
    for (name, _) in windows where st.ws[wid(name)] == n && !closed.contains(name) {
        if !(cg(wid(name))?.onScreen ?? false) && !inFullScreen(wid(name)) { fail("final: \(name) is on workspace \(n), which is shown, and not on screen") }
    }
}
for (id, n) in ghosttyBefore {
    guard cg(id) != nil else { fail("Ghostty window \(id) vanished"); continue }
    if state().ws[id] != n { fail("Ghostty window \(id) was on workspace \(n) and is on \(state().ws[id].map(String.init) ?? "none")") }
}
switchTo(1)
for (name, w) in windows where !closed.contains(name) { w.close() }
pump(0.5)
for line in notRun { say("not run: \(line)") }
if failures.isEmpty {
    say("PASS: every window existed, was on its workspace and was visible when its workspace was shown, in both modes")
    finish(0)
}
say("FAIL: \(failures.count) problem(s)")
finish(1)
