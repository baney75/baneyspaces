// bench-sample: the screen-change monitor's eyes. Every 50 ms (--interval-ms) it reads
//   front      the frontmost app (bundle id and pid)
//   workspace  BaneySpaces' current workspace (state.json "current")
//   pointer    the pointer position
//   key        the front-most normal window on screen (window id and owner pid)
//   user_window    a window id that newly appears on a workspace other than the agent workspace
//                  (state.json), i.e. a window on one of Donovan's workspaces
//   unplaced_window  a new on-screen normal window that state.json lists on no workspace for a full
//                  second (a debounce: BaneySpaces writes state.json a moment after a window appears)
// Every window event carries {id, pid, owner}. `user_pids` lists the processes that own a window on one of
// Donovan's workspaces, so the harness can snapshot at the start of a task which windows are his own background
// apps'. A delayed window event (unplaced_window) is its own line with its own first-seen time; it is never
// merged into the current sample's changes. A sheet, alert or popover belongs to its parent window: a window that state.json
// does not list, owned by a process that owns an agent-workspace window and lying inside that window's
// frame (8 pt slack), is a child. It is neither `unplaced_window` nor the key window.
//
// Input: a listen-only event tap counts keyboard, mouse and scroll events and reads each one's source
// process id. Pid 0 is real hardware (Donovan). A program's event counts as the column's own (`posted`) only if
// the poster is in a process group the harness registered in --allow-file (or is the harness itself); an event
// from ANY other pid is counted as real input, because a remapper or scroll tool of Donovan's looks the same. `input` lines carry {real: n, posted: {pid: n}}. Needs Input Monitoring; when
// the tap cannot be created `tap` is false in the start line and the harness falls back to HID idle time.
//
// A tap the system disables is switched back on and reported (`tap_disabled`: a lost monitor). HID activity that
// no tap event explains is reported as `hid` with real: true.
//
// Session: `session` lines say whether the screen is locked, the display asleep, the session off the
// console, loginwindow in front, or secure keyboard input on (keystrokes then never reach the tap).
//
// It prints a "beat" on EVERY sample (the harness treats 200 ms without one, or the process exiting, as a
// lost monitor), one JSON line when anything above changes, and a "hid" line while HID idle < 5 s.
// Read-only: it posts no events.
import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
var intervalMs = 50
if let i = CommandLine.arguments.firstIndex(of: "--interval-ms"), i + 1 < CommandLine.arguments.count,
   let v = Int(CommandLine.arguments[i + 1]) { intervalMs = max(10, v) }
var allowFile = ""
if let i = CommandLine.arguments.firstIndex(of: "--allow-file"), i + 1 < CommandLine.arguments.count { allowFile = CommandLine.arguments[i + 1] }
var allowVersion = -1
var allowPgids = Set<Int>()
var allowPids = Set<Int>()
var pidGroup: [Int: Int] = [:]            // poster pid -> its process group, learned while it was alive
var graceUntil: [Int: Double] = [:]       // process group -> when it stops being recognised after it left the file
let postedGraceS = 2.0
/// Reload the allow file when its VERSION changes (not its mtime: two writes in one tick must not be missed), keep a
/// group that just left the file recognised for postedGraceS, and acknowledge the version.
func refreshAllow() {
    guard !allowFile.isEmpty,
          let data = FileManager.default.contents(atPath: allowFile),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let v = obj["version"] as? Int, v != allowVersion else { return }
    let now = Date().timeIntervalSince1970
    let newPgids = Set((obj["pgids"] as? [Int]) ?? [])
    for g in allowPgids.subtracting(newPgids) { graceUntil[g] = now + postedGraceS }
    for g in newPgids { graceUntil[g] = nil }
    allowPgids = newPgids
    allowPids = Set((obj["pids"] as? [Int]) ?? [])
    allowVersion = v
    emit(["event": "allow", "t": now, "version": v])
}
/// Is the poster one of the harness's own commands (its process group) or the harness? Each registered command is its own
/// group leader (pgid == pid), so a poster that already exited is still matched by its pid; a grandchild is matched through the
/// group it had while alive (cached), which stays valid for postedGraceS after its group is retired.
func ownPoster(_ pid: Int) -> Bool {
    let now = Date().timeIntervalSince1970
    if allowPids.contains(pid) || allowPgids.contains(pid) { return true }
    if let g = pidGroup[pid] {
        if allowPgids.contains(g) { return true }
        if let until = graceUntil[g], until > now { return true }
    }
    let g = Int(getpgid(pid_t(pid)))
    if g > 0 {
        if allowPgids.contains(g) { pidGroup[pid] = g; return true }
        if let until = graceUntil[g], until > now { pidGroup[pid] = g; return true }
    }
    if let until = graceUntil[pid], until > now { return true }     // a retired leader that exited before delivery
    return false
}
let statePath = NSHomeDirectory() + "/Library/Application Support/BaneySpaces/state.json"

