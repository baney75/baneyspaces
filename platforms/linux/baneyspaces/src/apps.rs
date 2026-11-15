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

/// Chromium-family apps, which get Polycarp's extension and its native host.
pub fn is_chromium(app: &str) -> bool {
    CHROMIUM.contains(&basename(app))
}

/// The Polycarp extension `polycarp update` installs, `<data home>/polycarp/browser/source/dist-chrome`
/// (realpath), when it holds a manifest. Only this one folder, which BaneySpaces derives itself, is ever
/// loaded: never a path a caller gives. A comma would split Chromium's list, so a path with one is refused.
pub fn polycarp_extension(data_home: &Path) -> Option<PathBuf> {
    let dir = data_home.join("polycarp/browser/source/dist-chrome").canonicalize().ok()?;
    let text = dir.to_str()?;
    (dir.join("manifest.json").is_file() && !text.contains(',')).then_some(dir)
}

/// What a Chromium-family launch adds so the agent's browser comes up with Polycarp: the installed
/// extension, unpacked. Its manifest has a fixed `key`, so its id (and the native host's allowed origin)
/// is the one your browser has. Nothing for any other app, or when Polycarp isn't installed.
pub fn polycarp_flags(app: &str, extension: Option<&Path>) -> Vec<String> {
    match extension {
        Some(dir) if is_chromium(app) => vec![format!("--load-extension={}", dir.display())],
        _ => vec![],
    }
}

/// The native host names `polycarp-browser setup` registers (`NATIVE_HOST_NAMES` in browser/): the
/// current one and the one an extension built before the rename asks for.
pub const POLYCARP_HOSTS: &[&str] = &["com.polycarp.browser", "ai.tabkyra.bridge"];

/// Each Chromium-family browser's user folder under the config home, as `polycarp-browser setup` knows them
/// (`browserDirs()` in browser/cli/src/install.ts).
fn chromium_config(app: &str) -> Option<&'static str> {
    Some(match basename(app) {
        "chromium" => "chromium",
        "google-chrome" | "google-chrome-stable" => "google-chrome",
        "brave" => "BraveSoftware/Brave-Browser",
        "microsoft-edge" => "microsoft-edge",
        "helium" | "helium-browser" => "net.imput.helium",
        _ => return None,
    })
}

/// A native host manifest `polycarp-browser setup` wrote: JSON with this name, `type` stdio and an
/// absolute `path`. Anything else is left behind.
fn host_manifest_ok(text: &str, name: &str) -> bool {
    let Ok(v) = serde_json::from_str::<serde_json::Value>(text) else { return false };
    v["name"] == name && v["type"] == "stdio" && v["path"].as_str().is_some_and(|p| p.starts_with('/')) && v["allowed_origins"].is_array()
}

/// With a private `--user-data-dir`, Chromium on Linux looks for your native hosts in
/// `<profile>/NativeMessagingHosts/`, not in your browser's folder. Copies each Polycarp host manifest
/// setup registered (the launched browser's own first, then Chromium's) into the agent's profile, whole
/// and renamed into place. Only those two names, and only a file that is a host manifest. Returns the
/// names copied.
pub fn copy_polycarp_hosts(config_home: &Path, app: &str, profile: &Path) -> Vec<&'static str> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let Some(own) = chromium_config(app) else { return vec![] };
    let dest = profile.join("NativeMessagingHosts");
    let mut copied = vec![];
    for name in POLYCARP_HOSTS {
        let file = format!("{name}.json");
        let Some(text) = [own, "chromium"].iter().find_map(|d| std::fs::read_to_string(config_home.join(d).join("NativeMessagingHosts").join(&file)).ok().filter(|t| host_manifest_ok(t, name))) else {
            continue;
        };
        if std::fs::create_dir_all(&dest).is_err() {
            return copied;
        }
        let tmp = dest.join(format!(".{file}.tmp"));
        let written = std::fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(&tmp).and_then(|mut f| f.write_all(text.as_bytes()));
        if written.is_ok() && std::fs::rename(&tmp, dest.join(&file)).is_ok() {
            copied.push(*name);
        } else {
            let _ = std::fs::remove_file(&tmp);
        }
    }
    copied
}

