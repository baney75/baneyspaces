//! R-S2: the display you are on is the one you last clicked into, switched to or moved to. A click on a window
//! already moves it (the window's activation, R-F1), but the desktop spans every display and is not one of your
//! windows, so a click on the other display's bare desktop or taskbar changed nothing: with display B on an empty
//! workspace, Win+5 still switched display A. The daemon's mouse hook reports each press; this decides what it means.

/// The button presses that say where you are: left, right and middle, down, made by a hand (not injected).
pub fn is_a_press(msg: u32, injected: bool) -> bool {
    const WM_LBUTTONDOWN: u32 = 0x0201;
    const WM_RBUTTONDOWN: u32 = 0x0204;
    const WM_MBUTTONDOWN: u32 = 0x0207;
    !injected && matches!(msg, WM_LBUTTONDOWN | WM_RBUTTONDOWN | WM_MBUTTONDOWN)
}

/// The display to be on after a press on display `at`, when that is not the one you are on already. A display the
/// model does not know (one just plugged in, before the next poll) moves nothing.
pub fn after_press<'a>(focused: Option<&str>, at: Option<&'a str>, known: &[&str]) -> Option<&'a str> {
    let at = at?;
    (known.contains(&at) && focused != Some(at)).then_some(at)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_press_on_the_other_display_puts_you_there() {
        assert_eq!(after_press(Some("A"), Some("B"), &["A", "B"]), Some("B"));
        assert_eq!(after_press(None, Some("A"), &["A", "B"]), Some("A"));
    }

    #[test]
    fn a_press_where_you_are_or_on_an_unknown_display_changes_nothing() {
        assert_eq!(after_press(Some("A"), Some("A"), &["A", "B"]), None);
        assert_eq!(after_press(Some("A"), Some("C"), &["A", "B"]), None);
        assert_eq!(after_press(Some("A"), None, &["A", "B"]), None);
    }

    #[test]
    fn only_a_hand_pressing_a_button_counts() {
        assert!(is_a_press(0x0201, false) && is_a_press(0x0204, false) && is_a_press(0x0207, false));
        assert!(!is_a_press(0x0200, false), "a move is not a press");
        assert!(!is_a_press(0x0202, false), "nor is a release");
        assert!(!is_a_press(0x0201, true), "nor an injected press");
    }

    /// The hook thread watches the mouse, and the worker moves the display you are on for a press.
    #[test]
    fn the_daemon_hears_presses_and_moves_the_display_you_are_on() {
        let hook = include_str!("hook.rs");
        assert!(hook.contains("SetWindowsHookExW(WH_MOUSE_LL"), "a low-level mouse hook");
        assert!(hook.contains("focus::is_a_press("), "it reports presses only");
        // Windows checks the source out with CRLF line ends.
        let daemon = &include_str!("daemon.rs").replace("\r\n", "\n");
        assert!(daemon.contains("Ok(Msg::Press { x, y }) =>"), "the worker hears them");
        let on = &daemon[daemon.find("fn on_press(").expect("on_press")..];
        let on = &on[..on.find("\n    }\n").unwrap()];
        assert!(on.contains("focus::after_press(") && on.contains("Event::ObserveFocusMonitor"), "{on}");
    }
}
