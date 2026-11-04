import Foundation

/// How much of this Mac agents may use, picked by Donovan in Settings > Agents and kept until he changes it.
/// Every mode keeps the background-only rules: no app activation, no raised window, no global keys or clicks,
/// nothing while he is using an app (30 s), and never an Open or Save panel.
public enum AgentAccessMode: String, CaseIterable, Codable, Sendable {
    /// Agents may list, read and capture the windows Default allows, and change nothing.
    case readOnly = "read_only"
    /// The agent workspace, apps BaneySpaces starts for agents from its short list, and windows he lends.
    case standard = "default"
    /// Every window BaneySpaces places, on every workspace, and any app.
    case full

    public static let defaultsKey = "agentAccessMode"

    /// A saved value that isn't one of the modes reads as Default, never as more access.
    public init(saved: String?) { self = saved.flatMap(Self.init(rawValue:)) ?? .standard }

    var rank: Int {
        switch self {
        case .readOnly: return 0
        case .standard: return 1
        case .full: return 2
        }
    }

    /// Whether moving from `old` to this mode gives agents more than they had: only Donovan's real click
    /// on a consent sheet does that. Narrowing never asks.
    public func widens(from old: AgentAccessMode) -> Bool { rank > old.rank }

    /// What a caller on another machine gets: never more than Default. Full Access is for agents on this Mac;
    /// a remote caller only gives the agent workspace work (SECURITY.md).
    public var forRemote: AgentAccessMode { self == .full ? .standard : self }

    public var title: String {
        switch self {
        case .readOnly: return "Read Only"
        case .standard: return "Default"
        case .full: return "Full Access"
        }
    }

    public var detail: String {
        switch self {
        case .readOnly:
            return "Agents can list, read and capture the windows they could use in Default, and can't click, type, open apps, run commands, move windows or turn the agent workspace on."
        case .standard:
            return "Agents work on the agent workspace, in apps BaneySpaces starts for them (TextEdit, Preview, Calculator) and in apps you lend."
        case .full:
            return "Agents can read and act on every window on every workspace and start any app. They still work from behind: they never bring an app forward, move your pointer, type into the app in front, touch an app you used in the last 30 seconds, or use an Open or Save panel."
        }
    }
}

/// What Read Only refuses: every verb that changes something. `shot` only reads.
public enum AgentAccessGate {
    public static let changes: Set<String> = ["click", "type", "set-value", "press", "click-at", "drag", "scroll", "select", "toggle", "open"]
    /// The session engine's own agent ops that start or move something.
    public static let sessionChanges: Set<String> = ["open", "run", "move", "on"]

    public static func refusal(verb: String, mode: AgentAccessMode) -> HandsError? {
        guard mode == .readOnly, changes.contains(verb) else { return nil }
        return readOnly(verb)
    }

    /// The check right before an action is delivered (and before each retry): the mode may have narrowed to Read Only
    /// since the request was let in.
    public static func actingRefusal(mode: AgentAccessMode) -> HandsError? {
        mode == .readOnly ? readOnly("this action") : nil
    }

    public static func sessionRefusal(op: String, mode: AgentAccessMode) -> HandsError? {
        guard mode == .readOnly, sessionChanges.contains(op) else { return nil }
        return readOnly("agent \(op)")
    }

    static func readOnly(_ what: String) -> HandsError {
        HandsError(.permissionDenied, "agents have read-only access, so \(what) is refused",
                   suggestion: "You can still list, snapshot, find, get and shot. Donovan sets agent access in BaneySpaces Settings > Agents.",
                   retry: .never)
    }
}
