import CoreGraphics
import Foundation

/// When an agent's cursor is drawn. It shows on the agent workspace while you are looking at it, and over a lent
/// app while the agent uses it. Anywhere else it stays hidden, and the action still runs: hiding is only about
/// drawing. (docs/agent-computer-use.md, "The agent cursor".)
public enum CursorVisibility {
    public enum Hidden: String, Equatable, Sendable {
        /// Turned off in Settings, by `agent cursor off`, or by `behavior.cursor.enabled`.
        case disabled
        /// The window is on a workspace you are not looking at (parked out of view).
        case notWatching
        /// The target's frame couldn't be read.
        case noFrame
        /// The frame is not on any display.
        case offscreen
    }

    public enum Decision: Equatable, Sendable {
        case show
        case hidden(Hidden)
        public var shown: Bool { self == .show }
    }

    /// The part that needs no frame: whether to measure the target at all. Cheap, so the hands ask it before
    /// spending an engine call on the target's bounds.
    public static func wantsFrame(enabled: Bool, scope: String, windowWorkspace: Int?, current: Int, agent: Int?) -> Bool {
        if case .show = watching(enabled: enabled, scope: scope, windowWorkspace: windowWorkspace, current: current, agent: agent) { return true }
        return false
    }

    public static func decide(enabled: Bool, scope: String, windowWorkspace: Int?, current: Int, agent: Int?,
                              frame: CGRect?, displays: [CGRect]) -> Decision {
        let w = watching(enabled: enabled, scope: scope, windowWorkspace: windowWorkspace, current: current, agent: agent)
        guard case .show = w else { return w }
        guard let frame, !frame.isNull, !frame.isInfinite else { return .hidden(.noFrame) }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return displays.contains { $0.contains(center) } ? .show : .hidden(.offscreen)
    }

    private static func watching(enabled: Bool, scope: String, windowWorkspace: Int?, current: Int, agent: Int?) -> Decision {
        guard enabled else { return .hidden(.disabled) }
        switch scope {
        case "agent_workspace":
            // Parked windows are out of view; the cursor is drawn only while you are on the agent workspace.
            guard let agent, current == agent, windowWorkspace == agent else { return .hidden(.notWatching) }
            return .show
        case "lent":
            // A lent app is on your own workspace: it shows when you are on that workspace.
            guard let windowWorkspace, windowWorkspace == current else { return .hidden(.notWatching) }
            return .show
        default:
            return .hidden(.notWatching)
        }
    }
}
