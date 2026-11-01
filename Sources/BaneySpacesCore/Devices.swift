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
    public var title: String
    /// AXStandardWindow (or a compositor window).
    public var standard: Bool

    public init(platform: String = "macos", bundle: String = "", process: String = "", windowClass: String = "",
                exe: String = "", title: String = "", standard: Bool = true) {
        self.platform = platform
        self.bundle = bundle
        self.process = process
        self.windowClass = windowClass
        self.exe = exe
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
}

public struct DeviceKeysInfo: Equatable, Sendable {
    public var capture: String
    public var release: String?
    public var note: String?
}

public struct DeviceApp: Sendable {
    public struct Rule: Sendable {
        var titlePrefix: String?, titleContains: String?, titleIs: String?, titleEmpty: Bool?
        var role: DeviceRole
        var home: String?
        func hits(_ title: String) -> Bool {
            (titlePrefix.map { title.hasPrefix($0) } ?? true)
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
            for (platform, v) in (a["match"] as? [String: Any]) ?? [:] {
                match[platform] = (v as? [String: Any])?.compactMapValues { $0 as? [String] } ?? [:]
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
                                      role: role, home: r["home"] as? String)
            }
            return DeviceApp(id: id, label: label, kind: kind, resizesItself: a["resizes_itself"] as? Bool ?? false,
                             float: a["float"] as? Bool ?? false, match: match, rules: parsed, keys: keys)
        }
    }

    /// The table that ships (spec/devices.json, embedded).
    public static let builtin: DeviceTable = {
        do { return try DeviceTable(json: DeviceData.devicesJSON) } catch { fatalError("\(error)") }
    }()

    public func app(of f: DeviceFacts) -> DeviceApp? { apps.first { $0.hits(f) } }
    public func app(id: String) -> DeviceApp? { apps.first { $0.id == id } }

    /// R-D1. A window that is not a standard one is never `main`.
    public func classify(_ f: DeviceFacts) -> DeviceDecision {
        guard let app = app(of: f) else {
            return DeviceDecision(app: nil, role: f.standard ? .main : .ignore, agentHome: false, resizesItself: false, float: false)
        }
        let rule = app.rules.first { $0.hits(f.title) }
        var role = rule?.role ?? (f.standard ? .main : .ignore)
        if role == .main, !f.standard { role = .ignore }
        return DeviceDecision(app: app.id, role: role, agentHome: role == .main && rule?.home == "agent",
                              resizesItself: app.resizesItself, float: app.float)
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
        if chord.mods == [mod] { return "switch \(n)" }
        if chord.mods == [mod, "shift"] { return "move \(n)" }
        return nil
    }

    /// Whether another event tap that takes key events stands in front of ours. The list is
    /// front-to-back as `CGGetEventTapList` gives it.
    public static func shouldRearm(taps: [(owner: Int32, takesKeys: Bool)], ours: Int32) -> Bool {
        guard let first = taps.firstIndex(where: { $0.takesKeys }) else { return false }
        return taps[first].owner != ours
    }
}

// MARK: R-D8, a device's whole process tree belongs to the agent

public enum ProcessTree {
    /// Whether `pid` is a registered root or descends from one. `roots` maps pid to start time; a root
    /// whose pid now has another start time was reused and is no root. The walk ends after 64 steps.
    public static func descends(pid: Int32, roots: [Int32: Double], startOf: (Int32) -> Double?, parentOf: (Int32) -> Int32?) -> Bool {
        var at = pid
        for _ in 0..<64 {
            if let want = roots[at], want == 0 || startOf(at) == want { return true }
            guard let p = parentOf(at), p > 1, p != at else { return false }
            at = p
        }
        return false
    }
}
