// Fails unless dragging a window by its title bar down to the Workspace Dock brings the dock up,
// and letting go on another workspace's tile sends the window there in its old spot. It opens a
// window of its own, drags it to the bottom edge with real mouse events, holds it there, checks
// that the dock is up, then slides along the dock until trace.log says the first empty workspace
// is lit, and lets go. A second drag lets go above the dock: the window must stay here.
// Run it with BaneySpaces installed and running, the dock on the bottom edge.
//   swift scripts/dock-drag-probe.swift
// It takes the pointer for about ten seconds; run it while Donovan is away. Before each press it
// checks that its own window is the one under the pointer, and stops if not.
import AppKit

let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/BaneySpaces")
func state() -> (current: Int, workspaces: [Int: [UInt32]]) {
    guard let data = try? Data(contentsOf: folder.appendingPathComponent("state.json")),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let ws = json["workspaces"] as? [String: [[String: Any]]] else { return (0, [:]) }
    var out: [Int: [UInt32]] = [:]
    for (k, v) in ws { out[Int(k) ?? 0] = v.compactMap { ($0["id"] as? NSNumber)?.uint32Value } }
    return ((json["current"] as? Int) ?? 0, out)
}
func workspace(of id: UInt32) -> Int? { state().workspaces.first { $0.value.contains(id) }?.key }
/// The window's workspace once it's on `n`, or the last one seen after another 1.5 s. Called 1.5 s
/// after letting go; the app means to move it within 0.5 s (`dropCarried`), but on 2026-10-30
/// it took longer (#76), so a late move is told apart from none.
func settled(_ id: UInt32, on n: Int) -> Int? {
    var seen = workspace(of: id)
    for _ in 0..<30 where seen != n { usleep(50_000); seen = workspace(of: id) }
    return seen
}
/// trace.log's lines written after `offset`, and the new end.
func traceSince(_ offset: UInt64) -> (lines: [String], end: UInt64) {
    guard let h = try? FileHandle(forReadingFrom: folder.appendingPathComponent("trace.log")) else { return ([], offset) }
    defer { try? h.close() }
    try? h.seek(toOffset: offset)
    let data = h.readDataToEndOfFile()
    return (String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init), offset + UInt64(data.count))
}
func traceEnd() -> UInt64 { traceSince(0).end }

