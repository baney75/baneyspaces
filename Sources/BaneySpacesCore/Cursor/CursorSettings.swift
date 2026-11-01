import Foundation

/// What the person (or an agent, through `baneyspaces agent cursor`) chose for the agent cursor. They are the
/// config keys of spec/config.md: `behavior.cursor.enabled`, `behavior.cursor.theme`, and the glide's
/// `animation.preset`, `animation.speed`, `animation.respect_reduce_motion` and `animation.cursor.glide.*`.
/// Until the config file's own implementation lands, the choice is saved here, and a `config.toml` that sets
/// any of those keys wins over the saved choice for that key (`CursorConfigFile`).
public struct CursorSettings: Codable, Equatable, Sendable {
    public var enabled = true
    public var theme = CursorTheme.defaultName
    public var preset = "baneyspaces"
    public var speed = 1.0
    public var respectReduceMotion = true
    public var response: Double?
    public var damping: Double?

    public static let userDefaultsKey = "cursor"
    public init() {}

    private enum CodingKeys: String, CodingKey { case enabled, theme, preset, speed, respectReduceMotion, response, damping }

    /// Each field on its own: one unreadable takes its default and leaves the rest.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? enabled
        theme = (try? c.decodeIfPresent(String.self, forKey: .theme)) ?? theme
        preset = (try? c.decodeIfPresent(String.self, forKey: .preset)) ?? preset
        speed = (try? c.decodeIfPresent(Double.self, forKey: .speed)) ?? speed
        respectReduceMotion = (try? c.decodeIfPresent(Bool.self, forKey: .respectReduceMotion)) ?? respectReduceMotion
        response = try? c.decodeIfPresent(Double.self, forKey: .response)
        damping = try? c.decodeIfPresent(Double.self, forKey: .damping)
    }

    public static func load(from defaults: UserDefaults = .standard) -> CursorSettings {
        guard let data = defaults.data(forKey: userDefaultsKey), let s = try? JSONDecoder().decode(CursorSettings.self, from: data) else { return CursorSettings() }
        return s
    }

    public func save(to defaults: UserDefaults = .standard) {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        if let data = try? e.encode(self) { defaults.set(data, forKey: Self.userDefaultsKey) }
    }

    /// The theme to draw; an unknown name (a deleted custom theme) falls back to the default.
    public var resolvedTheme: CursorTheme { CursorTheme.named(theme) ?? .standard }

    /// The glide's spring: the preset (or the keys that override it), with `speed` making it quicker or slower.
    public var spring: GlideSpring {
        if speed <= 0 { return .instant }
        let base = GlideSpring.preset(preset) ?? .baneyspaces
        if base.isInstant { return .instant }
        let s = GlideSpring(response: (response ?? base.response) / speed, damping: damping ?? base.damping)
        return s.clamped
    }

    /// Whether a glide is skipped for the person's Reduce Motion setting.
    public func skipsGlide(reduceMotion: Bool) -> Bool { spring.isInstant || (respectReduceMotion && reduceMotion) }

    /// Keys a config file set, which win over what is saved.
    public func applying(_ file: CursorConfigFile) -> CursorSettings {
        var s = self
        if let v = file.enabled { s.enabled = v }
        if let v = file.theme { s.theme = v }
        if let v = file.preset { s.preset = v }
        if let v = file.speed { s.speed = v }
        if let v = file.respectReduceMotion { s.respectReduceMotion = v }
        if let v = file.response { s.response = v }
        if let v = file.damping { s.damping = v }
        return s
    }
}

/// The cursor's keys read from a `config.toml` (spec/config.md). Only the subset of TOML the cursor needs:
/// `[table.headers]`, `key = value` and dotted keys, strings, numbers and booleans, `#` comments. Anything else is
/// ignored, and a value of the wrong type is ignored too, so a bad line never switches the cursor off.
public struct CursorConfigFile: Equatable, Sendable {
    public var enabled: Bool?
    public var theme: String?
    public var preset: String?
    public var speed: Double?
    public var respectReduceMotion: Bool?
    public var response: Double?
    public var damping: Double?
    public init() {}

    public var isEmpty: Bool { self == CursorConfigFile() }

    /// `$XDG_CONFIG_HOME/baneyspaces/config.toml`, default `~/.config/baneyspaces/config.toml`.
    public static func path(environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()) -> String {
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.config"
        return base + "/baneyspaces/config.toml"
    }

    public static func read(at path: String = path()) -> CursorConfigFile {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return CursorConfigFile() }
        return parse(text)
    }

    public static func parse(_ text: String) -> CursorConfigFile {
        var out = CursorConfigFile()
        var table = ""
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = stripComment(String(raw)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[[") { table = ""; continue }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { continue }
                table = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            let path = table.isEmpty ? key : table + "." + key
            switch path {
            case "behavior.cursor.enabled": out.enabled = bool(value)
            case "behavior.cursor.theme": out.theme = string(value)
            case "animation.preset": out.preset = string(value)
            case "animation.speed": out.speed = Double(value)
            case "animation.respect_reduce_motion": out.respectReduceMotion = bool(value)
            case "animation.cursor.glide.response": out.response = Double(value)
            case "animation.cursor.glide.damping": out.damping = Double(value)
            default: break
            }
        }
        return out
    }

    private static func bool(_ v: String) -> Bool? { v == "true" ? true : v == "false" ? false : nil }

    private static func string(_ v: String) -> String? {
        guard v.count >= 2, let q = v.first, q == "\"" || q == "'", v.last == q else { return nil }
        return String(v.dropFirst().dropLast())
    }

    private static func stripComment(_ s: String) -> String {
        var quote: Character?
        for (i, ch) in zip(s.indices, s) {
            if let q = quote { if ch == q { quote = nil } }
            else if ch == "\"" || ch == "'" { quote = ch }
            else if ch == "#" { return String(s[..<i]) }
        }
        return s
    }
}
