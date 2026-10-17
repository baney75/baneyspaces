import AppKit
import BaneySpacesCore
import IOKit
import IOKit.usb

/// Phones in the Deck. Android comes from `adb track-devices`, which reports every plug, unplug
/// and "Allow USB debugging?" answer as it happens. iPhones come from Xcode's devicectl, asked
/// again whenever a USB device comes or goes, and once a minute for ones on Wi-Fi.
final class PhoneWatcher {
    var onChange: () -> Void = {}
    private(set) var android: [Phone] = []
    private(set) var ios: [Phone] = []
    var phones: [Phone] { android + ios }

    private var tracker: Process?
    private var buffer = Data()
    private var running = false
    private var iosTimer: Timer?
    private var iosBusy = false
    private var notifyPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    /// scrcpy windows this Mac opened, by serial.
    private var mirrors: [String: Process] = [:]

    static let adb: String? = Tool.find("adb", extra: [NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb"])
    static let scrcpy: String? = Tool.find("scrcpy")

    func start() {
        guard !running else { return }
        running = true
        startTracker()
        refreshIOS()
        iosTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refreshIOS() }
        iosTimer?.tolerance = 10
        watchUSB()
    }

    func stop() {
        running = false
        tracker?.terminate()
        tracker = nil
        iosTimer?.invalidate()
        iterators.forEach { IOObjectRelease($0) }
        iterators.removeAll()
        if let p = notifyPort { IONotificationPortDestroy(p) }
        notifyPort = nil
        android = []; ios = []
    }

    // MARK: Android

    private func startTracker() {
        guard running, let adb = Self.adb else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb)
        p.arguments = ["track-devices", "-l"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            DispatchQueue.main.async { self?.received(chunk) }
        }
        p.terminationHandler = { [weak self] _ in
            // adb's server restarted or went away: try again shortly, while the Deck is on.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.startTracker() }
        }
        do { try p.run(); tracker = p } catch { tracker = nil }
    }

    private func received(_ chunk: Data) {
        guard running, !chunk.isEmpty else { return }
        buffer.append(chunk)
        for m in AdbTrack.messages(&buffer) {
            let now = AdbTrack.phones(m)
            if now != android { android = now; onChange() }
        }
    }

    // MARK: iPhone

    func refreshIOS() {
        guard running, !iosBusy, FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else { return }
        iosBusy = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("baneyspaces-devices-\(getpid()).json")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            p.arguments = ["devicectl", "list", "devices", "--json-output", out.path, "--quiet"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            var found: [Phone] = []
            if (try? p.run()) != nil {
                let deadline = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: deadline)
                p.waitUntilExit()
                deadline.cancel()
                if let d = try? Data(contentsOf: out) { found = DeviceCtl.phones(d) }
                try? FileManager.default.removeItem(at: out)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.iosBusy = false
                if found != self.ios { self.ios = found; self.onChange() }
            }
        }
    }

    /// Any USB device arriving or leaving asks devicectl again (and adb notices by itself).
    private func watchUSB() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            while case let o = IOIteratorNext(iterator), o != 0 { IOObjectRelease(o) }
            guard let refcon else { return }
            let me = Unmanaged<PhoneWatcher>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { me.refreshIOS() }
        }
        for kind in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var it: io_iterator_t = 0
            guard IOServiceAddMatchingNotification(port, kind, IOServiceMatching("IOUSBHostDevice"), callback, refcon, &it) == KERN_SUCCESS else { continue }
            while case let o = IOIteratorNext(it), o != 0 { IOObjectRelease(o) }
            iterators.append(it)
        }
    }

    // MARK: acting

    func phone(_ itemID: String) -> Phone? { phones.first { $0.item.id == itemID } }

    /// The phone's screen: scrcpy's mirror for Android, iPhone Mirroring or Simulator for iOS.
    func open(_ phone: Phone) {
        switch phone.platform {
        case .ios:
            // iPhone Mirroring has no iPad mode; opening it for one would show the wrong device.
            guard !phone.tablet || phone.simulator else { return NSSound.beep() }
            let app = phone.simulator ? "com.apple.iphonesimulator" : "com.apple.ScreenContinuity"
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
            }
        case .android:
            if let m = mirrors[phone.id], m.isRunning {
                NSRunningApplication(processIdentifier: m.processIdentifier)?.activate()
                return
            }
            guard phone.ready else { return NSSound.beep() }
            guard let scrcpy = Self.scrcpy else { return shell(phone) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: scrcpy)
            p.arguments = ["-s", phone.id, "--window-title", phone.name, "--stay-awake"]
            var env = ProcessInfo.processInfo.environment
            if let adb = Self.adb { env["ADB"] = adb }
            p.environment = env
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil { mirrors[phone.id] = p }
        }
    }

    /// `adb shell` on the phone in a new Ghostty window.
    func shell(_ phone: Phone) {
        guard phone.platform == .android, let adb = Self.adb, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        cfg.arguments = ["--quit-after-last-window-closed=true", "--window-save-state=never", "-e", adb, "-s", phone.id, "shell"]
        NSWorkspace.shared.openApplication(at: url, configuration: cfg)
    }

    /// A screenshot of an Android phone, saved to the Desktop and shown in Finder.
    func screenshot(_ phone: Phone) {
        guard phone.platform == .android, phone.ready, let adb = Self.adb else { return NSSound.beep() }
        DispatchQueue.global(qos: .userInitiated).async {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: ".")
            let dest = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/\(phone.name) \(stamp).png")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: adb)
            p.arguments = ["-s", phone.id, "exec-out", "screencap", "-p"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0, data.count > 8, (try? data.write(to: dest)) != nil else { return }
            DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([dest]) }
        }
    }
}

/// Command line tools found without a shell: Homebrew's folders, then any extra places.
enum Tool {
    static func find(_ name: String, extra: [String] = []) -> String? {
        (["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"] + extra).first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
