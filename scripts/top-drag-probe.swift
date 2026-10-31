// Fails unless dragging a window to the top of the screen opens BaneySpaces' overview, not
// Mission Control, and letting go over a workspace sends the window there in its old spot.
// It opens a window of its own, drags it by its title bar to the top edge with real mouse events,
// holds it there, checks that the overview is on screen, then lets go over the first empty
// workspace. The window must leave this workspace, and on the target workspace it must sit where
// the drag picked it up. A second drag lets go off the tiles: the window must stay here. Let go
// at the top itself, after a short rest or a long one, and macOS must fill the screen with it.
// Run it with BaneySpaces installed and running.
//   swift scripts/top-drag-probe.swift
// It takes the pointer for about fifteen seconds, visits the target workspace, comes back, and
// closes its window. It needs no AppleScript, so no Automation prompt.
import AppKit

let stateURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/BaneySpaces/state.json")
func state() -> (current: Int, workspaces: [Int: [UInt32]]) {
    guard let data = try? Data(contentsOf: stateURL),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let ws = json["workspaces"] as? [String: [[String: Any]]] else { return (0, [:]) }
    var out: [Int: [UInt32]] = [:]
    for (k, v) in ws { out[Int(k) ?? 0] = v.compactMap { ($0["id"] as? NSNumber)?.uint32Value } }
    return ((json["current"] as? Int) ?? 0, out)
}
func workspace(of id: UInt32) -> Int? { state().workspaces.first { $0.value.contains(id) }?.key }

