import CoreGraphics
import Foundation

/// Simulators, emulators and virtual machines (spec/devices.md). `spec/devices.json` says which apps
/// these are and what each of their windows is for; the rules R-D1 to R-D8 are decided here, with no
/// AppKit, so they can be tested with fakes.

/// R-D1: what a window is for.
public enum DeviceRole: String, Equatable, Sendable {
    /// An application window: it has a workspace, a tile, a place in the switcher.
    case main
    /// A toolbar or extended controls: lives with its process's main window, never counted (R-D2, R-D3).
    case companion
    /// Not tracked at all.
    case ignore
}

/// What macOS knows about one window.
public struct DeviceFacts: Equatable, Sendable {
    public var platform: String
    public var bundle: String
    public var process: String
    public var windowClass: String
    public var exe: String
    /// The process's command line arguments (empty when unknown).
    public var args: [String]
    public var title: String
    /// AXStandardWindow (or a compositor window).
    public var standard: Bool

    public init(platform: String = "macos", bundle: String = "", process: String = "", windowClass: String = "",
                exe: String = "", args: [String] = [], title: String = "", standard: Bool = true) {
        self.platform = platform
        self.bundle = bundle
        self.process = process
        self.windowClass = windowClass
        self.exe = exe
        self.args = args
        self.title = title
        self.standard = standard
    }
}

public struct DeviceDecision: Equatable, Sendable {
    public var app: String?
    public var role: DeviceRole
    public var agentHome: Bool
    public var resizesItself: Bool
    public var float: Bool
    /// `agentHome` applies only to a process BaneySpaces' sandbox started (R-D9).
    public var sandboxOnly: Bool = false
}

public struct DeviceKeysInfo: Equatable, Sendable {
    public var capture: String
    public var release: String?
    public var note: String?
}

public struct DeviceApp: Sendable {
    public struct Rule: Sendable {
        var titlePrefix: String?, titleContains: String?, titleIs: String?, titleEmpty: Bool?
        var standard: Bool?, platform: String?, onlyIf: String?
        var role: DeviceRole
        var home: String?
        func hits(_ f: DeviceFacts) -> Bool {
            let title = f.title
            return (platform.map { $0 == f.platform } ?? true)
                && (standard.map { $0 == f.standard } ?? true)
                && (titlePrefix.map { title.hasPrefix($0) } ?? true)
                && (titleContains.map { title.contains($0) } ?? true)
                && (titleIs.map { title == $0 } ?? true)
                && (titleEmpty.map { title.isEmpty == $0 } ?? true)
        }
    }
    public let id: String
    public let label: String
    public let kind: String
    public let resizesItself: Bool
    public let float: Bool
    let match: [String: [String: [String]]]
    /// Per platform: a process name pattern -> the argument it must be started with / the title prefix its window must have.
    let processArg: [String: [String: String]]
    let processTitle: [String: [String: String]]
    let rules: [Rule]
    public let keys: [String: DeviceKeysInfo]

    /// An exact name, or a prefix when the pattern ends in `*`; case does not matter.
    public static func name(_ pattern: String, matches name: String) -> Bool {
        if name.isEmpty { return false }
        let p = pattern.lowercased(), n = name.lowercased()
        return p.hasSuffix("*") ? n.hasPrefix(String(p.dropLast())) : p == n
    }

    func hits(_ f: DeviceFacts) -> Bool {
        guard let m = match[f.platform] else { return false }
        if !f.bundle.isEmpty, (m["bundle"] ?? []).contains(f.bundle) { return true }
        return (m["process"] ?? []).contains { Self.name($0, matches: f.process) }
            || (m["class"] ?? []).contains { Self.name($0, matches: f.windowClass) }
            || (m["exe"] ?? []).contains { Self.name($0, matches: f.exe) }
            || (processArg[f.platform] ?? [:]).contains { Self.name($0.key, matches: f.process) && f.args.contains($0.value) }
            || (processTitle[f.platform] ?? [:]).contains { (Self.name($0.key, matches: f.process) || Self.name($0.key, matches: f.exe)) && f.title.hasPrefix($0.value) }
    }
}

