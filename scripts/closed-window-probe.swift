// Fails if a window that can't come forward stays on a workspace. Ghostty keeps windows it closed
// alive in the window server (no script makes one on demand), and a tab behind another tab looks
// the same: alive, off screen, not listed by the app. BaneySpaces kept them, so ⌘Tab, the docks
// and the launcher sent you to a workspace for a window that never came forward. This opens a
// Ghostty window with a second tab on workspace <n>: the tab behind must leave the workspaces.
// Then it closes the front tab: the one behind must come back to workspace <n>. Last, no
// workspace may hold a Ghostty window Ghostty doesn't list. Run it with BaneySpaces installed
// and running and Ghostty open.
//   swift scripts/closed-window-probe.swift 4
// It switches your screen to workspace <n> and leaves you there.
import AppKit

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError
@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopySpacesForWindows") func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ windows: CFArray) -> Unmanaged<CFArray>?
@_silgen_name("CGSCopyManagedDisplaySpaces") func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray
/// Off screen and on no macOS desktop or one being shown: Accessibility can see it from here.
func reachable(_ id: UInt32, offscreen: Bool) -> Bool {
    guard offscreen else { return false }
    let cid = CGSMainConnectionID()
    let spaces = Set((CGSCopySpacesForWindows(cid, 0x7, [id] as CFArray)?.takeRetainedValue() as? [NSNumber] ?? []).map(\.intValue))
    let shown = Set((CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] ?? [])
        .compactMap { ($0["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int })
    return spaces.isEmpty || spaces.isSubset(of: shown)
}

guard let n = CommandLine.arguments.dropFirst().first.flatMap(Int.init), (1...9).contains(n) else {
    FileHandle.standardError.write("usage: swift scripts/closed-window-probe.swift <workspace 1-9>\n".data(using: .utf8)!)
    exit(2)
}
let stateURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/BaneySpaces/state.json")
func workspaces() -> [String: [UInt32]] {
    guard let data = try? Data(contentsOf: stateURL),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let ws = json["workspaces"] as? [String: [[String: Any]]] else { return [:] }
    return ws.mapValues { $0.compactMap { ($0["id"] as? NSNumber)?.uint32Value } }
}
func open(_ url: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-g", url]
    try? p.run()
    p.waitUntilExit()
}
func fail(_ s: String) -> Never { print("FAIL: \(s)"); exit(1) }
func children(_ e: AXUIElement) -> [AXUIElement] {
    var raw: CFTypeRef?
    AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &raw)
    return raw as? [AXUIElement] ?? []
}
func title(_ e: AXUIElement) -> String? {
    var raw: CFTypeRef?
    AXUIElementCopyAttributeValue(e, kAXTitleAttribute as CFString, &raw)
    return raw as? String
}
func axWindows(_ app: AXUIElement) -> [AXUIElement] {
    var raw: CFTypeRef?
    AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
    return raw as? [AXUIElement] ?? []
}
func id(_ e: AXUIElement) -> UInt32? {
    var id: CGWindowID = 0
    return _AXUIElementGetWindow(e, &id) == .success && id != 0 ? id : nil
}
func alive(_ id: UInt32) -> Bool {
    let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    return info.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }
}

guard let ghostty = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.mitchellh.ghostty" }) else {
    fail("Ghostty isn't running")
}
let app = AXUIElementCreateApplication(ghostty.processIdentifier)
open("baneyspaces://switch/\(n)")
Thread.sleep(forTimeInterval: 1)

// Presses a File menu item without bringing Ghostty forward, and returns the window it opened.
func press(_ name: String) -> AXUIElement {
    let before = Set(axWindows(app).compactMap(id))
    var raw: CFTypeRef?
    AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &raw)
    guard let bar = raw.map({ $0 as! AXUIElement }),
          let item = children(bar).filter({ title($0) == "File" }).flatMap(children).flatMap(children)
            .first(where: { title($0) == name }) else { fail("no File > \(name) in Ghostty") }
    AXUIElementPerformAction(item, kAXPressAction as CFString)
    for _ in 0..<100 {
        Thread.sleep(forTimeInterval: 0.03)
        if let w = axWindows(app).first(where: { id($0).map { !before.contains($0) } ?? false }) { return w }
    }
    fail("File > \(name) opened no window")
}
func close(_ w: AXUIElement) {
    var raw: CFTypeRef?
    AXUIElementCopyAttributeValue(w, kAXCloseButtonAttribute as CFString, &raw)
    guard let button = raw.map({ $0 as! AXUIElement }) else { fail("window \(id(w) ?? 0) has no close button") }
    AXUIElementPerformAction(button, kAXPressAction as CFString)
}
/// Any switch looks again; the workspace you're on is the cheapest one.
func rescan() {
    Thread.sleep(forTimeInterval: 1)
    open("baneyspaces://switch/\(n)")
    Thread.sleep(forTimeInterval: 0.8)
}

// A window with a second tab: the window's first tab goes behind.
let window = press("New Window")
let tab = press("New Tab")
guard let wid = id(window), let tid = id(tab) else { fail("no window numbers") }
rescan()
var ws = workspaces()
guard ws[String(n)]?.contains(tid) == true else { close(tab); fail("tab \(tid) never joined workspace \(n)") }
if let on = ws.first(where: { $0.value.contains(wid) })?.key {
    close(tab); Thread.sleep(forTimeInterval: 0.5); close(window)
    fail("tab \(wid), behind another tab, is still on workspace \(on)")
}
// The tab in front closes; the one behind comes forward and must be back where it was.
close(tab)
rescan()
ws = workspaces()
let back = ws[String(n)]?.contains(wid) == true
let closedStays = ws.first(where: { $0.value.contains(tid) })?.key
// No workspace may hold a Ghostty window Ghostty doesn't list (an earlier ghost, too).
let listed = Set(axWindows(app).compactMap(id))
var server: [UInt32: Bool] = [:]
for w in CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
where (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ghostty.processIdentifier {
    if let id = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value { server[id] = (w[kCGWindowIsOnscreen as String] as? Bool) != true }
}
let ghosts = ws.flatMap { n, ids in
    ids.filter { id in server[id].map { !listed.contains(id) && reachable(id, offscreen: $0) } ?? false }.map { "\($0) on \(n)" }
}
close(window)
if let on = closedStays { fail("closed tab \(tid) still on workspace \(on)") }
guard back else { fail("tab \(wid) came forward but isn't back on workspace \(n): \(ws)") }
guard ghosts.isEmpty else { fail("Ghostty windows it doesn't list are on workspaces: \(ghosts.joined(separator: ", "))") }
print("tab behind another tab left the workspaces and came back to \(n) when it came forward; no ghosts")
