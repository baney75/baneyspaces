import BaneySpacesCore
import Darwin
import Foundation

/// `baneyspaces phone …`: phones for agents. Android runs through adb directly, so it works even
/// with the session engine off; an iPhone is driven through its iPhone Mirroring window with `baneyspaces agent`.
enum PhoneCommand {
    static let usage = """
    usage: baneyspaces phone <command> [-s SERIAL]

      ls                        connected phones (Android and iPhone)
      ui                        the screen's UI tree as XML (Android): find buttons by text
      size                      the screen size in pixels (Android)
      shot [file.png]           a screenshot (Android)
      tap X Y                   tap at pixels (Android)
      swipe X1 Y1 X2 Y2 [ms]    swipe (Android)
      type TEXT                 type into the focused field (Android)
      key home|back|enter|menu|power|NAME   press a key (Android)
      shell [command…]          adb shell (Android)
      mirror                    show the phone's screen: scrcpy, or iPhone Mirroring

    An iPhone is driven through its iPhone Mirroring window: `baneyspaces agent open
    "iPhone Mirroring"` puts it on the agent workspace, then `baneyspaces agent` works it from behind.
    """

    static var adb: String? {
        ["/opt/homebrew/bin/adb", "/usr/local/bin/adb", NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(_ args: [String]) -> Never {
        var args = args
        var serial: String?
        if let i = args.firstIndex(of: "-s"), i + 1 < args.count { serial = args[i + 1]; args.removeSubrange(i...i + 1) }
        let sub = args.first ?? "ls"
        let rest = Array(args.dropFirst())
        if sub == "ls" { list() }
        if sub == "mirror" { mirror(serial) }
        if sub == "help" || sub == "-h" { print(usage); exit(0) }
        guard let adb else { fail("adb isn't installed: brew install android-platform-tools") }
        let s = serial ?? onlyReady(adb)
        func adbRun(_ a: [String], capture: Bool = false) -> Data {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: adb)
            p.arguments = ["-s", s] + a
            let pipe = Pipe()
            if capture { p.standardOutput = pipe }
            do { try p.run() } catch { fail("couldn't run adb") }
            let d = capture ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
            p.waitUntilExit()
            if p.terminationStatus != 0 { exit(p.terminationStatus) }
            return d
        }
        switch sub {
        case "ui":
            FileHandle.standardOutput.write(adbRun(["exec-out", "uiautomator", "dump", "/dev/tty"], capture: true))
        case "size":
            FileHandle.standardOutput.write(adbRun(["shell", "wm", "size"], capture: true))
        case "shot":
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: ".")
            let path = rest.first ?? "phone-\(stamp).png"
            let png = adbRun(["exec-out", "screencap", "-p"], capture: true)
            guard png.count > 8, (try? png.write(to: URL(fileURLWithPath: path))) != nil else { fail("no screenshot") }
            print(path)
        case "tap":
            guard rest.count == 2, rest.allSatisfy({ Int($0) != nil }) else { fail("usage: baneyspaces phone tap X Y", code: 2) }
            _ = adbRun(["shell", "input", "tap"] + rest)
        case "swipe":
            guard (4...5).contains(rest.count), rest.allSatisfy({ Int($0) != nil }) else { fail("usage: baneyspaces phone swipe X1 Y1 X2 Y2 [ms]", code: 2) }
            _ = adbRun(["shell", "input", "swipe"] + rest)
        case "type":
            guard !rest.isEmpty else { fail("usage: baneyspaces phone type TEXT", code: 2) }
            _ = adbRun(["shell", "input", "text", AdbTrack.inputText(rest.joined(separator: " "))])
        case "key":
            guard let k = rest.first else { fail("usage: baneyspaces phone key home|back|enter|…", code: 2) }
            let named = ["home": "KEYCODE_HOME", "back": "KEYCODE_BACK", "enter": "KEYCODE_ENTER", "menu": "KEYCODE_MENU",
                         "power": "KEYCODE_POWER", "up": "KEYCODE_DPAD_UP", "down": "KEYCODE_DPAD_DOWN", "tab": "KEYCODE_TAB",
                         "delete": "KEYCODE_DEL", "recents": "KEYCODE_APP_SWITCH", "volup": "KEYCODE_VOLUME_UP", "voldown": "KEYCODE_VOLUME_DOWN"]
            let code = named[k.lowercased()] ?? k
            guard code.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { fail("not a key: \(k)", code: 2) }
            _ = adbRun(["shell", "input", "keyevent", code])
        case "shell":
            // Hands the terminal to adb, so an interactive shell works.
            let argv = [adb, "-s", s, "shell"] + rest
            var cargs = argv.map { strdup($0) } + [nil]
            execv(adb, &cargs)
            fail("couldn't start adb")
        default:
            fail(usage, code: 2)
        }
        exit(0)
    }

    static func list() -> Never {
        if let reply = Wire.call(Wire.Request(op: .list), timeout: 1), let items = reply.items {
            let phones = items.filter { $0.kind == .device }
            if phones.isEmpty { print("no phones (plug one in; Android needs USB debugging on)") }
            for p in phones { print("\(p.id)\t\(p.label)\t\(p.detail)") }
            exit(0)
        }
        // The session engine is off: ask adb itself.
        guard let adb else { fail("BaneySpaces isn't running and adb isn't installed") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb)
        p.arguments = ["devices", "-l"]
        try? p.run()
        p.waitUntilExit()
        exit(p.terminationStatus)
    }

    static func mirror(_ serial: String?) -> Never {
        let items = Wire.call(Wire.Request(op: .list), timeout: 1)?.items?.filter { $0.kind == .device } ?? []
        let pick = serial.flatMap { s in items.first { $0.id.hasSuffix(":" + s) } } ?? (items.count == 1 ? items.first : nil)
        guard let pick else { fail(items.isEmpty ? "no phones" : "more than one phone: pass -s SERIAL") }
        guard let r = Wire.call(Wire.Request(op: .focus, target: pick.id), timeout: 2), r.ok else { fail("BaneySpaces didn't answer") }
        exit(0)
    }

    /// The one Android phone that's ready, or a clear error.
    static func onlyReady(_ adb: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb)
        p.arguments = ["devices"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let ready = out.split(separator: "\n").dropFirst().compactMap { line -> String? in
            let f = line.split(separator: "\t")
            return f.count == 2 && f[1] == "device" ? String(f[0]) : nil
        }
        if ready.count == 1 { return ready[0] }
        fail(ready.isEmpty ? "no Android phone ready (plug one in and allow USB debugging)" : "more than one phone: pass -s SERIAL (\(ready.joined(separator: ", ")))")
    }
}
