//! Which apps an agent may start, and how.
//!
//! The line is drawn by process: an agent drives only a process BaneySpaces started for it as a
//! new instance. An app that forwards to a copy you already run (a GApplication, a browser, a file
//! manager) would open its window in YOUR process, so by default it is refused before launch
//! (`needs_sandbox`), the way the Mac refuses apps that cannot run a second instance. Apps known to
//! start a separate process, or to do so with a flag, are on the list below.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

/// How a known app is started as its own process.
pub enum Launch {
    /// Always a separate process.
    Separate,
    /// Separate with these arguments added (a private profile or a flag).
    Flags(Vec<String>),
}

fn basename(app: &str) -> &str {
    Path::new(app)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or(app)
}

/// The allowlist. `profile` is a fresh directory under BaneySpaces' own agent folder, never yours.
pub fn known(app: &str, profile: &Path) -> Option<Launch> {
    let name = basename(app);
    let p = profile.display().to_string();
    Some(match name {
        // Terminals and viewers that start a process per window.
        "foot" | "alacritty" | "kitty" | "xterm" | "st" | "urxvt" | "zenity" | "yad" | "mpv"
        | "imv" | "swayimg" | "weston-terminal" => Launch::Separate,
        // GApplication single-instance, with the flag that turns it off.
        "ghostty" => Launch::Flags(vec!["--gtk-single-instance=false".into()]),
        // Chromium family: its own profile is its own process, and never touches yours.
        "chromium"
        | "google-chrome"
        | "google-chrome-stable"
        | "brave"
        | "microsoft-edge"
        | "helium"
        | "helium-browser" => Launch::Flags(vec![
            format!("--user-data-dir={p}"),
            "--no-first-run".into(),
            "--no-default-browser-check".into(),
        ]),
        "firefox" | "librewolf" => Launch::Flags(vec!["--no-remote".into(), "--profile".into(), p]),
        _ => return None,
    })
}

fn is_interpreter(name: &str) -> bool {
    [
        "python", "node", "ruby", "perl", "java", "bash", "sh", "dash", "zsh", "lua", "deno", "bun",
    ]
    .iter()
    .any(|i| {
        name == *i
            || name
                .strip_prefix(i)
                .is_some_and(|rest| rest.chars().all(|c| c.is_ascii_digit() || c == '.'))
    })
}

/// What identifies "the same app" for single-instance purposes: the executable, and for an
/// interpreter also the script it runs (so one python script is not every python program).
pub fn instance_key(exe: &Path, args: &[String]) -> String {
    let exe = exe.canonicalize().unwrap_or_else(|_| exe.to_path_buf());
    let name = exe.file_name().and_then(|n| n.to_str()).unwrap_or("");
    if is_interpreter(name) {
        if let Some(script) = args.iter().find(|a| !a.starts_with('-')) {
            return format!("{}\u{0}{}", exe.display(), script);
        }
    }
    exe.display().to_string()
}

/// A process of yours (not one an agent was given) that is the same app. Checks `/proc`, so it
/// sees only your own processes.
pub fn user_instance(key: &str, agent_tokens: &HashSet<String>) -> Option<u32> {
    let me = std::process::id();
    let dir = std::fs::read_dir("/proc").ok()?;
    for pid in dir
        .flatten()
        .filter_map(|e| e.file_name().to_str()?.parse::<u32>().ok())
    {
        if pid == me {
            continue;
        }
        let Ok(exe) = std::fs::read_link(format!("/proc/{pid}/exe")) else {
            continue;
        };
        let Ok(cmd) = std::fs::read(format!("/proc/{pid}/cmdline")) else {
            continue;
        };
        let args: Vec<String> = cmd
            .split(|b| *b == 0)
            .filter(|a| !a.is_empty())
            .skip(1)
            .map(|a| String::from_utf8_lossy(a).into_owned())
            .collect();
        if instance_key(&exe, &args) != key {
            continue;
        }
        if crate::proc::token_of(pid).is_some_and(|t| agent_tokens.contains(&t)) {
            continue; // an agent's own copy
        }
        return Some(pid);
    }
    None
}

/// A new, empty profile directory for one launch.
pub fn profile_dir(state: &Path, token: &str) -> PathBuf {
    state
        .join("agent-profiles")
        .join(&token[..8.min(token.len())])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn terminals_are_separate_and_unknown_apps_are_not_listed() {
        let p = Path::new("/tmp/p");
        assert!(matches!(known("/usr/bin/foot", p), Some(Launch::Separate)));
        assert!(known("nautilus", p).is_none());
        assert!(known("gtk4-demo", p).is_none());
    }

    #[test]
    fn browsers_get_a_private_profile_and_ghostty_the_flag() {
        let p = Path::new("/tmp/prof");
        let Some(Launch::Flags(f)) = known("chromium", p) else {
            panic!()
        };
        assert!(f.contains(&"--user-data-dir=/tmp/prof".to_string()));
        let Some(Launch::Flags(f)) = known("firefox", p) else {
            panic!()
        };
        assert_eq!(&f[..2], ["--no-remote", "--profile"]);
        let Some(Launch::Flags(f)) = known("ghostty", p) else {
            panic!()
        };
        assert_eq!(f, ["--gtk-single-instance=false"]);
    }

    #[test]
    fn an_interpreter_is_told_apart_by_its_script() {
        let py = Path::new("/usr/bin/true"); // any real file; the name is what counts below
        let _ = py;
        assert!(
            is_interpreter("python3.14")
                && is_interpreter("python3")
                && is_interpreter("bash")
                && is_interpreter("node")
        );
        assert!(!is_interpreter("foot") && !is_interpreter("pythonic-app"));
    }

    #[test]
    fn instance_keys_compare_the_script_not_just_the_interpreter() {
        // /bin/sh exists everywhere and is an interpreter name.
        let sh = Path::new("/bin/sh");
        let a = instance_key(sh, &["-c".into(), "x.sh".into()]);
        let b = instance_key(sh, &["y.sh".into()]);
        let c = instance_key(sh, &["x.sh".into(), "--flag".into()]);
        assert_ne!(a, b);
        assert_eq!(a, c);
    }

    #[test]
    fn our_own_process_is_a_user_instance_of_itself() {
        let exe = std::env::current_exe().unwrap();
        // The test binary is a cargo test harness: found by exe alone, unless it is excluded as "me".
        let key = instance_key(&exe, &[]);
        let found = user_instance(&key, &HashSet::new());
        assert!(found.is_none() || found != Some(std::process::id()));
    }
}
