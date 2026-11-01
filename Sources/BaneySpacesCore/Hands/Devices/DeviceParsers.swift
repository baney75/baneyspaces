import Foundation

/// What `baneyspaces agent device` reads from simctl, adb, uiautomator and AXe. Pure parsers: the
/// same fixtures in spec/conformance/device-hands are parsed by the Rust core for Android.

public enum DevicePlatform: String, Sendable { case ios, android }

/// One element of a device's screen, from a uiautomator dump or AXe's describe-ui.
public struct UINode: Equatable, Sendable {
    public var role: String
    public var label: String
    public var value: String
    /// resource-id (Android) or AXUniqueId (iOS).
    public var identifier: String
    public var x: Double, y: Double, width: Double, height: Double
    public var enabled: Bool
    public var clickable: Bool
    public var checkable: Bool
    public var checked: Bool
    public var focused: Bool
    public var scrollable: Bool
    public var editable: Bool
    public var ref: String = ""

    public var centerX: Double { x + width / 2 }
    public var centerY: Double { y + height / 2 }
    public var hasArea: Bool { width > 0 && height > 0 }

    /// Something a person could tap, type into or scroll.
    public var actionable: Bool { enabled && hasArea && (clickable || checkable || editable || scrollable) }

    /// What identifies the element across two reads of the screen, whatever its state or place.
    public var identity: String { [role, identifier, label].joined(separator: "|") }
    /// The state a tap or typing changes.
    public var state: String { [value, checked ? "1" : "0", focused ? "1" : "0"].joined(separator: "|") }
}

public struct SimDevice: Equatable, Sendable {
    public var udid: String, name: String, state: String, runtime: String, type: String
}
public struct SimRuntime: Equatable, Sendable { public var identifier: String, version: String, name: String }
public struct SimDeviceType: Equatable, Sendable { public var identifier: String, name: String }
public struct AdbDevice: Equatable, Sendable { public var serial: String, state: String, model: String }
public struct PhysicalDevice: Equatable, Sendable { public var name: String, os: String, udid: String }

public enum SimctlParse {
    public static func devices(_ data: Data) -> [SimDevice]? {
        guard let root = JSONValue.parse(data)?["devices"]?.object else { return nil }
        var out: [SimDevice] = []
        for (runtime, list) in root.sorted(by: { $0.key < $1.key }) {
            for d in list.array ?? [] {
                guard let udid = d["udid"]?.string, let name = d["name"]?.string else { continue }
                if d["isAvailable"]?.bool == false { continue }
                out.append(SimDevice(udid: udid, name: name, state: d["state"]?.string ?? "", runtime: runtime, type: d["deviceTypeIdentifier"]?.string ?? ""))
            }
        }
        return out
    }
    public static func runtimes(_ data: Data) -> [SimRuntime]? {
        guard let list = JSONValue.parse(data)?["runtimes"]?.array else { return nil }
        return list.compactMap { r in
            guard let id = r["identifier"]?.string, r["isAvailable"]?.bool != false, r["platform"]?.string ?? "iOS" == "iOS" else { return nil }
            return SimRuntime(identifier: id, version: r["version"]?.string ?? "", name: r["name"]?.string ?? id)
        }
    }
    public static func deviceTypes(_ data: Data) -> [SimDeviceType]? {
        guard let list = JSONValue.parse(data)?["devicetypes"]?.array else { return nil }
        return list.compactMap { t in
            guard let id = t["identifier"]?.string, let name = t["name"]?.string else { return nil }
            return SimDeviceType(identifier: id, name: name)
        }
    }
    /// "26.5" > "26.0" > "9.3", numerically.
    public static func newest(_ runtimes: [SimRuntime]) -> SimRuntime? {
        runtimes.max { versionKey($0.version).lexicographicallyPrecedes(versionKey($1.version)) }
    }
    static func versionKey(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0) ?? 0 } }
}

public enum AdbParse {
    /// `adb devices -l`.
    public static func devices(_ text: String) -> [AdbDevice] {
        text.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard f.count >= 2, !line.hasPrefix("*") else { return nil }
            let model = f.dropFirst(2).first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)) } ?? ""
            return AdbDevice(serial: f[0], state: f[1], model: model)
        }
    }
    public static func isEmulator(_ serial: String) -> Bool { serial.hasPrefix("emulator-") }
}