public struct DeviceTable: Sendable {
    public let apps: [DeviceApp]

    public init(json: String) throws {
        guard let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              (root["version"] as? Int) == 1, let list = root["apps"] as? [[String: Any]] else {
            throw DeviceTableError.bad("devices.json: not version 1 with an apps list")
        }
        apps = try list.map { a in
            guard let id = a["id"] as? String, let label = a["label"] as? String, let kind = a["kind"] as? String,
                  let rules = a["windows"] as? [[String: Any]], !rules.isEmpty else {
                throw DeviceTableError.bad("devices.json: an app lacks id, label, kind or windows")
            }
            var match: [String: [String: [String]]] = [:]
            var processArg: [String: [String: String]] = [:], processTitle: [String: [String: String]] = [:]
            for (platform, v) in (a["match"] as? [String: Any]) ?? [:] {
                let m = v as? [String: Any] ?? [:]
                match[platform] = m.compactMapValues { $0 as? [String] }
                processArg[platform] = m["process_arg"] as? [String: String] ?? [:]
                processTitle[platform] = m["process_title"] as? [String: String] ?? [:]
            }
            var keys: [String: DeviceKeysInfo] = [:]
            for (platform, v) in (a["keys"] as? [String: Any]) ?? [:] {
                guard let k = v as? [String: Any], let cap = k["capture"] as? String else { continue }
                keys[platform] = DeviceKeysInfo(capture: cap, release: k["release"] as? String, note: k["note"] as? String)
            }
            let parsed = try rules.map { r -> DeviceApp.Rule in
                guard let role = (r["role"] as? String).flatMap(DeviceRole.init(rawValue:)) else {
                    throw DeviceTableError.bad("devices.json: \(id) has a window rule without a known role")
                }
                return DeviceApp.Rule(titlePrefix: r["title_prefix"] as? String, titleContains: r["title_contains"] as? String,
                                      titleIs: r["title_is"] as? String, titleEmpty: r["title_empty"] as? Bool,
                                      standard: r["standard"] as? Bool, platform: r["platform"] as? String, onlyIf: r["only_if"] as? String,
                                      role: role, home: r["home"] as? String)
            }
            return DeviceApp(id: id, label: label, kind: kind, resizesItself: a["resizes_itself"] as? Bool ?? false,
                             float: a["float"] as? Bool ?? false, match: match, processArg: processArg, processTitle: processTitle, rules: parsed, keys: keys)
        }
    }

    /// The table that ships (spec/devices.json, embedded).
    public static let builtin: DeviceTable = {
        do { return try DeviceTable(json: DeviceData.devicesJSON) } catch { fatalError("\(error)") }
    }()

    public func app(of f: DeviceFacts) -> DeviceApp? { apps.first { $0.hits(f) } }

    /// The app whose process name is used with a marker (an argument or a title) that this process may still
    /// lack: the emulator's `qemu-system-*` whose arguments could not be read.
    public func appByName(of f: DeviceFacts) -> DeviceApp? {
        apps.first { app in
            (app.processArg[f.platform] ?? [:]).keys.contains { DeviceApp.name($0, matches: f.process) }
                || (app.processTitle[f.platform] ?? [:]).keys.contains { DeviceApp.name($0, matches: f.process) || DeviceApp.name($0, matches: f.exe) }
        }
    }

    /// Whether a process could be a device app's: it matches now, or by name with a marker still missing.
    public func isCandidate(_ f: DeviceFacts) -> Bool { app(of: f) != nil || appByName(of: f) != nil }
    public func app(id: String) -> DeviceApp? { apps.first { $0.id == id } }

    /// R-D1. A window that is not a standard one is never `main`.
    public func classify(_ f: DeviceFacts) -> DeviceDecision {
        guard let app = app(of: f) else {
            return DeviceDecision(app: nil, role: f.standard ? .main : .ignore, agentHome: false, resizesItself: false, float: false)
        }
        let rule = app.rules.first { $0.hits(f) }
        var role = rule?.role ?? (f.standard ? .main : .ignore)
        if role == .main, !f.standard { role = .ignore }
        return DeviceDecision(app: app.id, role: role, agentHome: role == .main && rule?.home == "agent",
                              resizesItself: app.resizesItself, float: app.float, sandboxOnly: rule?.onlyIf == "sandbox_process")
    }

