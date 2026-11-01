import Foundation

/// Where the sandbox's display window goes. The rule: the agent workspace, never yours. Without an
/// agent workspace there is nowhere safe to put the window, so `view` refuses instead of showing it
/// on whatever workspace you're on.
public enum SandboxWindows {
    public struct Window: Equatable, Sendable {
        public var id: UInt32
        public var pid: Int32
        public var title: String
        /// The workspace BaneySpaces has it on, nil if it hasn't placed it yet.
        public var workspace: Int?
        public init(id: UInt32, pid: Int32, title: String = "", workspace: Int? = nil) {
            self.id = id; self.pid = pid; self.title = title; self.workspace = workspace
        }
    }

    public enum Decision: Equatable, Sendable {
        /// The next window `pid` opens goes to `workspace`. Asked before the process starts showing one.
        case claim(workspace: Int)
        /// A window already open on the wrong workspace goes to `workspace`.
        case move(window: UInt32, workspace: Int)
        case refuse(String)
    }

    public static let noAgentWorkspace = "the agent workspace is off, and the sandbox window only ever opens there: baneyspaces agent on"

    /// Before the display process starts.
    public static func beforeLaunch(agentWorkspace: Int?) -> Decision {
        guard let n = agentWorkspace else { return .refuse(noAgentWorkspace) }
        return .claim(workspace: n)
    }

    /// After it has windows: every window of the VM's process that isn't on the agent workspace
    /// goes there. Other processes' windows are never touched.
    public static func afterLaunch(windows: [Window], vmPid: Int32, agentWorkspace: Int?) -> [Decision] {
        guard let n = agentWorkspace else { return [.refuse(noAgentWorkspace)] }
        return windows.filter { $0.pid == vmPid && $0.workspace != n }.map { .move(window: $0.id, workspace: n) }
    }
}

/// What the sandbox needs from the app to place a window. The app delegate fills it in.
public protocol SandboxWindowHost: AnyObject {
    func agentWorkspace() -> Int?
    /// The next window of `pid` goes to `workspace` (BaneySpaces' own claim; it never follows it). False if
    /// the claim could not be registered in time: the caller must not let the process show a window.
    func claim(pid: Int32, workspace: Int) -> Bool
    func windows(of pid: Int32) -> [SandboxWindows.Window]
    func move(window: UInt32, to workspace: Int)
}
