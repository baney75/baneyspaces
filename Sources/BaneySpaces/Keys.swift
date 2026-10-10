import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// The modifier the workspace shortcuts use. Moving a window always adds ⇧.
enum Modifier: String, CaseIterable, Identifiable {
    case command, control, option, controlOption

    var id: String { rawValue }

    static var current: Modifier {
        get { Modifier(rawValue: UserDefaults.standard.string(forKey: "modifier") ?? "") ?? .command }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "modifier") }
    }

    var symbol: String {
        switch self {
        case .command: "⌘"
        case .control: "⌃"
        case .option: "⌥"
        case .controlOption: "⌃⌥"
        }
    }

    var carbon: Int {
        switch self {
        case .command: cmdKey
        case .control: controlKey
        case .option: optionKey
        case .controlOption: controlKey | optionKey
        }
    }

    var menuFlags: NSEvent.ModifierFlags {
        switch self {
        case .command: [.command]
        case .control: [.control]
        case .option: [.option]
        case .controlOption: [.control, .option]
        }
    }

    /// What the person gives up by picking this modifier.
    var tradeoff: String {
        switch self {
        case .command: "Replaces app shortcuts like ⌘1 for a browser's first tab."
        case .control: "Rarely used by apps. Leaves ⌘1–⌘9 to your browser and editor."
        case .option: "⌥ with a number types symbols like ¡ and ™; those stop working."
        case .controlOption: "Free in nearly every app, at the cost of a two-key hold."
        }
    }
}

/// macOS's own shortcuts that would take the keys before BaneySpaces sees them.
enum SystemShortcuts {
    private static let domain = "com.apple.symbolichotkeys" as CFString

    /// Screenshot shortcuts on ⌘⇧3, ⌘⇧4 and ⌘⇧5, with the values macOS stores for each.
    private static let screenshots: [(id: Int, key: Int, code: Int)] = [(28, 51, 20), (30, 52, 21), (184, 53, 23)]
    /// "Switch to Desktop 1–9" on ⌃1–⌃9.
    private static let desktopSwitch = Array(118...126)

    private static func enabled(_ id: Int) -> Bool {
        CFPreferencesAppSynchronize(domain)
        let all = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain) as? [String: Any]
        guard let entry = all?[String(id)] as? [String: Any], let on = entry["enabled"] as? Bool else {
            // macOS turns the screenshot shortcuts on by default and desktop switching off.
            return id < 118 || id > 126
        }
        return on
    }

    /// Conflicts for a modifier, as one sentence each, or empty.
    static func conflicts(for m: Modifier) -> [String] {
        switch m {
        case .command:
            return screenshots.contains { enabled($0.id) }
                ? ["macOS uses ⌘⇧3, ⌘⇧4 and ⌘⇧5 for screenshots, so those keys can't move windows."] : []
        case .control:
            return desktopSwitch.contains(where: enabled)
                ? ["macOS uses ⌃1–⌃9 to switch Mission Control desktops."] : []
        case .option, .controlOption:
            return []
        }
    }

    /// Turns off the shortcuts that conflict with `m`. ⌃⌘⇧3 and ⌃⌘⇧4 still take screenshots.
    static func free(for m: Modifier) {
        var writes: [(Int, String)] = []
        switch m {
        case .command:
            for s in screenshots {
                writes.append((s.id, "<dict><key>enabled</key><false/><key>value</key><dict><key>parameters</key><array><integer>\(s.key)</integer><integer>\(s.code)</integer><integer>1179648</integer></array><key>type</key><string>standard</string></dict></dict>"))
            }
        case .control:
            for (i, id) in desktopSwitch.enumerated() {
                let key = 65535, code = Hotkeys.digitKeyCodes[i]
                writes.append((id, "<dict><key>enabled</key><false/><key>value</key><dict><key>parameters</key><array><integer>\(key)</integer><integer>\(code)</integer><integer>262144</integer></array><key>type</key><string>standard</string></dict></dict>"))
            }
        case .option, .controlOption:
            return
        }
        for (id, value) in writes {
            run("/usr/bin/defaults", ["write", "com.apple.symbolichotkeys", "AppleSymbolicHotKeys", "-dict-add", String(id), value])
        }
        // Applies the change without logging out.
        run("/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings", ["-u"])
    }

    private static func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }
}

// Read-only SkyLight calls: how many Mission Control desktops exist.
@_silgen_name("CGSMainConnectionID") private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces") private func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray

enum Desktops {
    /// The most regular (not full-screen) Mission Control desktops on any display.
    static var count: Int {
        let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]] ?? []
        return displays.map { d in
            (d["Spaces"] as? [[String: Any]] ?? []).filter { ($0["type"] as? Int) == 0 }.count
        }.max() ?? 1
    }
}