    public static func classify(_ f: DeviceFacts) -> DeviceDecision { builtin.classify(f) }
}

public enum DeviceTableError: Error { case bad(String) }

// MARK: R-D6, a window that resizes itself keeps the size it has

public enum DeviceGeometry {
    /// Where a parked window of a device app goes when it comes back. An app that resizes itself
    /// (a device rotated while the window was parked) keeps its current `size` and the saved origin,
    /// slid into the display that held the saved frame; any other window gets `Geometry.restoreFrame`.
    public static func restoreFrame(saved: CGRect?, size: CGSize, screens: [CGRect], resizesItself: Bool) -> CGRect {
        guard resizesItself else { return Geometry.restoreFrame(saved: saved, size: size, screens: screens) }
        guard let saved, Geometry.visibleFraction(saved, screens: screens) >= 0.5 else {
            guard let s = screens.first else { return CGRect(origin: .zero, size: size) }
            return CGRect(x: s.midX - size.width / 2, y: s.midY - size.height / 2, width: size.width, height: size.height).integral
        }
        let home = screens.max { a, b in area(a, saved) < area(b, saved) } ?? screens[0]
        var x = min(saved.minX, home.maxX - size.width)
        var y = min(saved.minY, home.maxY - size.height)
        x = max(home.minX, x)
        y = max(home.minY, y)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private static func area(_ screen: CGRect, _ frame: CGRect) -> CGFloat {
        let i = screen.intersection(frame)
        return i.isNull ? 0 : i.width * i.height
    }
}

// MARK: R-D7, workspace keys inside an app that grabs the keyboard

public struct ChordSpec: Equatable, Sendable {
    public var mods: Set<String>
    public var key: String
    public init(mods: Set<String>, key: String) { self.mods = mods; self.key = key }
}

public enum DeviceKeys {
    /// The workspace action a chord means in a front app that captures the keyboard, or nil to let
    /// it through (to the guest, or to the ordinary shortcut). `frontApp` is the device app id.
    /// Only `mod+1...9` (switch) and `mod+shift+1...9` (move) are taken, with no other modifier.
    public static func action(frontApp: String?, platform: String = "macos", mod: String, bridge: Bool, chord: ChordSpec,
                              table: DeviceTable = .builtin) -> String? {
        guard bridge, let frontApp, let capture = table.app(id: frontApp)?.keys[platform]?.capture,
              capture == "tap" || capture == "hook" else { return nil }
        guard chord.key.count == 1, let n = Int(chord.key), (1...9).contains(n) else { return nil }
        // `mod` is one modifier, or several joined by "+" (the workspace modifier can be ⌃⌥).
        let want = Set(mod.split(separator: "+").map(String.init))
        if chord.mods == want { return "switch \(n)" }
        if chord.mods == want.union(["shift"]) { return "move \(n)" }
        return nil
    }

