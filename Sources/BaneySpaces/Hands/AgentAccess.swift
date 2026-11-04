import AppKit
import BaneySpacesCore

/// The agent access mode Donovan picked (Settings > Agents), read by the hands on any thread. Only `set`, called
/// from Settings or the menu after `AccessConsent` when it widens access, changes it; nothing on the socket and no
/// line in config.toml does. Like every saved setting, another process of his could rewrite the defaults domain;
/// that is outside the host threat model (docs/agent-computer-use.md), so a mode other than Default is logged at launch.
final class AgentAccess {
    static let shared = AgentAccess()
    private let lock = NSLock()
    private var mode = AgentAccessMode(saved: UserDefaults.standard.string(forKey: AgentAccessMode.defaultsKey))
    /// Processes `agent open` reached only because of Full Access: an app off the list it started, or one of Donovan's
    /// running apps it claimed a window of. Their windows are refused again once the mode is no longer Full Access,
    /// even on the agent workspace. Kept by start time, so a reused pid is never taken for one.
    private var grants = AgentOwnedSet()
    /// Called on the main thread after the mode changes: the menu bar, Settings, state.json.
    var onChange: ((AgentAccessMode) -> Void)?

    private init() {
        if mode != .standard { Trace.log("agent access at launch: \(mode.rawValue) (saved in Settings)") }
    }

    var current: AgentAccessMode {
        lock.lock(); defer { lock.unlock() }
        return mode
    }

    func grant(_ pid: Int32) {
        guard let t = AgentOwned.startTime(pid) else { return }
        lock.lock(); grants.add(pid, startedAt: t); lock.unlock()
    }

    /// Whether `pid` is one Full Access let in.
    func grantedUnderFull(_ pid: Int32) -> Bool {
        lock.lock(); let g = grants; lock.unlock()
        return g.contains(pid, startedAt: AgentOwned.startTime(pid))
    }

    /// Main thread only. The caller has already asked Donovan when the change widens access.
    func set(_ new: AgentAccessMode) {
        lock.lock(); let old = mode; mode = new; lock.unlock()
        guard old != new else { return }
        UserDefaults.standard.set(new.rawValue, forKey: AgentAccessMode.defaultsKey)
        Trace.log("agent access: \(old.rawValue) -> \(new.rawValue)")
        onChange?(new)
    }

    /// Asks first when `new` widens access; true when the mode is now `new`. Main thread only.
    @discardableResult
    func request(_ new: AgentAccessMode) -> Bool {
        let old = current
        guard old != new else { return true }
        if new.widens(from: old), !AccessConsent.ask(new) { return false }
        set(new)
        return true
    }
}
