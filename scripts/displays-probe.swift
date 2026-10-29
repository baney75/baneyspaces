// Fails unless each display keeps a workspace of its own. Needs two displays (a monitor or
// Sidecar) and BaneySpaces installed and running.
// It opens a window on each display, then switches the display in front (the main one) to an
// empty workspace: the other display must keep its workspace and its window in sight. Going
// to the other display's workspace must go there and change neither display. Then it puts
// everything back and closes its windows.
//   swift scripts/displays-probe.swift
// It takes the keyboard focus for about ten seconds; no clicks or typing.
import AppKit

let stateURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/BaneySpaces/state.json")
func state() -> [String: Any] {
    (try? Data(contentsOf: stateURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
}
func current() -> Int { state()["current"] as? Int ?? 0 }
func displays() -> [String: Int] { state()["displays"] as? [String: Int] ?? [:] }
func workspace(of id: UInt32) -> Int? {
    guard let ws = state()["workspaces"] as? [String: [[String: Any]]] else { return nil }
    return ws.first { $0.value.contains { ($0["id"] as? NSNumber)?.uint32Value == id } }.flatMap { Int($0.key) }
}
func onScreen(_ id: UInt32) -> CGRect? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.first { ($0[kCGWindowNumber as String] as? Int).map(UInt32.init) == id }
        .flatMap { ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } }
}
/// How much of a window shows on the displays (a parked one hangs off a corner).
func shownFraction(_ r: CGRect?) -> CGFloat {
    guard let r, r.width * r.height > 0 else { return 0 }
    var ids = [CGDirectDisplayID](repeating: 0, count: 8); var n: UInt32 = 0
    CGGetActiveDisplayList(8, &ids, &n)
    let shown = ids.prefix(Int(n)).reduce(CGFloat(0)) { sum, d in
        let i = CGDisplayBounds(d).intersection(r)
        return i.isNull ? sum : sum + i.width * i.height
    }
    return shown / (r.width * r.height)
}
func run(_ path: String, _ args: [String]) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    try? p.run(); p.waitUntilExit()
}
func go(_ n: Int) { run("/usr/bin/open", ["-g", "baneyspaces://switch/\(n)"]); usleep(900_000) }

var failures: [String] = []
func expect(_ ok: Bool, _ what: String) {
    print((ok ? "ok    " : "FAIL  ") + what)
    if !ok { failures.append(what) }
}

let screens = NSScreen.screens
guard screens.count >= 2 else { print("needs two displays; found \(screens.count)"); exit(2) }
guard current() > 0 else { print("BaneySpaces isn't running (no state.json)"); exit(2) }
let main = screens[0], other = screens[1]
let app = NSApplication.shared
app.setActivationPolicy(.regular)
func window(on s: NSScreen, _ title: String) -> NSWindow {
    let r = NSRect(x: s.visibleFrame.midX - 250, y: s.visibleFrame.midY - 150, width: 500, height: 300)
    let w = NSWindow(contentRect: r, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    w.title = title
    w.isReleasedWhenClosed = false
    w.makeKeyAndOrderFront(nil)
    return w
}
let here = window(on: main, "BaneySpaces displays probe (main)")
let there = window(on: other, "BaneySpaces displays probe (other)")
app.activate(ignoringOtherApps: true)
here.makeKeyAndOrderFront(nil)
let hereID = UInt32(here.windowNumber), thereID = UInt32(there.windowNumber)

DispatchQueue.global().async {
    let placedBy = Date().addingTimeInterval(15)
    while (workspace(of: hereID) == nil || workspace(of: thereID) == nil) && Date() < placedBy { usleep(200_000) }
    usleep(500_000)
    let start = displays()
    print("      displays: \(start)")
    expect(start.count >= 2, "state.json has a workspace for each display")
    let a = workspace(of: hereID) ?? 0, b = workspace(of: thereID) ?? 0
    expect(a != 0 && b != 0 && a != b, "the two windows are on two workspaces, one per display (\(a), \(b))")
    let used = Set(start.values)
    guard let empty = (1...9).first(where: { !used.contains($0) && $0 != a && $0 != b }) else { print("no free workspace"); exit(2) }

    // 1. The main display goes to an empty workspace; the other keeps its own.
    DispatchQueue.main.sync { app.activate(ignoringOtherApps: true); here.makeKeyAndOrderFront(nil) }
    usleep(300_000)
    go(empty)
    expect(current() == empty, "⌘\(empty) went to workspace \(empty) (current \(current()))")
    expect(Set(displays().values) == Set([empty, b]), "the main display shows \(empty), the other still \(b) (\(displays()))")
    expect(shownFraction(onScreen(thereID)) > 0.9, "the other display's window stayed in sight")
    expect(shownFraction(onScreen(hereID)) < 0.25, "the main display's window went out of sight (parked or hidden)")

    // 2. The other display's workspace: go there, change neither display.
    go(b)
    expect(current() == b, "⌘\(b) went to the other display's workspace (current \(current()))")
    expect(Set(displays().values) == Set([empty, b]), "neither display changed (\(displays()))")

    // 3. Back as it was.
    DispatchQueue.main.sync { app.activate(ignoringOtherApps: true); here.makeKeyAndOrderFront(nil) }
    go(a)
    expect(shownFraction(onScreen(hereID)) > 0.9, "back on \(a), the main display's window is in sight again")
    expect(shownFraction(onScreen(thereID)) > 0.9, "and the other display's window still is")
    DispatchQueue.main.sync { here.close(); there.close() }
    usleep(500_000)
    if failures.isEmpty { print("each display keeps a workspace of its own") } else { exit(1) }
    exit(0)
}
app.run()
