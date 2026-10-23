// Fails unless dragging a window to the top of the screen opens BaneySpaces' overview, not
// Mission Control, and letting go over a workspace sends the window there in its old spot.
// It opens a TextEdit window, drags it by its title bar to the top edge with real mouse events,
// holds it there, checks that the overview is on screen, then lets go over the first empty
// workspace. The window must leave this workspace, and on the target workspace it must sit where
// the drag picked it up. A second drag lets go off the tiles: the window must stay here.
// Run it with BaneySpaces installed and running.
//   swift scripts/top-drag-probe.swift
// It takes the pointer for about ten seconds, visits the target workspace, comes back, and
// closes the TextEdit window it made.
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
func osascript(_ s: String) { run("/usr/bin/osascript", ["-e", s]) }
func go(_ n: Int) { run("/usr/bin/open", ["-g", "baneyspaces://switch/\(n)"]); usleep(700_000) }

func post(_ type: CGEventType, _ p: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}
/// Presses on `from`, glides to `to`, rests there `hold` seconds, glides to `release`, lets go.
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
    check()
    glide(to, release)
    usleep(150_000)
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

// A TextEdit window in the middle of the screen, away from the top.
let before = Set(windows().compactMap { $0[kCGWindowNumber as String] as? Int })
osascript("""
    tell application "TextEdit"
        activate
        make new document with properties {text:"BaneySpaces top-drag probe"}
        set bounds of front window to {360, 260, 1060, 760}
    end tell
    """)
usleep(1_000_000)
guard let made = windows().first(where: { w in
    (w[kCGWindowOwnerName as String] as? String) == "TextEdit" && (w[kCGWindowLayer as String] as? Int) == 0
        && !before.contains(w[kCGWindowNumber as String] as? Int ?? 0)
}), let id = (made[kCGWindowNumber as String] as? Int).map(UInt32.init), let original = bounds(made) else {
    print("couldn't open a TextEdit window"); exit(2)
}
func cleanup() {
    osascript("tell application \"TextEdit\" to close (every document whose text is \"BaneySpaces top-drag probe\") saving no")
}
usleep(800_000)
expect(workspace(of: id) == start.current, "the new window is on workspace \(start.current)")

// The tile's middle, laid out as ViewerView lays it out: 48 pt padding, 20 pt gaps, a 40 pt
// footer, at most 1600 pt wide. Tiles are a few hundred points tall, so a few points off is fine.
func tileCenter(_ n: Int) -> CGPoint {
    let w = min(screenRect.width, 1600) - 96
    let left = (screenRect.width - min(screenRect.width, 1600)) / 2 + 48
    let tileW = (w - 40) / 3
    let tileH = max(160, (screenRect.height - 96 - 40 - 40) / 3)
    let top = (screenRect.height - (3 * tileH + 40 + 18 + 40)) / 2
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
expect(workspace(of: id) == target, "the window moved to workspace \(target) (it's on \(workspace(of: id).map(String.init) ?? "none"))")
expect(state().current == start.current, "you stayed on workspace \(start.current)")
go(target)
let landed = onScreen(id)
expect(landed.map { abs($0.minX - original.minX) < 3 && abs($0.minY - original.minY) < 3 } ?? false,
       "on workspace \(target) it sits where it was picked up (\(original.origin) → \(landed.map { "\($0.origin)" } ?? "not on screen"))")

// 2. From there, up to the top again and let go off the tiles, on the footer: it stays.
osascript("tell application \"TextEdit\" to activate")
usleep(400_000)
if let now = onScreen(id) {
    drag(from: CGPoint(x: now.midX, y: now.minY + 12), to: CGPoint(x: now.midX, y: 0), hold: 0.8,
         release: CGPoint(x: screenRect.midX, y: screenRect.height - 20)) {
        expect(overviewUp(screenRect), "the overview opens again from workspace \(target)")
    }
    expect(workspace(of: id) == target, "let go off the tiles, the window stayed on workspace \(target)")
} else {
    expect(false, "the window is on screen on workspace \(target)")
}

cleanup()
go(start.current)
if failures.isEmpty { print("top drag opens the overview and moves the window") } else { exit(1) }
