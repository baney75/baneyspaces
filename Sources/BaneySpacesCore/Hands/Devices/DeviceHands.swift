import Foundation
import CryptoKit

/// `baneyspaces agent device ...`: agents drive simulators and emulators the way they drive windows:
/// the envelope, refs from a snapshot, evidence read back after each action, retry rules and a scope
/// guard. Everything goes through simctl, AXe and adb, which act inside the device: no click on a
/// window, no host key, no pointer, no app brought forward. (spec/device-hands.md)
public final class DeviceHands {
    private let runner: DeviceRunner
    private let tools: DeviceTools
    private let store: DeviceStore
    private let shots: URL
    private let agent: String
    private let now: () -> Date
    private let sleep: (TimeInterval) -> Void
    private let randomWord: (Int) -> String
    private let alive: (Int32) -> Bool
    private let lock = NSLock()
    private var snaps: [String: Snap] = [:]

    private struct Snap { var sid: String; var nodes: [UINode]; var size: (w: Double, h: Double) }

    public init(runner: DeviceRunner, tools: DeviceTools, store: DeviceStore, shots: URL, agent: String = "agent",
                now: @escaping () -> Date = Date.init, sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                randomWord: @escaping (Int) -> String = { n in String((0..<n).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! }) },
                alive: @escaping (Int32) -> Bool = { kill($0, 0) == 0 }) {
        self.runner = runner; self.tools = tools; self.store = store; self.shots = shots; self.agent = agent
        self.now = now; self.sleep = sleep; self.randomWord = randomWord; self.alive = alive
    }

    /// Donovan lends a device (called by the app after the consent sheet).
    public func lend(_ id: String, session: String, seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        var l = store.load(); l.lend(id, session: session, now: now(), for: seconds); store.save(l)
    }
    public func giveBack(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        var l = store.load(); l.giveBack(id); store.save(l)
    }

    // MARK: dispatch

    public func handle(_ req: HandsRequest) -> HandsEnvelope {
        lock.lock(); defer { lock.unlock() }
        do {
            switch req.verb {
            case "device-list": return try list(req)
            case "device-boot": return try boot(req)
            case "device-shutdown": return try shutdown(req)
            case "device-open-app": return try openApp(req)
            case "device-snapshot": return try snapshot(req)
            case "device-tap": return try tap(req)
            case "device-type": return try type(req)
            case "device-swipe": return try swipe(req)
            case "device-press": return try press(req)
            case "device-shot": return try shot(req)
            case "device-log": return try log(req)
            default: return .failure(HandsError(.badArguments, "unknown device command \(req.verb)", suggestion: "Commands: " + DeviceTools_.verbs.joined(separator: ", ")))
            }
        } catch let e as HandsError {
            return .failure(e)
        } catch {
            return .failure(HandsError(.engineError, "\(error)", suggestion: "Try again; if it keeps failing, run `baneyspaces agent device list`.", retry: .never))
        }
    }

    // MARK: ids and scope

    struct Target { var info: DeviceInfo; var platform: DevicePlatform; var native: String }

    private func parseID(_ id: String?) throws -> (DevicePlatform, String) {
        guard let id, let c = id.firstIndex(of: ":"), let p = DevicePlatform(rawValue: String(id[..<c])), id.index(after: c) < id.endIndex else {
            throw HandsError(.badArguments, "a device id looks like ios:<udid> or android:<serial>", suggestion: "Run `baneyspaces agent device list` and use an id from it.", retry: .safe)
        }
        let native = String(id[id.index(after: c)...])
        guard native.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." || $0 == ":" }) else {
            throw HandsError(.badArguments, "that device id has characters a device id never has", suggestion: "Use an id from `device list`.", retry: .safe)
        }
        return (p, native)
    }

    /// The scope guard: a device is used only when BaneySpaces booted it for the agent, or Donovan lent it,
    /// and it is still the same device. Checked on every call, against the live device list.
    private func authorize(_ idArg: String?, needBooted: Bool = true) throws -> Target {
        let (platform, native) = try parseID(idArg)
        let id = "\(platform.rawValue):\(native)"
        var ledger = store.load()
        ledger.expire(now: now())
        // A process we started that is gone ends the claim: its serial may be reused by Donovan's emulator.
        for e in ledger.entries where e.pid.map({ !alive($0) }) == true { ledger.remove(e.id) }
        store.save(ledger)
        let devices = try listAll(ledger: ledger, includeShutdown: true)
        guard let info = devices.first(where: { $0.id == id }) else {
            throw HandsError(.deviceNotFound, "no device \(id)", suggestion: "Run `baneyspaces agent device list`. A device you booted that was shut down is gone; boot another.", retry: .safe)
        }
        guard info.supported else {
            throw HandsError(.notSupported, "\(info.name): \(info.note ?? "not supported yet")", suggestion: "Use a simulator or an emulator.", retry: .never)
        }
        guard info.owned || info.lent else {
            throw HandsError(.needsLend, "\(id) (\(info.name)) is not a device BaneySpaces booted for you; it is Donovan's",
                             suggestion: "Boot your own with `baneyspaces agent device boot`, or ask Donovan to lend this one: he runs `baneyspaces agent lend \(id)` in a terminal he types in.", retry: .never)
        }
        if needBooted, info.state != "booted" {
            throw HandsError(.deviceOffline, "\(id) is \(info.state)", suggestion: info.platform == "ios" ? "It may still be booting; wait a few seconds and send it again." : "Wait for it to finish booting, then send it again.", retry: .safe)
        }
        return Target(info: info, platform: platform, native: native)
    }

    // MARK: tools

    private func adb(_ serial: String?, _ args: [String], timeout: TimeInterval = 20) throws -> DeviceRun {
        guard let adb = tools.adb else {
            throw HandsError(.toolMissing, "adb isn't installed", suggestion: "Install the Android SDK platform-tools (Android Studio's SDK Manager) and set ANDROID_HOME. BaneySpaces installs nothing.", retry: .never)
        }
        return runner.run(adb, (serial.map { ["-s", $0] } ?? []) + args, timeout: timeout)
    }
    private func simctl(_ args: [String], timeout: TimeInterval = 30) throws -> DeviceRun {
        guard let x = tools.xcrun else { throw HandsError(.toolMissing, "xcrun isn't installed", suggestion: "Install Xcode's command line tools.", retry: .never) }
        return runner.run(x, ["simctl"] + args, timeout: timeout)
    }
    private func axe(_ args: [String], timeout: TimeInterval = 30) throws -> DeviceRun {
        guard let a = tools.axe else {
            throw HandsError(.toolMissing, "AXe isn't built", suggestion: "Run scripts/build-axe.sh once (it builds the pinned source in BaneySpaces' tools folder). BaneySpaces downloads and installs no binary.", retry: .never)
        }
        return runner.run(a, args, timeout: timeout)
    }

    /// What an action's failure means for a retry. Nothing reached the device when the program didn't
    /// start or adb says the device isn't there; a timeout may have landed.
    private func failed(_ r: DeviceRun, doing what: String) -> HandsError {
        let e = (r.err + r.text).lowercased()
        if !r.started { return HandsError(.toolMissing, "\(what): the tool wouldn't start (\(r.err))", suggestion: "Check the tool's path.", retry: .never) }
        if r.timedOut { return HandsError(.timeout, "\(what) timed out; it may have been delivered", suggestion: "Take a new snapshot and look before repeating it.", retry: .never) }
        if e.contains("device offline") || e.contains("no devices/emulators") || e.contains("device not found") || e.contains("not booted") || e.contains("unauthorized") || e.contains("error: closed") {
            return HandsError(.deviceOffline, "\(what): the device isn't answering", suggestion: "Wait a moment and send it again.", retry: .safe)
        }
        return HandsError(.actionFailed, "\(what) failed: \(r.err.split(separator: "\n").first.map(String.init) ?? "status \(r.status)")", suggestion: "Take a new snapshot and check the screen.", retry: .never)
    }

    // MARK: list

    private func listAll(ledger: DeviceLedger, includeShutdown: Bool) throws -> [DeviceInfo] {
        var out: [DeviceInfo] = []
        let t = now()
        if tools.xcrun != nil {
            let r = try simctl(["list", "-j", "devices", "available"])
            if r.ok, let sims = SimctlParse.devices(r.out) {
                for s in sims where s.runtime.contains("iOS") {
                    let id = "ios:\(s.udid)"
                    let version = s.runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.iOS-", with: "").replacingOccurrences(of: "-", with: ".")
                    out.append(DeviceInfo(id: id, platform: "ios", kind: "simulator", name: s.name, os: "iOS \(version)", state: s.state.lowercased() == "booted" ? "booted" : s.state.lowercased(),
                                          owned: ledger.owns(id), lent: ledger.lent(id, now: t), supported: true))
                }
            }
            let x = runner.run(tools.xcrun!, ["xctrace", "list", "devices"], timeout: 15)
            if x.ok {
                for d in XctraceParse.devices(x.text) {
                    out.append(DeviceInfo(id: "ios:\(d.udid)", platform: "ios", kind: "device", name: d.name, os: "iOS \(d.os)", state: "booted", owned: false, lent: false, supported: false,
                                          note: "physical iOS devices are not supported yet"))
                }
            }
        }
        if tools.adb != nil {
            let r = try adb(nil, ["devices", "-l"], timeout: 15)
            if r.ok {
                for d in AdbParse.devices(r.text) {
                    let id = "android:\(d.serial)"
                    let emu = AdbParse.isEmulator(d.serial)
                    let name = ledger.entry(id)?.name ?? d.model.replacingOccurrences(of: "_", with: " ")
                    out.append(DeviceInfo(id: id, platform: "android", kind: emu ? "emulator" : "device", name: name.isEmpty ? d.serial : name, os: "Android",
                                          state: d.state == "device" ? "booted" : d.state, owned: ledger.owns(id), lent: ledger.lent(id, now: t), supported: true))
                }
            }
        }
        return includeShutdown ? out : out.filter { $0.state == "booted" || $0.owned || $0.lent }
    }

    private func list(_ req: HandsRequest) throws -> HandsEnvelope {
        var ledger = store.load(); ledger.expire(now: now()); store.save(ledger)
        let all = try listAll(ledger: ledger, includeShutdown: req.bool("all"))
        guard tools.xcrun != nil || tools.adb != nil else {
            throw HandsError(.toolMissing, "neither xcrun nor adb is installed", suggestion: "Install Xcode or the Android SDK platform-tools. BaneySpaces installs nothing.", retry: .never)
        }
        let rows = all.map { $0.json }
        var data: [String: JSONValue] = ["devices": .array(rows)]
        var tips: [String] = []
        if tools.axe == nil, tools.xcrun != nil { tips.append("AXe isn't built, so iOS snapshot, tap and type are unavailable (scripts/build-axe.sh)") }
        if tools.adb == nil { tips.append("adb isn't installed, so Android devices are not listed") }
        if !tips.isEmpty { data["notes"] = .array(tips.map { .string($0) }) }
        return .success(.object(data))
    }

    // MARK: boot and shutdown

    private func boot(_ req: HandsRequest) throws -> HandsEnvelope {
        if req.bool("window") {
            throw HandsError(.notSupported, "device windows are not opened yet; devices boot headless", suggestion: "Use `device shot` to see the screen.", retry: .never)
        }
        let platform = req.string("platform") ?? (req.string("avd") != nil ? "android" : "ios")
        var ledger = store.load()
        if platform == "ios" {
            let model = req.string("model") ?? "iPhone 17 Pro"
            guard let t = tools.xcrun else { throw HandsError(.toolMissing, "xcrun isn't installed", suggestion: "Install Xcode.", retry: .never) }
            let types = SimctlParse.deviceTypes(try simctl(["list", "-j", "devicetypes"]).out) ?? []
            guard let type = types.first(where: { $0.name.lowercased() == model.lowercased() }) else {
                throw HandsError(.badArguments, "no device type called \(model)", suggestion: "Known: " + types.prefix(12).map(\.name).joined(separator: ", "), retry: .safe)
            }
            let runtimes = (SimctlParse.runtimes(try simctl(["list", "-j", "runtimes"]).out) ?? [])
            let chosen = req.string("os").flatMap { v in runtimes.first { $0.version == v || $0.version.hasPrefix(v + ".") } } ?? SimctlParse.newest(runtimes)
            guard let rt = chosen else { throw HandsError(.badArguments, "no iOS runtime\(req.string("os").map { " " + $0 } ?? "") is installed", suggestion: "Use `xcrun simctl list runtimes`.", retry: .never) }
            let name = "BaneySpaces \(agent) \(randomWord(4))"
            let made = try simctl(["create", name, type.identifier, rt.identifier])
            let udid = made.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard made.ok, udid.range(of: #"^[0-9A-Fa-f-]{36}$"#, options: .regularExpression) != nil else { throw failed(made, doing: "creating a simulator") }
            _ = t
            let booted = try simctl(["boot", udid], timeout: 90)
            let status = booted.ok ? try simctl(["bootstatus", udid], timeout: 180) : booted
            let id = "ios:\(udid)"
            guard status.ok else {
                _ = try? simctl(["shutdown", udid]); _ = try? simctl(["delete", udid])
                throw failed(status, doing: "booting \(model)")
            }
            ledger.add(.init(id: id, name: name, agent: agent, bootedAt: now(), created: true))
            store.save(ledger)
            let state = try listAll(ledger: ledger, includeShutdown: true).first { $0.id == id }?.state ?? "unknown"
            return .success(.object(["id": .string(id), "name": .string(name), "model": .string(type.name), "os": .string(rt.name),
                                     "evidence": evidence("simctl boot", verified: state == "booted", ["state": .string(state)])]))
        }
        guard platform == "android" else { throw HandsError(.badArguments, "platform is ios or android", suggestion: "Pass --platform ios or android.", retry: .safe) }
        guard let emu = tools.emulator else {
            throw HandsError(.toolMissing, "the Android emulator isn't installed", suggestion: "Install it from Android Studio's SDK Manager and set ANDROID_HOME. BaneySpaces installs nothing.", retry: .never)
        }
        let avds = runner.run(emu, ["-list-avds"], timeout: 15).text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasPrefix("INFO") && !$0.isEmpty }
        guard let avd = req.string("avd") ?? avds.first, avds.contains(avd) else {
            throw HandsError(.badArguments, "no AVD called \(req.string("avd") ?? "(none)")", suggestion: "AVDs: \(avds.joined(separator: ", ")). Create one in Android Studio; BaneySpaces creates none.", retry: .safe)
        }
        let busy = Set(AdbParse.devices(try adb(nil, ["devices"]).text).map(\.serial))
        guard let port = stride(from: 5554, through: 5584, by: 2).first(where: { !busy.contains("emulator-\($0)") }) else {
            throw HandsError(.actionFailed, "no free emulator port", suggestion: "Shut an emulator down.", retry: .never)
        }
        // -read-only: a second copy of the AVD runs from a throwaway overlay and never touches Donovan's saved state.
        guard let pid = runner.spawn(emu, ["-avd", avd, "-read-only", "-no-snapshot-save", "-no-boot-anim", "-no-audio", "-no-window", "-port", String(port)]) else {
            throw HandsError(.actionFailed, "the emulator wouldn't start", suggestion: "Run `emulator -avd \(avd)` yourself to see why.", retry: .never)
        }
        let serial = "emulator-\(port)", id = "android:\(serial)"
        // Claimed at once, so the process is ours while it boots.
        ledger.add(.init(id: id, name: avd, agent: agent, bootedAt: now(), pid: pid))
        store.save(ledger)
        var up = false
        for _ in 0..<90 {
            let state = try adb(serial, ["shell", "getprop", "sys.boot_completed"], timeout: 10)
            if state.ok, state.text.trimmingCharacters(in: .whitespacesAndNewlines) == "1" { up = true; break }
            sleep(2)
        }
        guard up else {
            _ = try? adb(serial, ["emu", "kill"])
            ledger.remove(id); store.save(ledger)
            throw HandsError(.timeout, "\(avd) didn't finish booting in 3 minutes", suggestion: "Try again, or start it by hand to see what it says.", retry: .safe)
        }
        return .success(.object(["id": .string(id), "name": .string(avd), "serial": .string(serial),
                                 "evidence": evidence("emulator -avd", verified: true, ["boot_completed": .string("1")])]))
    }

    private func shutdown(_ req: HandsRequest) throws -> HandsEnvelope {
        let t = try authorize(req.string("device"), needBooted: false)
        var ledger = store.load()
        guard let entry = ledger.entry(t.info.id) else {
            throw HandsError(.needsLend, "\(t.info.id) is lent to you, not yours to shut down", suggestion: "Return it with Donovan; he decides when it stops.", retry: .never)
        }
        switch t.platform {
        case .ios:
            let r = try simctl(["shutdown", t.native], timeout: 60)
            if !r.ok, !(r.err.contains("current state: Shutdown")) { throw failed(r, doing: "shutting down") }
            if entry.created { _ = try simctl(["delete", t.native], timeout: 60) }
        case .android:
            let r = try adb(t.native, ["emu", "kill"], timeout: 20)
            if !r.ok, !r.text.contains("OK") { throw failed(r, doing: "shutting down") }
            for _ in 0..<15 {
                if !AdbParse.devices(try adb(nil, ["devices"]).text).contains(where: { $0.serial == t.native }) { break }
                sleep(1)
            }
        }
        ledger.remove(t.info.id); store.save(ledger)
        lock.unlock(); defer { lock.lock() }
        snaps[t.info.id] = nil
        let gone = !((try? listAll(ledger: ledger, includeShutdown: true)) ?? []).contains { $0.id == t.info.id && $0.state == "booted" }
        return .success(.object(["id": .string(t.info.id), "evidence": evidence(t.platform == .ios ? "simctl shutdown" : "adb emu kill", verified: gone, ["still_running": .bool(!gone)])]))
    }

    // MARK: screen

    private func fetchTree(_ t: Target) throws -> (nodes: [UINode], size: (Double, Double)) {
        var nodes: [UINode]?
        switch t.platform {
        case .android:
            var r = try adb(t.native, ["exec-out", "uiautomator", "dump", "/dev/stdout"], timeout: 25)
            if !r.ok || !r.text.contains("<hierarchy") {
                // Some images refuse /dev/stdout: dump to a file and read it.
                let f = try adb(t.native, ["shell", "uiautomator", "dump", "/sdcard/bs-ui.xml"], timeout: 25)
                if f.ok { r = try adb(t.native, ["exec-out", "cat", "/sdcard/bs-ui.xml"], timeout: 15) }
            }
            if !r.ok { throw failed(r, doing: "reading the screen") }
            nodes = UiAutomatorParse.nodes(r.text)
        case .ios:
            let r = try axe(["describe-ui", "--udid", t.native])
            if !r.ok { throw failed(r, doing: "reading the screen") }
            nodes = AxeParse.nodes(r.out)
        }
        guard let nodes else {
            throw HandsError(.actionFailed, "the screen couldn't be read (an app that blocks accessibility, or the device is mid-animation)", suggestion: "Wait a second and take a new snapshot.", retry: .safe)
        }
        let root = nodes.max { $0.width * $0.height < $1.width * $1.height }
        return (nodes, (root?.width ?? 0, root?.height ?? 0))
    }

    private func snapshot(_ req: HandsRequest) throws -> HandsEnvelope {
        let t = try authorize(req.string("device"))
        let (raw, size) = try fetchTree(t)
        let sid = "d" + randomWord(8)
        var nodes = raw
        var shown: [UINode] = []
        for i in nodes.indices {
            let n = nodes[i]
            let wanted = req.bool("interactive") ? n.actionable : (n.actionable || !n.label.isEmpty || !n.value.isEmpty)
            guard wanted, n.hasArea else { continue }
            nodes[i].ref = "@\(sid):e\(shown.count + 1)"
            shown.append(nodes[i])
        }
        let capped = Array(shown.prefix(400))
        snaps[t.info.id] = Snap(sid: sid, nodes: capped, size: size)
        let rows: [JSONValue] = capped.map { n in
            var o: [String: JSONValue] = ["ref": .string(n.ref), "role": .string(n.role), "bounds": bounds(n), "enabled": .bool(n.enabled)]
            if !n.label.isEmpty { o["label"] = .string(n.label) }
            if !n.value.isEmpty { o["value"] = .string(n.value) }
            if !n.identifier.isEmpty { o["id"] = .string(n.identifier) }
            if n.checkable { o["checked"] = .bool(n.checked) }
            if n.focused { o["focused"] = .bool(true) }
            if n.editable { o["editable"] = .bool(true) }
            if n.scrollable { o["scrollable"] = .bool(true) }
            return .object(o)
        }
        return .success(.object(["snapshot": .string(sid), "device": .string(t.info.id), "screen": .object(["width": .int(Int(size.0)), "height": .int(Int(size.1))]),
                                 "elements": .array(rows), "truncated": .bool(shown.count > capped.count)]))
    }

    private func bounds(_ n: UINode) -> JSONValue {
        .object(["x": .int(Int(n.x)), "y": .int(Int(n.y)), "width": .int(Int(n.width)), "height": .int(Int(n.height))])
    }

    /// The live element a ref means. The ref must be from this device's latest snapshot; the element is found
    /// again on the live screen by what it is (role, id, label), so a screen that scrolled still taps the right
    /// thing, and one that changed refuses.
    private func resolve(_ ref: String?, on t: Target) throws -> (UINode, [UINode]) {
        guard let ref, ref.hasPrefix("@d"), let colon = ref.firstIndex(of: ":") else {
            throw HandsError(.badArguments, "a device ref looks like @d1a2b3c4d:e5", suggestion: "Take a snapshot with `device snapshot` and use a ref from it.", retry: .safe)
        }
        let sid = String(ref[ref.index(after: ref.startIndex)..<colon])
        guard let snap = snaps[t.info.id] else {
            throw HandsError(.unknownRef, "no snapshot of \(t.info.id) in this session", suggestion: "Take a snapshot first.", retry: .afterSnapshot)
        }
        guard snap.sid == sid else {
            throw HandsError(.staleRef, "\(ref) is from an older snapshot of this device", suggestion: "Take a new snapshot.", retry: .afterSnapshot)
        }
        guard let was = snap.nodes.first(where: { $0.ref == ref }) else {
            throw HandsError(.unknownRef, "\(ref) isn't in the snapshot", suggestion: "Use a ref the snapshot printed.", retry: .afterSnapshot)
        }
        let live = try fetchTree(t).nodes
        let same = live.filter { $0.identity == was.identity && $0.hasArea }
        let exact = same.filter { $0.x == was.x && $0.y == was.y && $0.width == was.width && $0.height == was.height }
        if exact.count == 1 { return (exact[0], live) }
        if same.count == 1 { return (same[0], live) }
        if same.isEmpty { throw HandsError(.staleRef, "\(ref) (\(was.label.isEmpty ? was.role : was.label)) is no longer on the screen", suggestion: "Take a new snapshot.", retry: .afterSnapshot) }
        throw HandsError(.ambiguousTarget, "\(ref) now matches \(same.count) elements", suggestion: "Take a new snapshot and pick again.", retry: .afterSnapshot)
    }

    static func hash(_ nodes: [UINode]) -> String {
        let s = nodes.map { "\($0.identity)@\(Int($0.x)),\(Int($0.y)),\(Int($0.width)),\(Int($0.height))=\($0.state)" }.joined(separator: "\n")
        return SHA256.hash(data: Data(s.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private func evidence(_ delivery: String, verified: Bool, _ readback: [String: JSONValue]) -> JSONValue {
        .object(["delivery": .string(delivery), "verified": .bool(verified), "readback": .object(readback)])
    }

    // MARK: input

    private func inject(_ t: Target, _ android: [String], _ ios: [String]) throws -> DeviceRun {
        let r = t.platform == .android ? try adb(t.native, ["shell", "input"] + android, timeout: 15) : try axe(ios + ["--udid", t.native], timeout: 20)
        if !r.ok { throw failed(r, doing: "sending input") }
        return r
    }

    private func tapAt(_ t: Target, _ x: Int, _ y: Int) throws {
        _ = try inject(t, ["tap", String(x), String(y)], ["tap", "-x", String(x), "-y", String(y)])
    }

    private func tap(_ req: HandsRequest) throws -> HandsEnvelope {
        let t = try authorize(req.string("device"))
        let before: [UINode]
        var target: UINode?
        let delivery = t.platform == .android ? "adb shell input tap" : "axe tap"
        let x: Int, y: Int
        if let ref = req.string("ref") {
            let (n, live) = try resolve(ref, on: t)
            guard n.enabled else { throw HandsError(.notSupported, "\(ref) is disabled", suggestion: "Pick an enabled element.", retry: .never) }
            target = n; before = live; x = Int(n.centerX); y = Int(n.centerY)
        } else if let px = req.int("x"), let py = req.int("y") {
            before = try fetchTree(t).nodes; x = px; y = py
            let (w, h) = snaps[t.info.id].map { ($0.size.w, $0.size.h) } ?? (Double.infinity, Double.infinity)
            guard px >= 0, py >= 0, Double(px) <= w, Double(py) <= h else { throw HandsError(.badArguments, "(\(px), \(py)) is off the screen", suggestion: "Use coordinates inside the screen from a snapshot.", retry: .safe) }
        } else {
            throw HandsError(.badArguments, "tap needs a ref, or x and y", suggestion: "`device tap <device> @dsid:e3`.", retry: .safe)
        }
        try tapAt(t, x, y)
        sleep(0.4)
        let after = try fetchTree(t).nodes
        return .success(.object(["device": .string(t.info.id), "evidence": changeEvidence(delivery, target: target, before: before, after: after)]))
    }

    /// The readback of an action: did the screen change, and for the element tapped, did its state.
    private func changeEvidence(_ delivery: String, target: UINode?, before: [UINode], after: [UINode]) -> JSONValue {
        let changed = Self.hash(before) != Self.hash(after)
        var read: [String: JSONValue] = ["screen_changed": .bool(changed), "before": .string(Self.hash(before)), "after": .string(Self.hash(after))]
        var verified = changed
        if let target, let now = after.first(where: { $0.identity == target.identity && $0.hasArea }) {
            if target.checkable { verified = now.checked != target.checked; read["checked"] = .bool(now.checked) }
            if target.editable { read["focused"] = .bool(now.focused); verified = verified || now.focused }
            if !now.value.isEmpty { read["value"] = .string(now.value) }
        }
        return evidence(delivery, verified: verified, read)
    }

    private func type(_ req: HandsRequest) throws -> HandsEnvelope {
        let t = try authorize(req.string("device"))
        guard let text = req.string("text"), !text.isEmpty else { throw HandsError(.badArguments, "type needs the text", suggestion: "`device type <device> <ref> <text>`.", retry: .safe) }
        guard text.count <= 500, !text.contains("\n"), text.unicodeScalars.allSatisfy({ $0.value >= 32 }) else {
            throw HandsError(.badArguments, "text must be one line of at most 500 characters", suggestion: "Type shorter pieces.", retry: .safe)
        }
        if t.platform == .android, !text.unicodeScalars.allSatisfy({ $0.isASCII }) {
            throw HandsError(.notSupported, "Android's `input text` takes only ASCII", suggestion: "Use ASCII text, or set the value another way.", retry: .never)
        }
        let (field, live) = try resolve(req.string("ref"), on: t)
        guard field.editable else { throw HandsError(.notSupported, "\(req.string("ref") ?? "") is not a text field", suggestion: "Pick an element marked editable.", retry: .never) }
        try tapAt(t, Int(field.centerX), Int(field.centerY))
        sleep(0.3)
        switch t.platform {
        case .android:
            // `input text` runs through a shell: spaces are %s, shell characters are escaped.
            let esc = text.map { c -> String in
                if c == " " { return "%s" }
                return "&|<>()*;$`\\\"'!#~{}[]?^=".contains(c) ? "\\\(c)" : String(c)
            }.joined()
            _ = try inject(t, ["text", esc], [])
        case .ios:
            _ = try inject(t, [], ["type", text])
        }
        sleep(0.3)
        let after = try fetchTree(t).nodes
        let now = after.first { $0.identity == field.identity && $0.hasArea } ?? after.first { $0.editable && $0.focused }
        let got = now?.value ?? ""
        let verified = got.contains(text) && got != field.value
        guard verified else {
            throw HandsError(.actionFailed, "typed, but the field reads \"\(got.prefix(60))\"", suggestion: "Take a new snapshot and check the field; the text may have gone elsewhere.", retry: .never)
        }
        _ = live
        return .success(.object(["device": .string(t.info.id), "evidence": evidence(t.platform == .android ? "adb shell input text" : "axe type", verified: true, ["value": .string(got)])]))
    }

    private func swipe(_ req: HandsRequest) throws -> HandsEnvelope {
        let t = try authorize(req.string("device"))
        var live = try fetchTree(t)
        var box = (x: 0.0, y: 0.0, w: live.size.0, h: live.size.1)
        var target: UINode?
        if let ref = req.string("ref") { let (n, l) = try resolve(ref, on: t); target = n; live = (l, live.size); box = (n.x, n.y, n.width, n.height) }
        let ms = max(100, min(req.int("duration_ms") ?? 300, 2000))
        var from: (Int, Int), to: (Int, Int)
        if let fx = req.int("from_x"), let fy = req.int("from_y"), let tx = req.int("to_x"), let ty = req.int("to_y") {
            from = (fx, fy); to = (tx, ty)
        } else if let dir = req.string("direction") {
            let cx = Int(box.x + box.w / 2), cy = Int(box.y + box.h / 2)
            let dx = Int(box.w * 0.35), dy = Int(box.h * 0.35)
            // The finger moves the way the content goes: "up" scrolls the content up (finger moves up).
            switch dir {
            case "up": from = (cx, cy + dy); to = (cx, cy - dy)
            case "down": from = (cx, cy - dy); to = (cx, cy + dy)
            case "left": from = (cx + dx, cy); to = (cx - dx, cy)
            case "right": from = (cx - dx, cy); to = (cx + dx, cy)
            default: throw HandsError(.badArguments, "direction is up, down, left or right", suggestion: "Or give from_x, from_y, to_x and to_y.", retry: .safe)
            }
        } else {
            throw HandsError(.badArguments, "swipe needs a direction, or from and to points", suggestion: "`device swipe <device> up [ref]`.", retry: .safe)
        }
        for v in [from.0, from.1, to.0, to.1] where v < 0 { throw HandsError(.badArguments, "a swipe point is off the screen", suggestion: "Stay inside the screen.", retry: .safe) }
        _ = try inject(t, ["swipe", String(from.0), String(from.1), String(to.0), String(to.1), String(ms)],
                       ["swipe", "--start-x", String(from.0), "--start-y", String(from.1), "--end-x", String(to.0), "--end-y", String(to.1), "--duration", String(Double(ms) / 1000)])
        sleep(0.4)
        let after = try fetchTree(t).nodes
        return .success(.object(["device": .string(t.info.id), "evidence": changeEvidence(t.platform == .android ? "adb shell input swipe" : "axe swipe", target: target, before: live.nodes, after: after)]))
    }

    static let androidKeys: [String: String] = ["home": "KEYCODE_HOME", "back": "KEYCODE_BACK", "menu": "KEYCODE_MENU", "enter": "KEYCODE_ENTER", "app_switch": "KEYCODE_APP_SWITCH",
                                                "power": "KEYCODE_POWER", "volume_up": "KEYCODE_VOLUME_UP", "volume_down": "KEYCODE_VOLUME_DOWN", "tab": "KEYCODE_TAB", "delete": "KEYCODE_DEL", "escape": "KEYCODE_ESCAPE"]
    static let iosButtons: [String: String] = ["home": "home", "lock": "lock", "power": "lock", "siri": "siri"]

    private func press(_ req: HandsRequest) throws -> HandsEnvelope {
        let t = try authorize(req.string("device"))
        let key = (req.string("key") ?? "").lowercased()
        let before = try fetchTree(t).nodes
        switch t.platform {
        case .android:
            guard let code = Self.androidKeys[key] else { throw HandsError(.notSupported, "no key \(key) on Android", suggestion: "Keys: " + Self.androidKeys.keys.sorted().joined(separator: ", "), retry: .never) }
            _ = try inject(t, ["keyevent", code], [])
        case .ios:
            guard let b = Self.iosButtons[key] else { throw HandsError(.notSupported, "no key \(key) on iOS", suggestion: "Keys: " + Self.iosButtons.keys.sorted().joined(separator: ", "), retry: .never) }
            _ = try inject(t, [], ["button", b])
        }
        sleep(0.4)
        // A locked screen can't be read; the key still went in, so the evidence says it can't be checked.
        guard let after = try? fetchTree(t).nodes else {
            return .success(.object(["device": .string(t.info.id), "evidence": evidence("press \(key)", verified: false, ["screen_changed": .null, "reason": .string("the screen couldn't be read after the key")])]))
        }
        return .success(.object(["device": .string(t.info.id), "evidence": changeEvidence("press \(key)", target: nil, before: before, after: after)]))
    }

    // MARK: apps, shots, logs

    private func openApp(_ req: HandsRequest) throws -> HandsEnvelope {
        let t = try authorize(req.string("device"))
        guard let app = req.string("app"), app.range(of: #"^[A-Za-z0-9._-]{1,200}$"#, options: .regularExpression) != nil else {
            throw HandsError(.badArguments, "app is a bundle id or package name like com.apple.Preferences", suggestion: "No spaces or paths.", retry: .safe)
        }
        if let url = req.string("url"), url.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://[^\s'";&|`$<>\\]+$"#, options: .regularExpression) == nil {
            throw HandsError(.badArguments, "that isn't a plain URL", suggestion: "Pass scheme://host/path with no spaces or shell characters.", retry: .safe)
        }
        switch t.platform {
        case .ios:
            if let url = req.string("url") {
                let r = try simctl(["openurl", t.native, url]); if !r.ok { throw failed(r, doing: "opening the URL") }
                return .success(.object(["device": .string(t.info.id), "evidence": evidence("simctl openurl", verified: true, ["url": .string(url)])]))
            }
            let r = try simctl(["launch", t.native, app])
            if !r.ok { throw failed(r, doing: "launching \(app)") }
            // "com.apple.Preferences: 1234": the pid is the device's word that it is running.
            let pid = r.text.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            return .success(.object(["device": .string(t.info.id), "evidence": evidence("simctl launch", verified: Int(pid) != nil, ["app": .string(app), "pid": .string(pid)])]))
        case .android:
            let r: DeviceRun
            if let url = req.string("url") { r = try adb(t.native, ["shell", "am", "start", "-W", "-a", "android.intent.action.VIEW", "-d", "'\(url)'"]) }
            else { r = try adb(t.native, ["shell", "monkey", "-p", app, "-c", "android.intent.category.LAUNCHER", "1"]) }
            if !r.ok || r.text.contains("No activities found") || r.text.contains("Error:") { throw failed(DeviceRun(status: 1, err: r.text, timedOut: r.timedOut, started: r.started), doing: "launching \(app)") }
            sleep(0.8)
            let focus = try adb(t.native, ["shell", "dumpsys", "window"], timeout: 20).text
            let line = focus.split(whereSeparator: \.isNewline).first { $0.contains("mCurrentFocus") }.map(String.init) ?? ""
            let verified = req.string("url") != nil ? !line.isEmpty : line.contains(app)
            return .success(.object(["device": .string(t.info.id), "evidence": evidence("adb shell monkey", verified: verified, ["focus": .string(line.trimmingCharacters(in: .whitespaces))])]))
        }
    }

    private func shot(_ req: HandsRequest) throws -> HandsEnvelope {
        let t = try authorize(req.string("device"))
        if let o = req.string("out"), !HandoffPath.isPlainFileName(o) {
            throw HandsError(.badArguments, "out is a plain file name, no folder", suggestion: "Pass a name like home.png.", retry: .safe)
        }
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let name = req.string("out") ?? "\(t.info.id.replacingOccurrences(of: ":", with: "-"))-\(Int(now().timeIntervalSince1970)).png"
        let file = shots.appendingPathComponent(name.hasSuffix(".png") ? name : name + ".png")
        var data: Data
        switch t.platform {
        case .android:
            let r = try adb(t.native, ["exec-out", "screencap", "-p"], timeout: 30)
            if !r.ok { throw failed(r, doing: "taking a screenshot") }
            data = r.out
        case .ios:
            let r = try simctl(["io", t.native, "screenshot", "--type=png", file.path])
            if !r.ok { throw failed(r, doing: "taking a screenshot") }
            data = (try? Data(contentsOf: file)) ?? Data()
        }
        let png = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        if t.platform == .android, png { try data.write(to: file, options: .atomic) }
        guard png else { throw HandsError(.actionFailed, "the device didn't return a PNG", suggestion: "Try again in a second.", retry: .safe) }
        return .success(.object(["device": .string(t.info.id), "path": .string(file.path), "bytes": .int(data.count),
                                 "evidence": evidence(t.platform == .android ? "adb exec-out screencap" : "simctl io screenshot", verified: true, ["png": .bool(true), "bytes": .int(data.count)])]))
    }

    private func log(_ req: HandsRequest) throws -> HandsEnvelope {
        let t = try authorize(req.string("device"))
        let lines = max(1, min(req.int("lines") ?? 200, 2000))
        let since = max(1, min(req.int("since") ?? 60, 3600))
        let r: DeviceRun
        switch t.platform {
        case .android: r = try adb(t.native, ["logcat", "-d", "-t", String(lines)], timeout: 30)
        case .ios: r = try simctl(["spawn", t.native, "log", "show", "--last", "\(since)s", "--style", "compact"], timeout: 60)
        }
        if !r.ok { throw failed(r, doing: "reading the log") }
        let all = r.text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let tail = Array(all.suffix(lines))
        return .success(.object(["device": .string(t.info.id), "lines": .array(tail.map { .string($0) }), "count": .int(tail.count),
                                 "evidence": evidence(t.platform == .android ? "adb logcat" : "simctl spawn log show", verified: true, ["count": .int(tail.count)])]))
    }
}

/// What a listed device is.
public struct DeviceInfo: Equatable, Sendable {
    public var id: String, platform: String, kind: String, name: String, os: String, state: String
    public var owned: Bool, lent: Bool, supported: Bool
    public var note: String? = nil
    var json: JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "platform": .string(platform), "kind": .string(kind), "name": .string(name), "os": .string(os), "state": .string(state),
                                      "owned": .bool(owned), "lent": .bool(lent), "usable": .bool(supported && (owned || lent)), "supported": .bool(supported)]
        if let note { o["note"] = .string(note) }
        return .object(o)
    }
}

enum DeviceTools_ {
    static let verbs = ["device-list", "device-boot", "device-shutdown", "device-open-app", "device-snapshot", "device-tap", "device-type", "device-swipe", "device-press", "device-shot", "device-log"]
}
