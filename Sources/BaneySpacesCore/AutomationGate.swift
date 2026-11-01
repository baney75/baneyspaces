/// When Settings' Automation tab can act. Its list and Bring Every Window Back reach the workspace
/// engine, which exists only once BaneySpaces has started: Accessibility allowed and AeroSpace
/// quit. Before that they do nothing, so Settings disables them and says why, in the order a
/// person would fix it.
public enum AutomationGate {
    /// Nil when the controls can be used; otherwise one line saying what they wait for.
    public static func reason(trusted: Bool, aeroSpaceRunning: Bool, started: Bool) -> String? {
        // Revoked after BaneySpaces started: the controls would call Accessibility and fail quietly.
        if started && !trusted { return "Accessibility access was turned off, so this can't work. Allow BaneySpaces again (General tab)." }
        if started { return nil }
        if !trusted { return "Available once BaneySpaces is running: it needs Accessibility access first (General tab)." }
        if aeroSpaceRunning { return "Available once BaneySpaces is running: it is waiting for AeroSpace to quit (General tab)." }
        return "Available once BaneySpaces is running; it is starting now."
    }
}
