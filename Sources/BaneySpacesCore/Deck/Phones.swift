import Foundation

/// A phone the Mac can reach: an Android device over adb, or an iPhone (or a booted simulator)
/// through Xcode's devicectl.
public struct Phone: Equatable, Sendable {
    public enum Platform: String, Codable, Sendable { case android, ios }

    public var platform: Platform
    /// adb's serial, or the iPhone's CoreDevice identifier.
    public var id: String
    public var name: String
    public var model: String
    /// Ready to use right now. An unauthorized Android phone (the "Allow USB debugging?" prompt
    /// still showing) or an iPhone out of reach is listed but not ready.
    public var ready: Bool
    /// Why it isn't ready, in words for the sidebar.
    public var status: String
    public var simulator: Bool
    /// An iPad. iPhone Mirroring can't show one, so it gets its own icon and no Mirroring item.
    public var tablet: Bool

    public init(platform: Platform, id: String, name: String, model: String, ready: Bool, status: String, simulator: Bool = false, tablet: Bool = false) {
        self.platform = platform; self.id = id; self.name = name; self.model = model
        self.ready = ready; self.status = status; self.simulator = simulator; self.tablet = tablet
    }

    public var item: Item {
        Item(id: "\(platform.rawValue):\(id)", bundleID: platform == .ios ? "com.apple.ScreenContinuity" : "", appName: platform == .android ? "Android" : tablet ? "iPad" : "iPhone",
             role: .device, kind: .device, group: "phones", title: name, detail: ready ? model : "\(model) · \(status)")
    }
}

/// `adb track-devices -l` writes one message per change: four hex digits giving the length, then
/// that many bytes listing every device, one per line ("serial  device product:x model:Pixel_8 …").
public enum AdbTrack {
    /// Takes every complete message off the front of `buffer`, leaving a partial one in place.
    public static func messages(_ buffer: inout Data) -> [String] {
        var out: [String] = []
        while buffer.count >= 4, let len = Int(String(decoding: buffer.prefix(4), as: UTF8.self), radix: 16), buffer.count >= 4 + len {
            out.append(String(decoding: buffer.dropFirst(4).prefix(len), as: UTF8.self))
            buffer = Data(buffer.dropFirst(4 + len))
        }
        return out
    }

    /// The argument for `adb shell input text`, which the phone's shell reads: spaces become %s
    /// (input's own escape) and the whole thing is single-quoted, so nothing in it runs there.
    public static func inputText(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: " ", with: "%s").replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func phones(_ message: String) -> [Phone] {
        message.split(separator: "\n").compactMap { line in
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard f.count >= 2 else { return nil }
            let serial = f[0], state = f[1]
            let props = Dictionary(f.dropFirst(2).compactMap { p -> (String, String)? in
                let kv = p.split(separator: ":", maxSplits: 1).map(String.init)
                return kv.count == 2 ? (kv[0], kv[1]) : nil
            }, uniquingKeysWith: { a, _ in a })
            let model = (props["model"] ?? "Android").replacingOccurrences(of: "_", with: " ")
            let status: String
            switch state {
            case "device": status = "ready"
            case "unauthorized": status = "allow USB debugging on the phone"
            case "offline": status = "offline"
            default: status = state
            }
            return Phone(platform: .android, id: serial, name: model, model: serial.hasPrefix("emulator-") ? "Emulator" : serial,
                         ready: state == "device", status: status, simulator: serial.hasPrefix("emulator-"))
        }
    }
}

/// `xcrun devicectl list devices --json-output <file>`: real iPhones and iPads that are paired,
/// and simulators only while booted. A paired device with a transport (USB or Wi-Fi) is ready even
/// while its tunnel is "disconnected": devicectl opens the tunnel on first use, in about 3 s.
/// "unavailable" with no transport means the Mac can't see it at all (asleep, off, or on another
/// network).
public enum DeviceCtl {
    public static func phones(_ data: Data) -> [Phone] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = (obj["result"] as? [String: Any])?["devices"] as? [[String: Any]] else { return [] }
        return devices.compactMap { d in
            guard let id = d["identifier"] as? String else { return nil }
            let props = d["deviceProperties"] as? [String: Any] ?? [:]
            let hw = d["hardwareProperties"] as? [String: Any] ?? [:]
            let conn = d["connectionProperties"] as? [String: Any] ?? [:]
            let simulator = (hw["reality"] as? String) == "simulated"
            if simulator && (props["bootState"] as? String) != "booted" { return nil }
            let tunnel = conn["tunnelState"] as? String ?? ""
            let transport = conn["transportType"] as? String ?? ""
            let paired = (conn["pairingState"] as? String ?? "paired") == "paired"
            let reachable = paired && (transport == "wired" || transport == "localNetwork")
            let ready = simulator || tunnel == "connected" || (reachable && tunnel != "unavailable")
            let status = ready ? (transport == "wired" ? "USB" : transport == "localNetwork" ? "Wi-Fi" : "ready")
                : !paired ? "not paired" : tunnel == "unavailable" ? "out of reach" : "not connected"
            let tablet = (hw["deviceType"] as? String) == "iPad" && !simulator
            let fallback = tablet ? "iPad" : "iPhone"
            return Phone(platform: .ios, id: id, name: props["name"] as? String ?? hw["marketingName"] as? String ?? fallback,
                         model: (hw["marketingName"] as? String ?? fallback) + (simulator ? " Simulator" : ""),
                         ready: ready, status: status, simulator: simulator, tablet: tablet)
        }
    }
}