/// The variables Polycarp's native host and its clients take the socket folder from (`envVar("SOCKET_DIR")`
/// in browser/cli/src/paths.ts): the current name and the one a release from before the rename reads.
pub const POLYCARP_SOCKET_VARS: &[&str] = &["POLYCARP_SOCKET_DIR", "TABKYRA_SOCKET_DIR"];

/// The Polycarp bridge folder of one agent launch, `<run>/polycarp/<tag>`. An agent's browser makes its
/// socket here, never in your `/tmp/polycarp-bridge-<user>`, so your Polycarp never attaches to it and an
/// agent's client never reaches your signed-in browser. Under this override the host also skips the legacy
/// `tabkyra-bridge` folder.
pub fn polycarp_socket_dir(run: &Path, tag: &str) -> PathBuf {
    run.join("polycarp").join(tag)
}

/// Makes `polycarp_socket_dir` private (0700, the mode the native host insists on) and returns it.
pub fn make_polycarp_socket_dir(run: &Path, tag: &str) -> std::io::Result<PathBuf> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    let dir = polycarp_socket_dir(run, tag);
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&dir)?;
    for d in [run.join("polycarp"), dir.clone()] {
        std::fs::set_permissions(&d, std::fs::Permissions::from_mode(0o700))?;
    }
    Ok(dir)
}

