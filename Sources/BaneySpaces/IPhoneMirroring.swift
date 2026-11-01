import AppKit
import ApplicationServices
import BaneySpacesCore

/// iPhone Mirroring as the launcher drives it (`IPhoneOpen`): its own menu bar through Accessibility, and
/// keys posted to its pid only. Nothing is written to its container and nothing of it is read from disk but
/// its own localized strings (the app bundle and its framework, which anyone may read).
enum IPhoneMirroring {
    static let bundleID = "com.apple.ScreenContinuity"
    static let path = "/System/Applications/iPhone Mirroring.app"
    private static let strings = path + "/Contents/Frameworks/ScreenContinuityUI.framework/Versions/A/Resources/Localizable.loctable"

    /// Whether this Mac has iPhone Mirroring (macOS 15 and later). Asked once.
    static let installed: Bool = FileManager.default.fileExists(atPath: path)

    static var running: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    /// Mirroring's own words, in the Mac's language where its resources have them, else English.
    private static let table: [String: [String: String]] = {
        guard let all = NSDictionary(contentsOfFile: strings) as? [String: [String: String]] else { return [:] }
        return all
    }()

    private static func localized(_ key: String) -> String? {
        for lang in Locale.preferredLanguages + ["en"] {
            let parts = lang.split(separator: "-").map(String.init)
            for candidate in [lang, lang.replacingOccurrences(of: "-", with: "_"), parts.first ?? lang] {
                if let v = table[candidate]?[key], !v.isEmpty { return v }
            }
        }
        return nil
    }

    /// The state strings as Mirroring words them here.
    static var phrases: IPhoneState.Phrases {
        var p = IPhoneState.Phrases.english
        if let v = localized("Unlock Your iPhone") { p.needsUnlock = v }
        if let v = localized("Unable to Connect to iPhone") { p.unavailable = v }
        if let v = localized("Mac Locked") { p.macLocked = v }
        if let v = localized("Connecting to %@") ?? localized("Connecting to") {
            p.connecting = v.replacingOccurrences(of: "%@", with: "").trimmingCharacters(in: .whitespaces)
        }
        return p
    }

    /// Mirroring's titles for its Spotlight menu item, if its resources name one.
    static var spotlightTitles: [String] {
        var titles: [String] = []
        for key in table["en"]?.keys.filter({ $0.caseInsensitiveCompare("Spotlight") == .orderedSame }) ?? [] {
            if let v = localized(key) { titles.append(v) }
        }
        return titles
    }

    // MARK: Reading

    /// The text in Mirroring's windows, for the state: static texts, buttons and titles, nothing from the phone's video.
    static func texts(of pid: pid_t) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var out: [String] = []
        var seen = 0
        func walk(_ e: AXUIElement, depth: Int) {
            guard depth < 8, seen < 300 else { return }
            seen += 1
            AXUIElementSetMessagingTimeout(e, 0.25)
            for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                if let s: String = e.value(attr), !s.isEmpty { out.append(s) }
            }
            for child: AXUIElement in e.value(kAXChildrenAttribute) ?? [] { walk(child, depth: depth + 1) }
        }
        for w: AXUIElement in app.value(kAXWindowsAttribute) ?? [] { walk(w, depth: 0) }
        return out
    }

    static func windowCount(of pid: pid_t) -> Int {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        return (app.value(kAXWindowsAttribute) as [AXUIElement]?)?.count ?? 0
    }

    /// What Mirroring reports now, and the phrase it used. Nothing is started: not running reads unknown.
    static func readState() -> (state: IPhoneState, phrase: String?) {
        guard installed, let pid = running?.processIdentifier else { return (.unknown, nil) }
        return IPhoneState.classify(texts(of: pid), phrases: phrases)
    }

    // MARK: Driving

    /// Opens Spotlight from the menu bar. Matched on the menu item's title, never on a key chord.
    static func pressSpotlight(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let bar: AXUIElement = app.value(kAXMenuBarAttribute) else { return false }
        let known = spotlightTitles
        func children(_ e: AXUIElement) -> [AXUIElement] {
            AXUIElementSetMessagingTimeout(e, 0.25)
            return e.value(kAXChildrenAttribute) ?? []
        }
        for menu in children(bar).dropFirst() {
            for list in children(menu) {
                for item in children(list) {
                    guard let title = item.string(kAXTitleAttribute), item.bool(kAXEnabledAttribute),
                          IPhoneSearch.isSpotlightItem(title, known: known) else { continue }
                    return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                }
            }
        }
        return false
    }

    /// Text into a field Mirroring exposes (its window is mostly the phone's video, so usually there is none).
    static func setFieldValue(_ text: String, pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var found = false
        func walk(_ e: AXUIElement, depth: Int) {
            guard depth < 8, !found else { return }
            let role = e.string(kAXRoleAttribute)
            if role == kAXTextFieldRole as String || role == kAXTextAreaRole as String || e.string(kAXSubroleAttribute) == kAXSearchFieldSubrole as String {
                var settable: DarwinBoolean = false
                if AXUIElementIsAttributeSettable(e, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue,
                   AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, text as CFString) == .success {
                    found = true
                    return
                }
            }
            for child: AXUIElement in e.value(kAXChildrenAttribute) ?? [] { walk(child, depth: depth + 1) }
        }
        for w: AXUIElement in app.value(kAXWindowsAttribute) ?? [] { walk(w, depth: 0) }
        return found
    }

    /// Keys for `text`, posted to Mirroring's pid and nowhere else: a private event source (no modifier or
    /// key state from the real keyboard) and `postToPid`, never the system's event tap.
    static func postKeys(_ text: String, pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .privateState) else { return false }
        for ch in text {
            let units = Array(String(ch).utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return false }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            down.postToPid(pid)
            up.postToPid(pid)
            usleep(12_000)
        }
        return true
    }
}

/// The live Mirroring for `IPhoneOpen`. Blocks: run it off the main thread.
final class LiveMirroring: MirroringDriver {
    private let startUp: () -> Void
    private(set) var phrase: String?

    /// `startUp` opens Mirroring on the target workspace (the launcher's open here), on the main thread.
    init(startUp: @escaping () -> Void) { self.startUp = startUp }

    private var pid: pid_t? { IPhoneMirroring.running?.processIdentifier }

    func bringUp() -> Bool {
        DispatchQueue.main.async(execute: startUp)
        let end = Date().addingTimeInterval(10)
        while Date() < end {
            if let pid, IPhoneMirroring.windowCount(of: pid) > 0 {
                // Its window is up; the screen inside takes a moment to draw its state text.
                usleep(600_000)
                return true
            }
            usleep(100_000)
        }
        return false
    }

    func state() -> IPhoneState {
        guard let pid else { return .unknown }
        let r = IPhoneState.classify(IPhoneMirroring.texts(of: pid), phrases: IPhoneMirroring.phrases)
        phrase = r.phrase
        return r.state
    }

    func openSpotlight() -> Bool {
        guard let pid else { return false }
        return IPhoneMirroring.pressSpotlight(pid: pid)
    }

    func type(_ text: String) -> Bool {
        guard let pid else { return false }
        // Spotlight takes a moment to appear on the phone before it can take text.
        usleep(700_000)
        return IPhoneMirroring.setFieldValue(text, pid: pid) || IPhoneMirroring.postKeys(text, pid: pid)
    }
}