func windows() -> [[String: Any]] {
    CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
}
func bounds(_ w: [String: Any]) -> CGRect? {
    (w[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
}
func onScreen(_ id: UInt32) -> CGRect? {
    windows().first { ($0[kCGWindowNumber as String] as? Int).map(UInt32.init) == id }.flatMap(bounds)
}
/// The Workspace Dock: a BaneySpaces window along the bottom of the screen, short of its full height.
func dockFrame(_ screen: CGRect) -> CGRect? {
    windows().first { w in
        (w[kCGWindowOwnerName as String] as? String) == "BaneySpaces"
            && (bounds(w).map { $0.maxY >= screen.maxY - 12 && $0.height < screen.height / 2 } ?? false)
            && (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.5
    }.flatMap(bounds)
}
/// The owner of the frontmost window under `p`, whatever its layer.
func ownerAt(_ p: CGPoint) -> Int32? {
    windows().first { bounds($0)?.contains(p) == true }.flatMap { $0[kCGWindowOwnerPID as String] as? Int32 }
}

func run(_ path: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    try? p.run()
    p.waitUntilExit()
}
func go(_ n: Int) { run("/usr/bin/open", ["-g", "baneyspaces://switch/\(n)"]); usleep(700_000) }

// Posted at the session tap with a click count: macOS 27 starts a title-bar drag only for those.
func post(_ type: CGEventType, _ p: CGPoint) {
    let e = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type, mouseCursorPosition: p, mouseButton: .left)
    if type != .mouseMoved { e?.setIntegerValueField(.mouseEventClickState, value: 1) }
    e?.post(tap: .cgSessionEventTap)
}
func glide(_ a: CGPoint, _ b: CGPoint, steps: Int = 30, pause: useconds_t = 12_000, until: () -> Bool = { false }) -> CGPoint {
    for i in 1...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        post(.leftMouseDragged, p)
        usleep(pause)
        if until() { return p }
    }
    return b
}

var failures: [String] = []
func expect(_ ok: Bool, _ what: String) {
    print((ok ? "ok    " : "FAIL  ") + what)
    if !ok { failures.append(what) }
}

let screen = NSScreen.main!
let screenRect = CGRect(origin: .zero, size: screen.frame.size)
let start = state()
guard start.current > 0 else { print("BaneySpaces isn't running (no state.json)"); exit(2) }
guard let target = (1...9).first(where: { $0 != start.current && (start.workspaces[$0] ?? []).isEmpty }) else {
    print("no empty workspace to drop on"); exit(2)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let made = NSWindow(contentRect: NSRect(x: 360, y: screen.frame.height - 560, width: 700, height: 400),
                    styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
made.title = "BaneySpaces dock-drag probe"
made.isReleasedWhenClosed = false
made.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
let id = UInt32(made.windowNumber)

/// One drag from the window's title bar down to the bottom edge, held, then `then` with the
/// dock's frame, which returns where to let go.
func dragDown(from window: CGRect, then: (CGRect?) -> CGPoint) {
    let press = CGPoint(x: window.midX, y: window.minY + 12)
    guard ownerAt(press) == getpid() else {
        print("the probe's window isn't under \(press) (owner \(ownerAt(press).map(String.init) ?? "none")); not pressing")
        DispatchQueue.main.sync { made.close() }
        exit(2)
    }
    post(.mouseMoved, press)
    usleep(100_000)
    post(.leftMouseDown, press)
    usleep(150_000)
    let edge = CGPoint(x: screenRect.midX, y: screenRect.maxY - 1)
    _ = glide(press, edge)
    let end = Date().addingTimeInterval(0.6)
    while Date() < end { post(.leftMouseDragged, edge); usleep(30_000) }
    let release = then(dockFrame(screenRect))
    post(.leftMouseUp, release)
    usleep(1_200_000)
}

DispatchQueue.global().async {
    usleep(1_000_000)
    guard let original = onScreen(id) else { print("couldn't open a window"); exit(2) }
    let placedBy = Date().addingTimeInterval(15)
    while workspace(of: id) == nil && Date() < placedBy { usleep(200_000) }
    usleep(800_000)
    expect(workspace(of: id) == start.current, "the new window is on workspace \(start.current)")

    // 1. Down to the dock, then along its tiles until workspace `target` is lit; let go there.
    var mark = traceEnd()
    dragDown(from: original) { dock in
        expect(dock != nil, "the dock came up for the window held on the bottom edge")
        guard let dock else { return CGPoint(x: screenRect.midX, y: screenRect.midY) }
        let row = dock.maxY - 40
        var lit = false
        var at = glide(CGPoint(x: screenRect.midX, y: screenRect.maxY - 1), CGPoint(x: dock.minX + 20, y: row), steps: 15)
        at = glide(at, CGPoint(x: dock.maxX - 20, y: row), steps: 120, pause: 15_000) {
            let (lines, end) = traceSince(mark)
            mark = end
            if lines.contains(where: { $0.hasSuffix("dockCarry target=\(target)") }) { lit = true }
            return lit
        }
        expect(lit, "sliding along the dock lit workspace \(target)")
        return at
    }
    usleep(300_000)
    expect(dockFrame(screenRect) == nil, "the dock went down on letting go")
    let seen = settled(id, on: target)
    expect(seen == target, "the window moved to workspace \(target) (it's on \(seen.map(String.init) ?? "none"))")
    expect(state().current == start.current, "you stayed on workspace \(start.current)")
    go(target)
    let landed = onScreen(id)
    expect(landed.map { abs($0.minX - original.minX) < 3 && abs($0.minY - original.minY) < 3 } ?? false,
           "on workspace \(target) it sits where it was picked up (\(original.origin) → \(landed.map { "\($0.origin)" } ?? "not on screen"))")

    // 2. From there, down to the dock again and let go above it: it stays.
    if let now = onScreen(id) {
        dragDown(from: now) { dock in
            expect(dock != nil, "the dock comes up again from workspace \(target)")
            let above = CGPoint(x: screenRect.midX, y: (dock?.minY ?? screenRect.maxY - 200) - 120)
            return glide(CGPoint(x: screenRect.midX, y: screenRect.maxY - 1), above)
        }
        // 1.2 s have passed since letting go (dragDown); give a wrong move as long as a right one gets.
        usleep(1_800_000)
        let now = workspace(of: id)
        expect(now == target, "let go above the dock, the window stayed on workspace \(target) (it's on \(now.map(String.init) ?? "none"))")
    } else {
        expect(false, "the window is on screen on workspace \(target)")
    }

    DispatchQueue.main.sync { made.close() }
    go(start.current)
    if failures.isEmpty { print("dragging a window to the dock moves it there") } else { exit(1) }
    exit(0)
}
app.run()
