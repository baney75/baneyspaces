//! Which apps an agent may start, and how.
//!
//! Deny by default. The line is drawn by process: an agent drives only a process BaneySpaces
//! started for it as a new instance. An app that might forward to a running copy (a GApplication,
//! a browser, a file manager) is dangerous both ways: it can open the agent's request in YOUR
//! process, and an agent's copy can become the instance YOUR later launches forward to. So an app
//! may be started for an agent only if it is on the list below, each with a verified way to run as
//! its own process. Anything else is refused before launch with `needs_sandbox`, whether or not you
//! happen to be running a copy.

use std::path::{Path, PathBuf};

/// How a known app is started as its own process.
pub enum Launch {
    /// Always a separate process.
    Separate,
    /// Separate with these arguments added (a private profile or a flag).
    Flags(Vec<String>),
}

fn basename(app: &str) -> &str {
    Path::new(app).file_name().and_then(|n| n.to_str()).unwrap_or(app)
}

const SEPARATE: &[&str] = &["foot", "alacritty", "kitty", "xterm", "st", "urxvt", "zenity", "yad", "mpv", "imv", "swayimg", "weston-terminal"];
const GHOSTTY: &[&str] = &["ghostty"];
const CHROMIUM: &[&str] = &["chromium", "google-chrome", "google-chrome-stable", "brave", "microsoft-edge", "helium", "helium-browser"];
const FIREFOX: &[&str] = &["firefox", "librewolf"];

/// Every app name an agent may start.
pub fn allowed() -> Vec<&'static str> {
    [SEPARATE, GHOSTTY, CHROMIUM, FIREFOX].concat()
}

/// The allowlist. `profile` is a fresh directory under BaneySpaces' own agent folder, never yours.
pub fn known(app: &str, profile: &Path) -> Option<Launch> {
    let name = basename(app);
    let p = profile.display().to_string();
    if SEPARATE.contains(&name) {
        Some(Launch::Separate)
    } else if GHOSTTY.contains(&name) {
        // GApplication single-instance, with the flag that turns it off.
        Some(Launch::Flags(vec!["--gtk-single-instance=false".into()]))
    } else if CHROMIUM.contains(&name) {
        // Its own profile is its own process, and never touches yours.
        Some(Launch::Flags(vec![format!("--user-data-dir={p}"), "--no-first-run".into(), "--no-default-browser-check".into()]))
    } else if FIREFOX.contains(&name) {
        Some(Launch::Flags(vec!["--no-remote".into(), "--profile".into(), p]))
    } else {
        None
    }
}

/// A new, empty profile directory for one launch.
pub fn profile_dir(state: &Path, token: &str) -> PathBuf {
    state.join("agent-profiles").join(&token[..8.min(token.len())])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn terminals_are_separate_and_everything_else_is_not_listed() {
        let p = Path::new("/tmp/p");
        assert!(matches!(known("/usr/bin/foot", p), Some(Launch::Separate)));
        for unlisted in ["nautilus", "gtk4-demo", "evince", "gnome-text-editor", "python3", "sh", "/usr/bin/true", "baneyspaces"] {
            assert!(known(unlisted, p).is_none(), "{unlisted}");
        }
    }

    #[test]
    fn browsers_get_a_private_profile_and_ghostty_the_flag() {
        let p = Path::new("/tmp/prof");
        let Some(Launch::Flags(f)) = known("chromium", p) else { panic!() };
        assert!(f.contains(&"--user-data-dir=/tmp/prof".to_string()));
        let Some(Launch::Flags(f)) = known("firefox", p) else { panic!() };
        assert_eq!(&f[..2], ["--no-remote", "--profile"]);
        let Some(Launch::Flags(f)) = known("ghostty", p) else { panic!() };
        assert_eq!(f, ["--gtk-single-instance=false"]);
    }

    #[test]
    fn the_list_and_the_lookup_agree() {
        for name in allowed() {
            assert!(known(name, Path::new("/tmp/p")).is_some(), "{name}");
        }
    }
}