struct Snap: Equatable {
    var front = ""
    var frontPid = 0
    var workspace = -1
    var px = 0.0, py = 0.0
    var key = 0
    var keyPid = 0
}
struct Win { var id: Int; var pid: Int; var owner: String; var r: CGRect }

var stateStamp: (Date, Int)? = nil
var stateCurrent = -1
var stateUser = Set<Int>()    // window ids on workspaces other than the agent workspace
var stateAgent = Set<Int>()   // window ids on the agent workspace
var stateAll = Set<Int>()     // window ids on any workspace
var agentWins: [Win] = []     // frames of the agent workspace's windows (refreshed once a second)
var agentPids = Set<Int>()
var userPids = Set<Int>()     // processes owning a window on one of Donovan's workspaces

func workspace() -> Int {
    let attrs = try? FileManager.default.attributesOfItem(atPath: statePath)
    let stamp = ((attrs?[.modificationDate] as? Date) ?? .distantPast, (attrs?[.size] as? Int) ?? 0)
    if let s = stateStamp, s == stamp { return stateCurrent }
    stateStamp = stamp
    if let data = FileManager.default.contents(atPath: statePath),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let cur = obj["current"] as? Int {
        stateCurrent = cur
        let agent = obj["agentWorkspace"] as? Int ?? -1
        var user = Set<Int>(), ag = Set<Int>(), all = Set<Int>()
        for (ws, wins) in (obj["workspaces"] as? [String: [[String: Any]]]) ?? [:] {
            for w in wins {
                guard let id = w["id"] as? Int else { continue }
                all.insert(id)
                if Int(ws) == agent { ag.insert(id) } else { user.insert(id) }
            }
        }
        stateUser = user; stateAgent = ag; stateAll = all
        refreshAgentWindows()
    }
    return stateCurrent
}

func windows(onScreenOnly: Bool) -> [Win] {
    let opts: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
    var out: [Win] = []
    for w in list {
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
              let b = w[kCGWindowBounds as String] as? [String: Double],
              (b["Width"] ?? 0) > 60, (b["Height"] ?? 0) > 40,
              let id = w[kCGWindowNumber as String] as? Int else { continue }
        out.append(Win(id: id, pid: w[kCGWindowOwnerPID as String] as? Int ?? 0,
                       owner: w[kCGWindowOwnerName as String] as? String ?? "",
                       r: CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)))
    }
    return out
}

func refreshAgentWindows() {
    let all = windows(onScreenOnly: false)
    agentWins = all.filter { stateAgent.contains($0.id) }
    agentPids = Set(agentWins.map { $0.pid })
    userPids = Set(all.filter { stateUser.contains($0.id) }.map { $0.pid })
}

/// A sheet, alert or popover of an agent-workspace window: not listed, same process, inside the parent's frame.
func isChild(_ w: Win) -> Bool {
    if stateAll.contains(w.id) || !agentPids.contains(w.pid) { return false }
    return agentWins.contains { $0.pid == w.pid && $0.r.insetBy(dx: -8, dy: -8).contains(w.r) }
}

func take(_ onScreen: [Win]) -> Snap {
    var s = Snap()
    let app = NSWorkspace.shared.frontmostApplication
    s.front = app?.bundleIdentifier ?? app?.localizedName ?? ""
    s.frontPid = Int(app?.processIdentifier ?? 0)
    s.workspace = workspace()
    let p = CGEvent(source: nil)?.location ?? .zero
    s.px = Double(p.x); s.py = Double(p.y)
    if let k = onScreen.first(where: { !isChild($0) }) { s.key = k.id; s.keyPid = k.pid }
    return s
}

