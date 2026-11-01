import Foundation

/// Whether the switch HUD (the 3×3 grid that flashes after a workspace switch) is drawn.
///
/// It is off unless you turn it on: it popped up on its own after every number-key switch and
/// every app focus that crossed workspaces, which read as the workspaces window opening by
/// itself (11-01). `defaults write com.baney.baneyspaces showSwitchHUD -bool true` brings it back.
/// ⌘Tab's own panel is not this HUD and is unaffected.
public enum SwitchHUDPolicy: Sendable {
    /// The UserDefaults key an explicit opt-in is stored under.
    public static let defaultsKey = "showSwitchHUD"
    public static let enabledByDefault = false

    /// `stored` is the key's value, nil when it was never set.
    public static func enabled(stored: Bool?) -> Bool { stored ?? enabledByDefault }

    /// A switch shows the HUD only when it asked to (`announce`), moves the focus, and the HUD is on.
    public static func shows(announce: Bool, takeFocus: Bool, stored: Bool?) -> Bool {
        announce && takeFocus && enabled(stored: stored)
    }
}
