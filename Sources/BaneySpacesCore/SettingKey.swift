import Foundation

/// The settings `baneyspaces set` and `baneyspaces get` reach, by the names the spec gives them
/// (spec/themes.md, "Settings"). The same names are in Settings on every platform.
public enum SettingKey: String, CaseIterable, Sendable {
    case theme = "appearance.theme"
    case palette = "appearance.palette"
    case dockEnabled = "dock.enabled"
    case launcherOpen = "behavior.launcher.open"

    public init?(name: String) { self.init(rawValue: name.trimmingCharacters(in: .whitespaces).lowercased()) }

    public var usage: String {
        switch self {
        case .theme: "\(rawValue) \(ThemeID.allCases.map(\.rawValue).joined(separator: "|"))"
        case .palette: "\(rawValue) auto|\(PaletteCatalog.shared.names.joined(separator: "|"))"
        case .dockEnabled: "\(rawValue) true|false"
        case .launcherOpen: "\(rawValue) \(OpenHere.Mode.allCases.map(\.rawValue).joined(separator: "|"))"
        }
    }

    /// The value as it is stored and shown, or nil when it isn't one this setting takes.
    public func normalized(_ text: String) -> String? {
        let v = text.trimmingCharacters(in: .whitespaces).lowercased()
        switch self {
        case .theme: return ThemeID(rawValue: v)?.rawValue
        case .palette: return v == AppearanceSettings.autoPalette || PaletteCatalog.shared.named(v) != nil ? v : nil
        case .dockEnabled:
            if ["true", "on", "yes", "1"].contains(v) { return "true" }
            if ["false", "off", "no", "0"].contains(v) { return "false" }
            return nil
        case .launcherOpen: return OpenHere.Mode(rawValue: v)?.rawValue
        }
    }

    /// What a `set` or `get` was asked, from the request's fields.
    public enum Ask: Equatable {
        case get(SettingKey)
        case set(SettingKey, String)
        case list
        case refused(String)
    }

    public static func ask(target: String?, text: String?) -> Ask {
        // A name that is empty (an unset variable in a script) is a mistake, never "list everything"
        // when a value came with it.
        if text != nil, target?.isEmpty ?? true { return .refused("no setting name; the settings are \(allCases.map(\.rawValue).joined(separator: ", "))") }
        guard let target, !target.isEmpty else { return .list }
        guard let key = SettingKey(name: target) else {
            return .refused("no setting \(target); the settings are \(allCases.map(\.rawValue).joined(separator: ", "))")
        }
        guard let text else { return .get(key) }
        guard let value = key.normalized(text) else { return .refused("\(text) isn't a value for \(key.rawValue): use \(key.usage)") }
        return .set(key, value)
    }
}
