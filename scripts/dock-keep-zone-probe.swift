// The Workspace Dock goes down once the pointer leaves the bar you see (2026-10-31).
//
// It stayed up with the pointer 25-50 pt above or beside the bar: the zone that kept it up came
// from the panel, which keeps a row for the hover label above the bar and is at least 480 pt
// long. This brings the bottom dock up from the screen's edge with the real pointer, then rests
// the pointer (1) on a tile: the dock must stay up; (2) 10 pt above the panel: it must go down;
// (3) brings it up again and rests 10 pt beside the panel: it must go down. Before the fix it
// stayed up in (2) and (3).
//
// It takes the pointer for about eight seconds and puts it back; run it while Donovan is away.
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

move(start)
print("dock let go")
