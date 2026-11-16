//! Who caused a foreground change. Windows says only that the front window changed, so input in the last 300 ms
//! counts as yours (R-F1): a user activation may take you to another workspace, an app's may not (R-F2).
//!
//! A close breaks that guess. When the front window closes, Windows hands the front to the next window in z-order,
//! and that can be a hidden window of another workspace. The click on the close box is still under 300 ms old, so
//! the system's activation would pass for yours and switch you away from the workspace you emptied (R-E1: empty
//! means empty). An activation is the system's when the window that was active is gone, or when a close came after
//! your last input.

use baneyspaces_core::model::Cause;

/// `idle_ms`: time since the last keyboard or mouse input. `since_close_ms`: time since a tracked window last
/// closed, if one has. `active_gone`: the window the model holds active no longer exists or is no longer visible.
pub fn foreground_by(idle_ms: u32, since_close_ms: Option<u32>, active_gone: bool) -> Cause {
    let closed_after_input = since_close_ms.is_some_and(|s| s <= idle_ms);
    if active_gone || closed_after_input || idle_ms >= 300 {
        Cause::App
    } else {
        Cause::User
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn closing_the_last_window_does_not_follow_windows_to_another_workspace() {
        // You click the close box (40 ms ago), the window closes (20 ms ago), Windows activates a hidden window.
        assert_eq!(foreground_by(40, Some(20), false), Cause::App);
        // The foreground event came before the close was seen: the active window is already gone.
        assert_eq!(foreground_by(40, None, true), Cause::App);
        assert_eq!(foreground_by(40, Some(9_000), true), Cause::App);
    }

    #[test]
    fn a_click_after_a_close_is_still_yours() {
        // A taskbar click 30 ms ago, after a close five seconds earlier, may take you to that window's workspace.
        assert_eq!(foreground_by(30, Some(5_000), false), Cause::User);
        assert_eq!(foreground_by(30, None, false), Cause::User);
    }

    #[test]
    fn no_recent_input_is_the_apps() {
        assert_eq!(foreground_by(2_000, None, false), Cause::App);
        assert_eq!(foreground_by(300, Some(9_000), false), Cause::App);
    }

    #[test]
    fn the_daemon_asks_before_it_calls_an_activation_yours() {
        let src = include_str!("daemon.rs").replace("\r\n", "\n");
        let start = src.find("fn on_foreground(").expect("on_foreground");
        let body = &src[start..start + src[start..].find("\n    }\n").expect("end of on_foreground")];
        assert!(body.contains("cause::foreground_by("), "on_foreground must classify the activation with cause::foreground_by");
        assert!(!body.contains("idle_ms() < 300"), "the bare 300 ms guess calls a close's activation yours");
        let start = src.find("fn close_window(").expect("close_window");
        let body = &src[start..start + src[start..].find("\n    }\n").expect("end of close_window")];
        assert!(body.contains("self.closed_at = Some("), "close_window must note when the close happened");
    }
}