/// Removes the bridge folders no live launch uses (a daemon killed outright left them).
pub fn sweep_polycarp_socket_dirs(run: &Path, live_tags: &std::collections::HashSet<String>) {
    let Ok(dir) = std::fs::read_dir(run.join("polycarp")) else { return };
    for e in dir.flatten() {
        if !live_tags.contains(&*e.file_name().to_string_lossy()) {
            let _ = std::fs::remove_dir_all(e.path());
        }
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

    fn temp(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("bs-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d.canonicalize().unwrap()
    }

    #[test]
    fn only_chromium_family_browsers_load_the_installed_extension() {
        let data = temp("ext");
        assert_eq!(polycarp_extension(&data), None, "nothing installed");
        let dir = data.join("polycarp/browser/source/dist-chrome");
        std::fs::create_dir_all(&dir).unwrap();
        assert_eq!(polycarp_extension(&data), None, "a folder with no manifest is not an extension");
        std::fs::write(dir.join("manifest.json"), "{}").unwrap();
        let ext = polycarp_extension(&data).unwrap();
        assert_eq!(ext, dir);
        for b in ["chromium", "/usr/bin/chromium", "google-chrome-stable", "brave", "helium"] {
            assert_eq!(polycarp_flags(b, Some(&ext)), [format!("--load-extension={}", dir.display())], "{b}");
        }
        for other in ["firefox", "librewolf", "foot", "ghostty", "mpv"] {
            assert!(polycarp_flags(other, Some(&ext)).is_empty(), "{other}");
        }
        assert!(polycarp_flags("chromium", None).is_empty());
        // The flag never carries a caller's path: `known` stays the isolation flags alone.
        let Some(Launch::Flags(f)) = known("chromium", Path::new("/tmp/prof")) else { panic!() };
        assert!(!f.iter().any(|a| a.starts_with("--load-extension")));
        let _ = std::fs::remove_dir_all(&data);
    }

    #[test]
    fn an_extension_reached_through_a_symlink_is_its_realpath_and_a_comma_is_refused() {
        let data = temp("ext-link");
        let link = data.join("polycarp/browser/source/dist-chrome");
        std::fs::create_dir_all(link.parent().unwrap()).unwrap();
        let comma = data.join("real,two");
        std::fs::create_dir_all(&comma).unwrap();
        std::fs::write(comma.join("manifest.json"), "{}").unwrap();
        std::os::unix::fs::symlink(&comma, &link).unwrap();
        assert_eq!(polycarp_extension(&data), None, "a comma would make Chromium load two folders");
        let plain = data.join("real");
        std::fs::create_dir_all(&plain).unwrap();
        std::fs::write(plain.join("manifest.json"), "{}").unwrap();
        let link2 = data.join("polycarp/browser/source/dist-chrome.new");
        std::os::unix::fs::symlink(&plain, &link2).unwrap();
        std::fs::rename(&link2, &link).unwrap();
        assert_eq!(polycarp_extension(&data), Some(plain));
        let _ = std::fs::remove_dir_all(&data);
    }

    fn host(name: &str, path: &str) -> String {
        format!("{{\n  \"name\": \"{name}\",\n  \"description\": \"Polycarp browser bridge\",\n  \"path\": \"{path}\",\n  \"type\": \"stdio\",\n  \"allowed_origins\": [\"chrome-extension://kenehmggpggpiolepbjojeenmeapgfoc/\"]\n}}\n")
    }

    #[test]
    fn the_polycarp_host_manifests_are_copied_into_the_agent_profile() {
        let root = temp("hosts");
        let (config, profile) = (root.join("config"), root.join("profile"));
        std::fs::create_dir_all(&profile).unwrap();
        assert!(copy_polycarp_hosts(&config, "chromium", &profile).is_empty(), "setup never ran");
        assert!(!profile.join("NativeMessagingHosts").exists(), "and nothing is made");
        let hosts = config.join("chromium/NativeMessagingHosts");
        std::fs::create_dir_all(&hosts).unwrap();
        let current = host("com.polycarp.browser", "/home/u/.config/polycarp/browser/polycarp-host");
        std::fs::write(hosts.join("com.polycarp.browser.json"), &current).unwrap();
        std::fs::write(hosts.join("ai.tabkyra.bridge.json"), host("ai.tabkyra.bridge", "/home/u/.config/polycarp/browser/polycarp-host")).unwrap();
        // Another extension's host in the same folder is never copied.
        std::fs::write(hosts.join("com.omarchy.ytdlp.json"), host("com.omarchy.ytdlp", "/usr/bin/x")).unwrap();
        assert_eq!(copy_polycarp_hosts(&config, "/usr/bin/chromium", &profile), ["com.polycarp.browser", "ai.tabkyra.bridge"]);
        let dest = profile.join("NativeMessagingHosts");
        assert_eq!(std::fs::read_to_string(dest.join("com.polycarp.browser.json")).unwrap(), current, "copied byte for byte");
        let mut names: Vec<String> = std::fs::read_dir(&dest).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
        names.sort();
        assert_eq!(names, ["ai.tabkyra.bridge.json", "com.polycarp.browser.json"], "only the two, and no temp file left");
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(dest.join("com.polycarp.browser.json")).unwrap().permissions().mode() & 0o777, 0o600);
        // Firefox and terminals get nothing.
        assert!(copy_polycarp_hosts(&config, "firefox", &root.join("ff")).is_empty());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_browser_uses_its_own_registration_first_and_a_bad_manifest_is_left_behind() {
        let root = temp("hosts-own");
        let (config, profile) = (root.join("config"), root.join("profile"));
        let own = config.join("BraveSoftware/Brave-Browser/NativeMessagingHosts");
        let chromium = config.join("chromium/NativeMessagingHosts");
        std::fs::create_dir_all(&own).unwrap();
        std::fs::create_dir_all(&chromium).unwrap();
        std::fs::write(own.join("com.polycarp.browser.json"), host("com.polycarp.browser", "/brave/host")).unwrap();
        std::fs::write(chromium.join("com.polycarp.browser.json"), host("com.polycarp.browser", "/chromium/host")).unwrap();
        // Brave's own legacy file is not a host manifest (wrong name inside), so Chromium's is used.
        std::fs::write(own.join("ai.tabkyra.bridge.json"), host("com.polycarp.browser", "/brave/host")).unwrap();
        std::fs::write(chromium.join("ai.tabkyra.bridge.json"), host("ai.tabkyra.bridge", "/chromium/host")).unwrap();
        assert_eq!(copy_polycarp_hosts(&config, "brave", &profile).len(), 2);
        let read = |n: &str| std::fs::read_to_string(profile.join("NativeMessagingHosts").join(n)).unwrap();
        assert!(read("com.polycarp.browser.json").contains("/brave/host"));
        assert!(read("ai.tabkyra.bridge.json").contains("/chromium/host"));
        for bad in ["not json", "{\"name\":\"com.polycarp.browser\",\"type\":\"stdio\",\"path\":\"relative\",\"allowed_origins\":[]}", "{\"name\":\"com.polycarp.browser\",\"type\":\"pipe\",\"path\":\"/x\",\"allowed_origins\":[]}"] {
            assert!(!host_manifest_ok(bad, "com.polycarp.browser"), "{bad}");
        }
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn the_list_and_the_lookup_agree() {
        for name in allowed() {
            assert!(known(name, Path::new("/tmp/p")).is_some(), "{name}");
        }
    }
}
