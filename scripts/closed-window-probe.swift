// Fails if a window an app closed stays on a workspace. Ghostty keeps every window it closes
// alive in the window server; BaneySpaces kept them too, so ⌘Tab, the docks and the launcher
// sent you to a workspace for a window that never came forward. This opens a Ghostty window on
// workspace <n>, closes it, and reads state.json. Run it with BaneySpaces installed and running
// and Ghostty open.
//   swift scripts/closed-window-probe.swift 4
// It switches your screen to workspace <n> and leaves you there.
import AppKit

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

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

// File > New Window, pressed without bringing Ghostty forward: the window opens here.
let before = Set(axWindows(app).compactMap(id))
guard let bar = { () -> AXUIElement? in
    var raw: CFTypeRef?
    AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &raw)
    return raw.map { $0 as! AXUIElement }
}(), let item = children(bar).filter({ title($0) == "File" }).flatMap(children).flatMap(children)
    .first(where: { title($0) == "New Window" }) else { fail("no File > New Window in Ghostty") }
AXUIElementPerformAction(item, kAXPressAction as CFString)
var new: AXUIElement?
for _ in 0..<100 where new == nil {
    Thread.sleep(forTimeInterval: 0.03)
    new = axWindows(app).first { id($0).map { !before.contains($0) } ?? false }
}
guard let window = new, let wid = id(window) else { fail("Ghostty opened no window") }
Thread.sleep(forTimeInterval: 1.2)
open("baneyspaces://switch/\(n)")
Thread.sleep(forTimeInterval: 0.8)
guard workspaces()[String(n)]?.contains(wid) == true else { fail("window \(wid) never joined workspace \(n)") }

var raw: CFTypeRef?
AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &raw)
guard let close = raw.map({ $0 as! AXUIElement }) else { fail("window \(wid) has no close button") }
AXUIElementPerformAction(close, kAXPressAction as CFString)
Thread.sleep(forTimeInterval: 1)
// Any switch looks again; the workspace you're on is the cheapest one.
open("baneyspaces://switch/\(n)")
Thread.sleep(forTimeInterval: 0.8)

let kept = alive(wid)
if let ws = workspaces().first(where: { $0.value.contains(wid) })?.key {
    fail("closed window \(wid) still on workspace \(ws) (window server \(kept ? "keeps" : "dropped") it)")
}
print("closed window \(wid) left the workspaces (window server \(kept ? "keeps it alive, the case this guards" : "dropped it; Ghostty didn't keep this one"))")