func windows() -> [[String: Any]] {
    CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
}
func bounds(_ w: [String: Any]) -> CGRect? {
    (w[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
}
func onScreen(_ id: UInt32) -> CGRect? {
    windows().first { ($0[kCGWindowNumber as String] as? Int).map(UInt32.init) == id }.flatMap(bounds)
}
/// BaneySpaces' overview: one of its windows over most of the screen.
func overviewUp(_ screen: CGRect) -> Bool {
    windows().contains { w in
        (w[kCGWindowOwnerName as String] as? String) == "BaneySpaces"
            && (bounds(w).map { $0.width >= screen.width * 0.9 && $0.height >= screen.height * 0.9 } ?? false)
    }
}
/// Mission Control: the Dock covers the screen with a window of its own.
func missionControlUp(_ screen: CGRect) -> Bool {
    windows().contains { w in
        (w[kCGWindowOwnerName as String] as? String) == "Dock" && (w[kCGWindowLayer as String] as? Int ?? 0) > 0
            && (bounds(w).map { $0.width >= screen.width * 0.9 && $0.height >= screen.height * 0.9 } ?? false)
            && (w[kCGWindowAlpha as String] as? Double ?? 1) > 0
    }
}

func run(_ path: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    try? p.run()
    p.waitUntilExit()
}
func go(_ n: Int) { run("/usr/bin/open", ["-g", "baneyspaces://switch/\(n)"]); usleep(700_000) }

// Posted at the session tap with a click count: macOS 27 starts a title-bar drag only for
// those (measured: events at the HID tap, or without a click count, never moved the window).
func post(_ type: CGEventType, _ p: CGPoint) {
    let e = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type, mouseCursorPosition: p, mouseButton: .left)
    if type != .mouseMoved { e?.setIntegerValueField(.mouseEventClickState, value: 1) }
    e?.post(tap: .cgSessionEventTap)
}
/// Presses on `from`, glides to `to`, rests there `hold` seconds, glides to `release`, lets go.
/// `check` runs just before leaving `to`; letting go at `to` itself follows the rest at once.
func drag(from: CGPoint, to: CGPoint, hold: TimeInterval, release: CGPoint, check: () -> Void) {
    post(.mouseMoved, from)
    usleep(100_000)
    post(.leftMouseDown, from)
    usleep(150_000)
    func glide(_ a: CGPoint, _ b: CGPoint) {
        for i in 1...30 {
            let t = CGFloat(i) / 30
            post(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            usleep(12_000)
        }
    }
    glide(from, to)
    let end = Date().addingTimeInterval(hold)
    while Date() < end { post(.leftMouseDragged, to); usleep(30_000) }
    print("      held at \(to); the window is at \(onScreen(id).map { "\($0.origin)" } ?? "nowhere") (picked up at \(from))")
    check()
    if release != to {
        glide(to, release)
        usleep(150_000)
    }
    post(.leftMouseUp, release)
    usleep(1_200_000)
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

// A window of the probe's own in the middle of the screen, away from the top. The gesture runs
// on a background thread while the main thread runs the app, so the window answers the drag.
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let made = NSWindow(contentRect: NSRect(x: 360, y: screen.frame.height - 760, width: 700, height: 500),
                    styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
made.title = "BaneySpaces top-drag probe"
made.isReleasedWhenClosed = false
made.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
let id = UInt32(made.windowNumber)
func cleanup() { DispatchQueue.main.sync { made.close() } }

DispatchQueue.global().async {
usleep(1_000_000)
guard let original = onScreen(id) else { print("couldn't open a window"); exit(2) }
// BaneySpaces places a new window on its next scan; a new app's first one can wait out a heal (3, 6, then 12 s).
let placedBy = Date().addingTimeInterval(15)
while workspace(of: id) == nil && Date() < placedBy { usleep(200_000) }
usleep(800_000)
expect(workspace(of: id) == start.current, "the new window is on workspace \(start.current)")

// The tile's middle, laid out as ViewerView lays it out: 48 pt padding, 20 pt gaps, a 40 pt
// footer, at most 1600 pt wide. Tiles are a few hundred points tall, so a few points off is fine.
// SwiftUI lays it out below the camera housing on a Mac with a notch.
func tileCenter(_ n: Int) -> CGPoint {
    let inset = screen.safeAreaInsets.top
    let height = screenRect.height - inset
    let w = min(screenRect.width, 1600) - 96
    let left = (screenRect.width - min(screenRect.width, 1600)) / 2 + 48
    let tileW = (w - 40) / 3
    let tileH = max(160, (height - 96 - 40 - 40) / 3)
    let top = inset + (height - (3 * tileH + 40 + 18 + 40)) / 2
    let col = CGFloat((n - 1) % 3), row = CGFloat((n - 1) / 3)
    return CGPoint(x: left + col * (tileW + 20) + tileW / 2, y: top + row * (tileH + 20) + tileH / 2)
}

let titleBar = CGPoint(x: original.midX, y: original.minY + 12)
let topEdge = CGPoint(x: original.midX, y: 0)

// 1. Up to the top, rest, let go over the empty workspace.
drag(from: titleBar, to: topEdge, hold: 0.8, release: tileCenter(target)) {
    expect(overviewUp(screenRect), "the overview is up while the window is held at the top")
    expect(!missionControlUp(screenRect), "Mission Control stayed closed")
}
expect(!overviewUp(screenRect), "the overview closed on letting go")
usleep(300_000)
expect(NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid(), "the keyboard left the moved window")
expect(workspace(of: id) == target, "the window moved to workspace \(target) (it's on \(workspace(of: id).map(String.init) ?? "none"))")
expect(state().current == start.current, "you stayed on workspace \(start.current)")
go(target)
let landed = onScreen(id)
expect(landed.map { abs($0.minX - original.minX) < 3 && abs($0.minY - original.minY) < 3 } ?? false,
       "on workspace \(target) it sits where it was picked up (\(original.origin) → \(landed.map { "\($0.origin)" } ?? "not on screen"))")

// 2. From there, up to the top again and let go off the tiles, on the footer: it stays.
if let now = onScreen(id) {
    let release = CGPoint(x: screenRect.midX, y: screenRect.height - 20)
    drag(from: CGPoint(x: now.midX, y: now.minY + 12), to: CGPoint(x: now.midX, y: 0), hold: 0.8, release: release) {
        expect(overviewUp(screenRect), "the overview opens again from workspace \(target)")
    }
    expect(workspace(of: id) == target, "let go off the tiles, the window stayed on workspace \(target)")
    let dropped = onScreen(id)
    expect(dropped.map { $0.minY > now.minY + 200 } ?? false,
           "and it stayed where it was let go, not back at its pick-up spot (\(dropped.map { "\($0.origin)" } ?? "not on screen"))")
} else {
    expect(false, "the window is on screen on workspace \(target)")
}

cleanup()
go(start.current)

// 3. A window already against the menu bar can't move up; its title bar pushed up still counts.
let top = screen.visibleFrame.maxY
let pinned = DispatchQueue.main.sync { () -> NSWindow in
    let w = NSWindow(contentRect: NSRect(x: 300, y: top - 500, width: 800, height: 500),
                     styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    w.title = "BaneySpaces top-drag probe (pinned)"
    w.isReleasedWhenClosed = false
    w.setFrameTopLeftPoint(NSPoint(x: 300, y: top))
    w.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    return w
}
usleep(1_000_000)
let pinnedID = UInt32(pinned.windowNumber)
let placedPinned = Date().addingTimeInterval(15)
while workspace(of: pinnedID) == nil && Date() < placedPinned { usleep(200_000) }
if let p = onScreen(pinnedID) {
    drag(from: CGPoint(x: p.midX, y: p.minY + 12), to: CGPoint(x: p.midX, y: 0), hold: 0.8, release: tileCenter(target)) {
        expect(onScreen(pinnedID).map { abs($0.minY - p.minY) < 2 } ?? false, "the window against the menu bar didn't move (\(p.origin))")
        expect(overviewUp(screenRect), "pushing its title bar up opens the overview")
    }
    expect(workspace(of: pinnedID) == target, "and letting go over workspace \(target) sends it there")
} else {
    expect(false, "a window against the menu bar is on screen")
}
DispatchQueue.main.sync { pinned.close() }

// 4. The arrow keys move the overview's highlight; Return goes there.
func key(_ code: CGKeyCode) {
    for down in [true, false] {
        CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: code, keyDown: down)?.post(tap: .cgSessionEventTap)
        usleep(30_000)
    }
}
let from = state().current
let col = (from - 1) % 3
let expected = col < 2 ? from + 1 : from - 1
// The pointer off the tiles, so no tile is hovered and the highlight starts on this workspace.
post(.mouseMoved, CGPoint(x: screenRect.midX, y: screenRect.height - 20))
usleep(200_000)
run("/usr/bin/open", ["-g", "baneyspaces://viewer"])
// Keys are typed only once the overview has the keyboard: never into whatever app is in front.
let keysBy = Date().addingTimeInterval(2)
func overviewHasKeys() -> Bool {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.baney.baneyspaces" && overviewUp(screenRect)
}
while !overviewHasKeys() && Date() < keysBy { usleep(50_000) }
if overviewHasKeys() {
    usleep(300_000)
    key(col < 2 ? 124 : 123)   // → or ←
    usleep(300_000)
    key(36)                     // Return
    let switchedBy = Date().addingTimeInterval(2)
    while state().current != expected && Date() < switchedBy { usleep(100_000) }
    expect(state().current == expected, "→/← then Return went from workspace \(from) to \(expected) (on \(state().current))")
} else {
    expect(false, "the overview took the keyboard (in front: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"), overview \(overviewUp(screenRect) ? "up" : "not up"))")
    if overviewUp(screenRect) { run("/usr/bin/open", ["-g", "baneyspaces://viewer"]) }
}
go(start.current)

// 5. Let go at the top and macOS fills the screen with the window, whether the overview opened
// or not (Donovan, 2026-10-28: the drag had stopped filling the screen).
let home = NSRect(x: 360, y: screen.frame.height - 760, width: 700, height: 500)
let filler = DispatchQueue.main.sync { () -> NSWindow in
    let w = NSWindow(contentRect: home, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    w.title = "BaneySpaces top-drag probe (fill)"
    w.isReleasedWhenClosed = false
    w.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    return w
}
usleep(1_000_000)
let fillID = UInt32(filler.windowNumber)
let placedFiller = Date().addingTimeInterval(15)
while workspace(of: fillID) == nil && Date() < placedFiller { usleep(200_000) }
let visible = CGRect(x: screen.visibleFrame.minX, y: screen.frame.maxY - screen.visibleFrame.maxY,
                     width: screen.visibleFrame.width, height: screen.visibleFrame.height)
// Most of the visible screen, its top at the menu bar: macOS's fill, not an exact frame.
func fills(_ r: CGRect?) -> Bool {
    r.map { abs($0.minY - visible.minY) < 12 && $0.width >= visible.width * 0.9 && $0.height >= visible.height * 0.85 } ?? false
}
// TopDrag.dwell, the rest before the overview opens; the probe can't import it.
let dwell = 0.25
// The short rest stays under the dwell but long enough for macOS's own fill: at 0.1 s macOS
// sometimes didn't fill at all (2026-10-30, #73).
for (hold, what) in [(dwell * 0.72, "a short rest"), (dwell + 1.0, "a rest long enough to open the overview")] {
    DispatchQueue.main.sync { filler.setFrame(filler.frameRect(forContentRect: home), display: true); filler.makeKeyAndOrderFront(nil) }
    usleep(600_000)
    guard let f = onScreen(fillID) else { expect(false, "the fill window is on screen"); break }
    let edge = CGPoint(x: f.midX, y: 0)
    var opened = false
    drag(from: CGPoint(x: f.midX, y: f.minY + 12), to: edge, hold: hold, release: edge) { opened = overviewUp(screenRect) }
    expect(hold < dwell ? !opened : opened, "after \(what) the overview \(opened ? "opened" : "stayed shut")")
    expect(!missionControlUp(screenRect), "Mission Control stayed closed")
    // macOS animates the fill; give it up to 2 s.
    let fillBy = Date().addingTimeInterval(2)
    while !fills(onScreen(fillID)) && Date() < fillBy { usleep(100_000) }
    expect(fills(onScreen(fillID)), "let go at the top after \(what), the window fills the screen (\(onScreen(fillID).map { "\($0)" } ?? "not on screen"), screen \(visible))")
    expect(workspace(of: fillID) == start.current, "and it stayed on workspace \(start.current)")
}
DispatchQueue.main.sync { filler.close() }

if failures.isEmpty { print("top drag opens the overview, moves the window, and fills the screen") } else { exit(1) }
exit(0)
}
app.run()