    /// Whether a key-taking tap from another process has appeared since `known` (the tap ids seen when ours was
    /// made). Apple documents no order for `CGGetEventTapList`, so position says nothing; a newcomer does.
    public static func shouldRearm(taps: [(id: UInt32, owner: Int32, takesKeys: Bool)], known: Set<UInt32>, ours: Int32) -> Bool {
        taps.contains { $0.takesKeys && $0.owner != ours && !known.contains($0.id) }
    }
}

/// The state the key bridge's tap callback and the main thread share, behind one lock. The callback does
/// the least it can under it: read the front app and modifier, look the key up, answer. `disarm` clears
/// what it holds under the same lock, so a key up that arrives after is passed on, never lost or held.
///
/// The modifier is held back from the guest while a workspace chord is still possible: a guest that maps
/// ⌘ to its Win or Super key would otherwise see a lone press and release on every workspace switch (and
/// open its Start menu or Activities), and a switch with ⌘ down would leave it stuck. A modifier press is
/// swallowed and remembered. If a workspace digit follows, the chord runs and the guest sees none of it. If
/// anything else follows (a key, a click, or the modifier letting go alone), the held modifiers are replayed
/// to the guest first (`replay`), so ⌘C, ⌘-click and a lone ⌘ tap reach it as they were.
public final class KeyBridgeState: @unchecked Sendable {
    public enum Verdict: Equatable, Sendable {
        case pass
        case swallow
        case run(String)
        /// Send these modifier presses (key codes, in order) to the guest, then pass the event on.
        case replay([Int64])
    }
    private let lock = NSLock()
    private var front: String?
    private var mod = "cmd"
    private var armed = false
    private var taken = Set<Int64>()
    /// Modifiers swallowed and not yet shown to the guest, in the order pressed.
    private var held: [(code: Int64, name: String)] = []
    /// A chord ran while these were held: they are never shown, and their release is swallowed.
    private var consumed = false
    private let table: DeviceTable

    public init(table: DeviceTable = .builtin) { self.table = table }

    public func setFront(_ app: String?, mod: String) {
        lock.lock(); front = app; self.mod = mod; lock.unlock()
    }
    public func arm() { lock.lock(); armed = true; lock.unlock() }
    public func disarm() { lock.lock(); armed = false; taken.removeAll(); held.removeAll(); consumed = false; lock.unlock() }
    public var isArmed: Bool { lock.lock(); defer { lock.unlock() }; return armed }

    private var workspaceMods: Set<String> { Set(mod.split(separator: "+").map(String.init)) }

    /// A modifier changed: `name` is cmd, ctrl, alt or shift; `down` whether it went down.
    public func modifier(code: Int64, name: String, down: Bool) -> Verdict {
        lock.lock(); defer { lock.unlock() }
        guard armed, front != nil else { return .pass }
        if down {
            // The workspace modifier starts a hold; any other modifier joins one that has started (⇧ of ⌘⇧3).
            guard !held.isEmpty || workspaceMods.contains(name) else { return .pass }
            if !held.contains(where: { $0.code == code }) { held.append((code, name)) }
            return .swallow
        }
        guard let i = held.firstIndex(where: { $0.code == code }) else { return .pass }
        if consumed {
            held.remove(at: i)
            if held.isEmpty { consumed = false }
            return .swallow
        }
        // It let go with no chord: the guest gets the press now, and the release follows.
        let codes = held.map(\.code)
        held.removeAll()
        return .replay(codes)
    }

    /// A key down for workspace key `n` (1-9, or nil for any other key) with these modifiers. Auto-repeat
    /// of a key already taken is swallowed; the first press runs its action.
    public func keyDown(code: Int64, workspaceKey n: Int?, mods: Set<String>, repeating: Bool) -> Verdict {
        lock.lock(); defer { lock.unlock() }
        guard armed else { return .pass }
        if repeating, taken.contains(code) { return .swallow }
        if let n, let action = DeviceKeys.action(frontApp: front, mod: mod, bridge: true, chord: ChordSpec(mods: mods, key: String(n)), table: table) {
            taken.insert(code)
            consumed = !held.isEmpty
            return .run(action)
        }
        return replayHeld()
    }

    /// A mouse button went down while modifiers are held back: the guest must see them first.
    public func mouseDown() -> Verdict {
        lock.lock(); defer { lock.unlock() }
        return armed ? replayHeld() : .pass
    }

    private func replayHeld() -> Verdict {
        guard !held.isEmpty else { return .pass }
        let codes = held.map(\.code)
        held.removeAll(); consumed = false
        return .replay(codes)
    }

