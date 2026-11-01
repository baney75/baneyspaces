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

/// Only viewers and browsers take files. A terminal treats an argument as the command to run, so a
/// file there would be code execution: terminals take none (`agent run` is for commands).
pub fn takes_files(app: &str) -> bool {
    let name = basename(app);
    ["mpv", "imv", "swayimg"].contains(&name) || CHROMIUM.contains(&name) || FIREFOX.contains(&name)
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

/// Where a system binary may live. An allowlisted name must resolve (realpath) to the same file as
/// one of these, so a wrapper script or a symlink earlier on PATH, or in a project, never passes for it.
pub const SYSTEM_BIN_DIRS: &[&str] = &["/usr/bin", "/bin", "/usr/local/bin"];

#[derive(Debug, PartialEq, Eq)]
pub enum Resolve {
    /// The system binary the allowlist entry names.
    Ok(PathBuf),
    /// Nothing by that name on PATH.
    NotFound,
    /// Something by that name is first on PATH, but it is not the system binary.
    NotSystem(PathBuf),
}

/// Resolves an app named without a slash through `path_var` and requires its realpath to equal the
/// system binary of the same name. The name alone is never enough.
pub fn resolve_system(name: &str, path_var: &str) -> Resolve {
    use std::os::unix::fs::PermissionsExt;
    let exec = |p: &Path| p.is_file() && p.metadata().map(|m| m.permissions().mode() & 0o111 != 0).unwrap_or(false);
    let Some(found) = path_var.split(':').filter(|d| d.starts_with('/')).map(|d| Path::new(d).join(name)).find(|p| exec(p)) else {
        return Resolve::NotFound;
    };
    let real = found.canonicalize().unwrap_or(found);
    let system: Vec<PathBuf> = SYSTEM_BIN_DIRS.iter().filter_map(|d| Path::new(d).join(name).canonicalize().ok()).collect();
    if system.contains(&real) { Resolve::Ok(real) } else { Resolve::NotSystem(real) }
}

/// An agent may pass only files, and only files inside the handoff folder (realpath, so a symlink
/// or `..` cannot step out). No flags, no URLs, nothing else.
pub fn check_files(args: &[String], handoff: &Path) -> Result<Vec<String>, String> {
    let root = handoff.canonicalize().map_err(|e| format!("the handoff folder is missing: {e}"))?;
    let mut out = vec![];
    for a in args {
        if a.starts_with('-') {
            return Err(format!("{a:?}: flags are not accepted; BaneySpaces adds the only ones an app needs"));
        }
        let real = Path::new(a).canonicalize().map_err(|_| format!("{a:?} is not an existing file; give a file inside the handoff folder ({})", root.display()))?;
        if !real.starts_with(&root) {
            return Err(format!("{a:?} is outside the handoff folder ({})", root.display()));
        }
        out.push(real.to_string_lossy().into_owned());
    }
    Ok(out)
}

/// Deletes profile directories older than `max_age` seconds that no live agent process owns.
/// `live` holds the 8-character token prefixes that still have processes. Returns how many went.
pub fn prune_profiles(state: &Path, now: std::time::SystemTime, max_age: u64, live: &std::collections::HashSet<String>) -> usize {
    let Ok(dir) = std::fs::read_dir(state.join("agent-profiles")) else { return 0 };
    let mut n = 0;
    for e in dir.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        let old = e.metadata().and_then(|m| m.modified()).ok().and_then(|t| now.duration_since(t).ok()).is_some_and(|d| d.as_secs() > max_age);
        if old && !live.contains(&name) && std::fs::remove_dir_all(e.path()).is_ok() {
            n += 1;
        }
    }
    n
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
    fn a_wrapper_earlier_on_path_is_not_the_system_binary() {
        use std::os::unix::fs::PermissionsExt;
        let d = std::env::temp_dir().join(format!("bs-apps-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        let fake = d.join("foot");
        std::fs::write(&fake, "#!/bin/sh\nexec nautilus\n").unwrap();
        std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
        // A real system `sh` under another name is not `sh` either.
        let link = d.join("sh");
        let _ = std::os::unix::fs::symlink("/bin/sh", &link);
        let path = format!("{}:/usr/bin:/bin", d.display());
        // The fake foot comes first on PATH: refused, whatever its name.
        assert!(matches!(resolve_system("foot", &path), Resolve::NotSystem(_)));
        // A symlink to the system binary has the same realpath: that is the system binary.
        assert!(matches!(resolve_system("sh", &path), Resolve::Ok(_)));
        assert_eq!(resolve_system("definitely-not-installed-zz", &path), Resolve::NotFound);
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn only_files_inside_the_handoff_folder_pass() {
        let d = std::env::temp_dir().join(format!("bs-handoff-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(d.join("sub")).unwrap();
        std::fs::write(d.join("a.txt"), "x").unwrap();
        let ok = check_files(&[d.join("a.txt").display().to_string()], &d).unwrap();
        assert!(ok[0].ends_with("a.txt"));
        for bad in ["-e", "--user-data-dir=/home/x", "/etc/passwd", "https://example.com", "nofile.txt"] {
            assert!(check_files(&[bad.to_string()], &d).is_err(), "{bad}");
        }
        // `..` and a symlink out of the folder do not get through.
        let _ = std::os::unix::fs::symlink("/etc/passwd", d.join("sub/link"));
        assert!(check_files(&[d.join("sub/link").display().to_string()], &d).is_err());
        assert!(check_files(&[d.join("sub/../../passwd").display().to_string()], &d).is_err());
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn old_profiles_are_pruned_unless_a_live_token_owns_them() {
        let st = std::env::temp_dir().join(format!("bs-prof-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&st);
        let prof = st.join("agent-profiles");
        for n in ["aaaaaaaa", "bbbbbbbb", "cccccccc"] {
            std::fs::create_dir_all(prof.join(n)).unwrap();
        }
        let live: std::collections::HashSet<String> = ["bbbbbbbb".to_string()].into();
        let later = std::time::SystemTime::now() + std::time::Duration::from_secs(8 * 86_400);
        assert_eq!(prune_profiles(&st, std::time::SystemTime::now(), 7 * 86_400, &live), 0, "nothing is a week old yet");
        assert_eq!(prune_profiles(&st, later, 7 * 86_400, &live), 2);
        assert!(prof.join("bbbbbbbb").exists() && !prof.join("aaaaaaaa").exists());
        let _ = std::fs::remove_dir_all(&st);
    }

    #[test]
    fn terminals_and_dialogs_take_no_files() {
        for t in ["foot", "kitty", "alacritty", "xterm", "ghostty", "st", "urxvt", "weston-terminal", "zenity", "yad"] {
            assert!(!takes_files(t), "{t}");
        }
        for v in ["mpv", "imv", "swayimg", "chromium", "firefox"] {
            assert!(takes_files(v), "{v}");
        }
    }

    #[test]
    fn the_list_and_the_lookup_agree() {
        for name in allowed() {
            assert!(known(name, Path::new("/tmp/p")).is_some(), "{name}");
        }
    }
}