func idleSeconds() -> Double {
    CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
}

func emit(_ o: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]),
          let s = String(data: d, encoding: .utf8) else { return }
    print(s)
}

func json(_ s: Snap) -> [String: Any] {
    ["front": s.front, "front_pid": s.frontPid, "workspace": s.workspace,
     "pointer": [s.px, s.py], "key_window": s.key, "key_pid": s.keyPid]
}

func winJSON(_ w: Win) -> [String: Any] { ["id": w.id, "pid": w.pid, "owner": w.owner] }

// ---- session: locked screen, display asleep, off the console, loginwindow in front
func sessionState(front: String) -> [String: Any] {
    let d = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
    return ["locked": (d["CGSSessionScreenIsLocked"] as? Bool) ?? false,
            "console": (d["kCGSSessionOnConsoleKey"] as? Bool) ?? true,
            "asleep": CGDisplayIsAsleep(CGMainDisplayID()) != 0,
            "loginwindow": front == "com.apple.loginwindow",
            // secure keyboard input (a password field, Terminal's Secure Keyboard Entry): keystrokes then never
            // reach an event tap, so the user may be typing unseen. The harness treats it as the user being here.
            "secure_input": IsSecureEventInputEnabled()]
}

// ---- input tap: real hardware (source pid 0) versus programs posting events
var realInputs = 0
var postedInputs: [Int: Int] = [:]
var lastPostedAt = 0.0
var tapOK = false
var tapPort: CFMachPort? = nil
var tapDisabled = false
let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    // The system turns a tap off when its callback is slow or on certain user input: switch it back on and
    // tell the harness, which treats it as a lost monitor (real input can no longer be seen).
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        tapDisabled = true
        if let p = tapPort { CGEvent.tapEnable(tap: p, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    let pid = Int(event.getIntegerValueField(.eventSourceUnixProcessID))
    if pid == 0 || !ownPoster(pid) { realInputs += 1 } else { postedInputs[pid, default: 0] += 1; lastPostedAt = Date().timeIntervalSince1970 }
    return Unmanaged.passUnretained(event)
}
func installTap() {
    let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                .otherMouseDown, .otherMouseUp, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .scrollWheel]
    var mask: CGEventMask = 0
    for t in types { mask |= CGEventMask(1) << CGEventMask(t.rawValue) }
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                      eventsOfInterest: mask, callback: tapCallback, userInfo: nil) else { return }
    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    tapPort = tap
    tapOK = true
}
installTap()

var onScreen0 = windows(onScreenOnly: true)
var last = take(onScreen0)
var lastSession = sessionState(front: last.front)
var knownUser = stateUser
var knownOnScreen = Set(onScreen0.map { $0.id })
var pendingUnplaced: [Int: Double] = [:]      // window id -> when it first appeared unlisted
var seenAt: [Int: Double] = [:]               // on-screen window id -> when it was first seen on screen
refreshAllow()
emit(["event": "start", "t": Date().timeIntervalSince1970, "state": json(last), "interval_ms": intervalMs,
      "tap": tapOK, "idle": idleSeconds(), "session": lastSession])
var lastUserPids = userPids
emit(["event": "user_pids", "t": Date().timeIntervalSince1970, "pids": lastUserPids.sorted()])
var samples = 0
var prevTick = Date().timeIntervalSince1970
var refreshedAt = prevTick
var prevIdle = idleSeconds()
var hidLow = false