public enum XctraceParse {
    /// `xcrun xctrace list devices`: the "== Devices ==" section minus the Mac itself.
    public static func devices(_ text: String) -> [PhysicalDevice] {
        var inDevices = false
        var out: [PhysicalDevice] = []
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("== ") { inDevices = line.contains("Devices ==") && !line.contains("Offline"); continue }
            guard inDevices, let m = line.range(of: #"^(.+) \(([0-9][0-9.]*)\) \(([0-9A-Fa-f-]{20,})\)$"#, options: .regularExpression) else { continue }
            let parts = String(line[m]).components(separatedBy: " (")
            guard parts.count >= 3 else { continue }
            out.append(PhysicalDevice(name: parts[0], os: String(parts[parts.count - 2].dropLast()), udid: String(parts[parts.count - 1].dropLast())))
        }
        return out
    }
}

/// Android: `uiautomator dump` XML.
public enum UiAutomatorParse {
    public static func nodes(_ xml: String) -> [UINode]? {
        guard let start = xml.range(of: "<hierarchy"), let end = xml.range(of: "</hierarchy>") else { return nil }
        let body = String(xml[start.lowerBound..<end.upperBound])
        let parser = XMLParser(data: Data(body.utf8))
        let d = Delegate()
        parser.delegate = d
        guard parser.parse(), !d.nodes.isEmpty else { return nil }
        return d.nodes
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var nodes: [UINode] = []
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            guard name == "node", let b = a["bounds"], let r = bounds(b) else { return }
            let cls = a["class"] ?? ""
            let label = [a["text"], a["content-desc"]].compactMap { $0 }.first { !$0.isEmpty } ?? ""
            let edit = cls.hasSuffix("EditText") || cls.hasSuffix("AutoCompleteTextView")
            nodes.append(UINode(role: cls.split(separator: ".").last.map(String.init) ?? cls, label: label,
                                value: edit ? (a["text"] ?? "") : (a["text"] ?? ""), identifier: a["resource-id"] ?? "",
                                x: r.0, y: r.1, width: r.2 - r.0, height: r.3 - r.1,
                                enabled: a["enabled"] != "false", clickable: a["clickable"] == "true", checkable: a["checkable"] == "true",
                                checked: a["checked"] == "true", focused: a["focused"] == "true", scrollable: a["scrollable"] == "true", editable: edit))
        }
        func bounds(_ s: String) -> (Double, Double, Double, Double)? {
            let n = s.split(whereSeparator: { !"0123456789-".contains($0) }).compactMap { Double($0) }
            return n.count == 4 ? (n[0], n[1], n[2], n[3]) : nil
        }
    }
}

/// iOS: `axe describe-ui` JSON (the accessibility tree, as IDB prints it).
public enum AxeParse {
    public static func nodes(_ data: Data) -> [UINode]? {
        guard let root = JSONValue.parse(data) else { return nil }
        let top = root.array ?? [root]
        var out: [UINode] = []
        func walk(_ n: JSONValue) {
            if let f = n["frame"], let x = f["x"]?.double, let y = f["y"]?.double, let w = f["width"]?.double, let h = f["height"]?.double {
                let role = n["role"]?.string ?? n["type"]?.string ?? ""
                let kind = (n["type"]?.string ?? role).lowercased()
                let editable = kind.contains("textfield") || kind.contains("securetextfield") || kind.contains("textview") || kind.contains("searchfield")
                let clickable = ["button", "cell", "link", "switch", "tab", "segmentedcontrol", "slider", "stepper", "menuitem", "picker", "toggle", "checkbox", "radiobutton", "key"].contains { kind.contains($0) }
                let value = n["AXValue"]?.stringified ?? ""
                out.append(UINode(role: role, label: n["AXLabel"]?.string ?? "", value: value, identifier: n["AXUniqueId"]?.string ?? "",
                                  x: x, y: y, width: w, height: h, enabled: n["enabled"]?.bool ?? true, clickable: clickable,
                                  checkable: kind.contains("switch") || kind.contains("checkbox") || kind.contains("toggle"),
                                  checked: kind.contains("switch") || kind.contains("toggle") || kind.contains("checkbox") ? value == "1" || value == "true" : false,
                                  focused: n["focused"]?.bool ?? false, scrollable: kind.contains("scroll") || kind.contains("table") || kind.contains("collection"),
                                  editable: editable))
            }
            for c in n["children"]?.array ?? [] { walk(c) }
        }
        top.forEach(walk)
        return out.isEmpty ? nil : out
    }
}

extension JSONValue {
    var double: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .string(let s): return Double(s)
        default: return nil
        }
    }
    /// A string for a string, number or bool; nil for the rest.
    var stringified: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }
}
