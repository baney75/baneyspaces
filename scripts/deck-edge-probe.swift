// Rests the pointer on the left screen edge with a Deck app in front, as Donovan did on 10-23,
// and reads the Deck's state from deck.json: it must open once and stay open while the pointer
// rests there, then close once the pointer goes off to the right. Closed while the pointer rests
// there, it must stay shut through a small drift. Before the fix it opened and closed about every 1.6 s.
//
// Usage: swift scripts/deck-edge-probe.swift   (BaneySpaces running, an app the Deck covers in front,
// the Deck unpinned and closed). Puts the pointer back where it was.
import AppKit

let state = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/BaneySpaces/deck.json")

func deck() -> (open: Bool, visible: Bool, pinned: Bool)? {
    guard let data = try? Data(contentsOf: state),
          let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return (j["open"] as? Bool ?? false, j["sidebarVisible"] as? Bool ?? false, j["pinned"] as? Bool ?? false)
}

func move(to p: CGPoint) {
    let e = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: .mouseMoved,
                    mouseCursorPosition: p, mouseButton: .left)
    e?.post(tap: .cgSessionEventTap)
}

/// Samples whether the sidebar is up every 20 ms for `seconds`; the number of times it changed.
func watch(_ seconds: Double, nudge: CGPoint? = nil) -> (changes: Int, last: Bool) {
    var last = deck()?.visible ?? false
    var changes = 0
    let end = Date().addingTimeInterval(seconds)
    var i = 0
    while Date() < end {
        // A hand resting on a mouse jitters by a point; so does this.
        if let n = nudge { move(to: CGPoint(x: n.x + CGFloat(i % 2), y: n.y)) }
        i += 1
        Thread.sleep(forTimeInterval: 0.02)
        let v = deck()?.visible ?? last
        if v != last { changes += 1; last = v }
    }
    return (changes, last)
}

guard let d = deck() else { print("no deck.json: is BaneySpaces running with the Deck on?"); exit(2) }
guard !d.pinned else { print("the Deck is pinned; unpin it to probe the drawer"); exit(2) }
guard !d.visible else { print("the Deck is open; close it first"); exit(2) }
let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
let screen = NSScreen.screens[0].frame
let home = CGEvent(source: nil)?.location ?? CGPoint(x: screen.midX, y: screen.midY)
print("front app: \(front); sidebar up: \(d.visible)")

var failed = false
func check(_ ok: Bool, _ what: String) {
    print("\(ok ? "ok  " : "FAIL") \(what)")
    if !ok { failed = true }
}

// Start away from the edge with the drawer shut.
move(to: CGPoint(x: screen.midX, y: screen.midY))
_ = watch(1.5)
let edge = CGPoint(x: 0, y: screen.height * 0.62)
move(to: edge)
let rest = watch(4, nudge: edge)
check(rest.last && rest.changes == 1, "resting on the edge opened it once and it stayed (changes: \(rest.changes))")
move(to: CGPoint(x: screen.midX, y: screen.midY))
let away = watch(1.5)
check(!away.last && away.changes == 1, "moving away to the right closed it once (changes: \(away.changes))")

// Closed with ⌘⇧B's toggle (no keystroke: the CLI) while the pointer rests on the edge, drifting a
// few points: it must stay shut until the pointer moves clearly away.
move(to: edge)
let reopened = watch(1.5, nudge: edge)
check(reopened.last, "resting on the edge opened it again")
let cli = Process()
cli.executableURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/baneyspaces")
cli.arguments = ["sidebar"]
cli.standardOutput = FileHandle.nullDevice
try? cli.run(); cli.waitUntilExit()
var shut = (changes: 0, last: true)
for x in [0, 3, 1, 4, 0, 2] {
    let r = watch(0.3, nudge: CGPoint(x: CGFloat(x), y: edge.y))
    shut = (shut.changes + r.changes, r.last)
}
check(!shut.last && shut.changes == 1, "closed while resting, a drift of a few points didn't reopen it (changes: \(shut.changes))")
move(to: CGPoint(x: screen.midX, y: screen.midY))
_ = watch(0.5)
move(to: edge)
let back = watch(1.5, nudge: edge)
check(back.last, "after moving away, resting on the edge opens it again")
move(to: CGPoint(x: screen.midX, y: screen.midY))
_ = watch(1.5)
move(to: home)
exit(failed ? 1 : 0)