func tick() {
    let now = Date().timeIntervalSince1970
    let gap = now - prevTick
    prevTick = now
    samples += 1
    refreshAllow()
    if now - refreshedAt >= 1 { refreshAgentWindows(); refreshedAt = now }
    if userPids != lastUserPids { lastUserPids = userPids; emit(["event": "user_pids", "t": now, "pids": userPids.sorted()]) }
    let onScreen = windows(onScreenOnly: true)
    let cur = take(onScreen)
    var fields: [String] = []
    if cur.front != last.front || cur.frontPid != last.frontPid { fields.append("front") }
    if cur.workspace != last.workspace { fields.append("workspace") }
    if abs(cur.px - last.px) > 0.5 || abs(cur.py - last.py) > 0.5 { fields.append("pointer") }
    if cur.key != last.key || cur.keyPid != last.keyPid { fields.append("key_window") }

    for w in onScreen where seenAt[w.id] == nil { seenAt[w.id] = now }
    let onIds = Set(onScreen.map { $0.id })
    for id in Array(seenAt.keys) where !onIds.contains(id) && !stateAll.contains(id) { seenAt[id] = nil }

    // user_window: state.json lists a new window on one of Donovan's workspaces. state.json lags the window, so the event is
    // its own line stamped with when the window was first SEEN on screen, never with the tick that read state.json.
    var userEvents: [(Double, [String: Any])] = []
    let newUser = stateUser.subtracting(knownUser)
    if !newUser.isEmpty {
        let all = windows(onScreenOnly: false)
        for id in newUser.sorted() {
            let w = all.first(where: { $0.id == id }).map(winJSON) ?? ["id": id, "pid": 0, "owner": ""]
            userEvents.append((min(seenAt[id] ?? now, now), w))
        }
    }
    knownUser = stateUser

    // unplaced: unlisted for a full second, still on screen, not a sheet of an agent window. Each is reported on
    // its own line stamped with when it FIRST appeared, never merged into this sample's current changes.
    for w in onScreen where !knownOnScreen.contains(w.id) && !stateAll.contains(w.id) && pendingUnplaced[w.id] == nil {
        pendingUnplaced[w.id] = now
    }
    let ids = Set(onScreen.map { $0.id })
    var delayed: [(Double, Win)] = []
    for (id, since) in pendingUnplaced {
        if !ids.contains(id) || stateAll.contains(id) { pendingUnplaced[id] = nil; continue }
        if now - since >= 1.0 {
            pendingUnplaced[id] = nil
            if let w = onScreen.first(where: { $0.id == id }) {
                refreshAgentWindows()
                if !isChild(w) { delayed.append((since, w)) }
            }
        }
    }
    knownOnScreen = ids
    if !fields.isEmpty {
        emit(["event": "change", "windows": [] as [Any], "t": now, "fields": Array(Set(fields)).sorted(), "from": json(last), "to": json(cur)])
        last = cur
    }
    for (since, w) in userEvents.sorted(by: { $0.0 < $1.0 }) {
        emit(["event": "change", "windows": [w], "t": since, "fields": ["user_window"], "from": json(last), "to": json(cur)])
    }
    for (since, w) in delayed.sorted(by: { $0.0 < $1.0 }) {
        emit(["event": "change", "windows": [winJSON(w)], "t": since, "fields": ["unplaced_window"], "from": json(last), "to": json(cur)])
    }

    let tapSawInput = realInputs > 0 || !postedInputs.isEmpty
    if tapSawInput {
        let posted = Dictionary(uniqueKeysWithValues: postedInputs.map { (String($0.key), $0.value) })
        emit(["event": "input", "t": now, "real": realInputs, "posted": posted])
        realInputs = 0; postedInputs = [:]
    }
    if tapDisabled { emit(["event": "tap_disabled", "t": now]); tapDisabled = false }
    let idle = idleSeconds()
    let freshHID = idle < 5 && (!hidLow || idle < prevIdle - 0.001)
    if !tapOK, freshHID {
        emit(["event": "hid", "t": now, "idle": idle])
    } else if tapOK, freshHID, !tapSawInput, now - lastPostedAt > 1.0 {
        // HID activity no event the tap saw can explain (nothing posted by a program just now): someone typed
        // under secure input, or the tap missed it. Real.
        emit(["event": "hid", "t": now, "idle": idle, "real": true])
    }
    hidLow = idle < 5
    prevIdle = idle

    let sess = sessionState(front: cur.front)
    if (sess as NSDictionary) != (lastSession as NSDictionary) {
        emit(["event": "session", "t": now, "state": sess])
        lastSession = sess
    }
    emit(["event": "beat", "t": now, "samples": samples, "gap_ms": Int(gap * 1000), "idle": idle])
}

for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        emit(["event": "end", "t": Date().timeIntervalSince1970, "samples": samples])
        exit(0)
    }
    src.resume()
}
Timer.scheduledTimer(withTimeInterval: Double(intervalMs) / 1000, repeats: true) { _ in tick() }
RunLoop.main.run()