    /// The key up of a key whose down was taken is taken too.
    public func keyUp(code: Int64) -> Verdict {
        lock.lock(); defer { lock.unlock() }
        return taken.remove(code) != nil ? .swallow : .pass
    }
}

// MARK: placement of a window the table pins (R-D9)

public enum DevicePlacement {
    /// R-D9: windows the table pins to the agent workspace go there, but only when their process is one
    /// BaneySpaces' sandbox started. A stranger's window titled `bsx-...` is left where it is. Returns the
    /// windows moved.
    @discardableResult
    public static func placePinned(windows: [WindowID], pinned: Set<WindowID>, ownedBySandbox: (WindowID) -> Bool,
                                   agent: Int?, model: inout Workspaces) -> [WindowID] {
        guard let agent else { return [] }
        var moved: [WindowID] = []
        for id in windows where pinned.contains(id) && model.workspace(of: id) != nil && model.workspace(of: id) != agent && ownedBySandbox(id) {
            model.assign(id, to: agent, focus: false)
            moved.append(id)
        }
        return moved
    }
}

// MARK: R-D8, a device's whole process tree belongs to the agent

/// A process found below one of the agent's roots, remembered with that root (its pid and start time) at
/// the time, while the parent chain still showed it.
public struct RecordedDescendant: Equatable, Sendable {
    public var started: Double
    public var root: Int32
    public var rootStarted: Double
    public init(started: Double, root: Int32, rootStarted: Double) { self.started = started; self.root = root; self.rootStarted = rootStarted }
}

public enum ProcessTree {
    /// The roots whose pid still belongs to the process that was started for the agent. A pid that another
    /// process has now is dropped, so nothing it starts is taken for the agent's.
    public static func liveRoots(_ roots: [Int32: Double], startOf: (Int32) -> Double?) -> [Int32: Double] {
        roots.filter { pid, started in started == 0 || startOf(pid).map { abs($0 - started) < 0.5 } == true }
    }

    /// The root `pid` belongs to, or nil. In order: it is a root (same start time); it was recorded under a
    /// root that is still that process; it descends from a root by the live parent chain right now (a child
    /// not recorded yet). Never "whichever root has a claim open": a process with no root has none.
    public static func attribute(pid: Int32, roots: [Int32: Double], recorded: [Int32: RecordedDescendant],
                                 startOf: (Int32) -> Double?, parentOf: (Int32) -> Int32?) -> Int32? {
        func same(_ a: Double, _ b: Double?) -> Bool { a == 0 || (b.map { abs($0 - a) < 0.5 } ?? false) }
        if let want = roots[pid], same(want, startOf(pid)) { return pid }
        if let r = recorded[pid], same(r.started, startOf(pid)), let rs = roots[r.root], same(rs, startOf(r.root)), abs(rs - r.rootStarted) < 0.5 || rs == 0 {
            return r.root
        }
        var at = pid
        for _ in 0..<64 {
            guard let p = parentOf(at), p > 1, p != at else { return nil }
            if let want = roots[p], same(want, startOf(p)) { return p }
            at = p
        }
        return nil
    }

    /// Whether `pid` belongs to some root (the old yes/no form).
    public static func descends(pid: Int32, roots: [Int32: Double], startOf: (Int32) -> Double?, parentOf: (Int32) -> Int32?) -> Bool {
        attribute(pid: pid, roots: roots, recorded: [:], startOf: startOf, parentOf: parentOf) != nil
    }

    /// Processes in `table` (pid, parent pid) below `roots` that are not in `known` yet, each with the root it
    /// was found under (the first root whose tree holds it). Recorded while their parent is alive, so they stay
    /// that root's if the parent exits and they are reparented.
    public static func newDescendants(roots: [Int32], known: Set<Int32>, table: [(pid: Int32, ppid: Int32)]) -> [(pid: Int32, root: Int32)] {
        var seen = Set(roots).union(known), found: [(pid: Int32, root: Int32)] = []
        for root in roots {
            var owned: Set<Int32> = [root]
            // a recorded process is still a link in the chain for its own children
            owned.formUnion(known)
            var grew = true
            while grew {
                grew = false
                for p in table where owned.contains(p.ppid) && !owned.contains(p.pid) && p.pid > 1 {
                    owned.insert(p.pid); grew = true
                    if seen.insert(p.pid).inserted { found.append((p.pid, root)) }
                }
            }
        }
        return found
    }
}
