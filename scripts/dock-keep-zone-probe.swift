// The Workspace Dock goes down once the pointer leaves the bar you see (2026-10-31).
//
// It stayed up with the pointer 25-50 pt above or beside the bar: the zone that kept it up came
// from the panel, which keeps a row for the hover label above the bar and is at least 480 pt
// long. This brings the bottom dock up from the screen's edge with the real pointer, then rests
// the pointer (1) on a tile: the dock must stay up; (2) 10 pt above the panel: it must go down;
// (3) brings it up again and rests 10 pt beside the panel: it must go down; (4) rests on the edge
// past the bar's end: a dock that comes up there must stay up. Before the fix it stayed up in (2)
// and (3); before the review fix it flashed in (4).
//
// It takes the pointer for about ten seconds and puts it back; run it while Donovan is away.
// Bottom dock only. Prints "dock let go" and exits 0 on success; exits 1 with the step that failed.
//
//   swift scripts/dock-keep-zone-probe.swift
import AppKit

let main = NSScreen.screens[0].frame // the primary screen: CG coordinates start at its top left

func move(_ p: CGPoint) { // CG coordinates
    CGWarpMouseCursorPosition(p)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}

/// The dock's panel on screen, in CG coordinates: BaneySpaces' window at the status bar level.
func dock() -> CGRect? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let level = Int(CGWindowLevelForKey(.statusWindow))
    for w in list where (w[kCGWindowOwnerName as String] as? String) == "BaneySpaces"
        && (w[kCGWindowLayer as String] as? Int) == level && (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.5 {
        if let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b),
           r.maxY >= main.height - 40 { return r }
    }
    return nil
}

func wait(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

func until(_ s: Double, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(s)
    while Date() < end { if cond() { return true }; wait(0.05) }
    return cond()
}

let start = CGEvent(source: nil)?.location ?? CGPoint(x: main.midX, y: main.midY)
func fail(_ why: String) -> Never { move(start); print("FAIL: \(why)"); exit(1) }

func bringUp() -> CGRect {
    move(CGPoint(x: main.midX, y: main.height / 2))
    guard until(1.5, { dock() == nil }) else { fail("the dock was up before the probe started") }
    wait(0.3)
    move(CGPoint(x: main.midX, y: main.height - 1))
    guard until(1.5, { dock() != nil }) else { fail("the dock didn't come up from the bottom edge (is it on the bottom?)") }
    wait(0.4) // the slide-in and the first layout
    return dock()!
}

var panel = bringUp()
// (1) On the bar: its tiles sit at the panel's bottom, below the label row.
move(CGPoint(x: panel.midX, y: panel.maxY - 40))
wait(1.2)
guard dock() != nil else { fail("the dock went down with the pointer on its bar") }
print("on the bar: stays up")

// (2) 10 pt above the panel: 42 pt or more above the bar, inside the old 24 pt slack around the panel.
move(CGPoint(x: panel.midX, y: panel.minY - 10))
guard until(1.2, { dock() == nil }) else { fail("the dock stayed up with the pointer 10 pt above its panel") }
print("above the panel: went down")

// (3) 10 pt beside the panel, at the bar's height.
panel = bringUp()
move(CGPoint(x: panel.maxX + 10, y: panel.maxY - 40))
guard until(1.2, { dock() == nil }) else { fail("the dock stayed up with the pointer 10 pt beside its panel") }
print("beside the panel: went down")

// (4) Resting on the edge past the bar's end but inside the panel's length: the dock may come up
// there or not, but one that comes up must stay up. Sized from the panel, it came up and dropped
// 0.4 s later with the pointer still (review of #91).
move(CGPoint(x: main.midX, y: main.height / 2))
guard until(1.5, { dock() == nil }) else { fail("the dock didn't go down before step 4") }
wait(0.3)
move(CGPoint(x: main.midX + panel.width / 2 - 20, y: main.height - 1))
var cameUp = false
for _ in 0..<40 {
    wait(0.05)
    if dock() != nil { cameUp = true } else if cameUp { fail("the dock came up past the bar's end and dropped with the pointer still") }
}
print(cameUp ? "past the bar's end: came up and stayed" : "past the bar's end: stayed down")

move(start)
print("dock let go")
