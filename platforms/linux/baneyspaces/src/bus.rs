//! A private session bus, and a private accessibility bus, for each agent launch.
//!
//! GApplication and other D-Bus single-instance apps forward a second launch to the first over the
//! session bus. Giving every agent launch its own session bus means an agent's copy of an app never
//! meets yours, in either direction: it cannot hand its request to your instance, and your later
//! launch cannot forward into the agent's process.
//!
//! Accessibility needs the same care. GTK4 asks the *session* bus where the accessibility bus is
//! (`org.a11y.Bus.GetAddress`) and ignores `AT_SPI_BUS_ADDRESS`, so an app on a private session bus
//! would start a launcher that takes over the socket of YOUR accessibility bus. So each launch gets
//! its own accessibility stack too, under a private runtime directory: the session bus,
//! `at-spi-bus-launcher` (which owns `org.a11y.Bus` on it and starts the a11y bus) and
//! `at-spi2-registryd`. They share one process group, torn down together with the token. The hands
//! engine is pointed at that session bus when it works on that launch's windows; your assistive
//! tools never see the agent's apps.
//!
//! What does not carry over, by design: your notification daemon, tray, portal backends and any
//! other service on your session bus. xdg-desktop-portal starts a second, private instance when an
//! app asks for it; file choosers and screen-capture portals may not open. Clipboard and display are
//! Wayland, not D-Bus, and are untouched. GSettings reads (dconf) still work from the user database.
//!
//! This keeps accidents out. `agent run` is a shell with your uid: a process that looks for your
//! bus address in its environment or in /run/user can still find it. Same threat model as the Mac.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::mpsc::{channel, Sender};
use std::sync::{Mutex, OnceLock};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

const LAUNCHER: &str = "/usr/lib/at-spi-bus-launcher";
const REGISTRYD: &str = "/usr/lib/at-spi2-registryd";

#[derive(Clone, Debug)]
pub struct BusInfo {
    /// The private session bus address apps (and the engine, for these windows) use.
    pub addr: String,
    /// The process group of the whole stack (its leader is the session bus daemon).
    pub pid: u32,
    pub start: u64,
}

fn tag(token: &str) -> &str {
    &token[..8.min(token.len())]
}

pub fn socket_path(run: &Path, token: &str) -> PathBuf {
    run.join(format!("bus-{}", tag(token)))
}

/// The private runtime directory the accessibility stack lives in.
pub fn rt_dir(run: &Path, token: &str) -> PathBuf {
    run.join(format!("rt-{}", tag(token)))
}

/// Services nobody on the private bus may reach. Their D-Bus activation files would start a second
/// portal or notification daemon on the private bus, whose windows (a file chooser) carry no launch
/// token and would open on YOUR workspace. A message to them is refused (AccessDenied) before
/// anything is activated; GTK and Qt then fall back to their own dialogs.
const DENIED: &[&str] = &[
    "org.freedesktop.portal.Desktop",
    "org.freedesktop.portal.Documents",
    "org.freedesktop.portal.Flatpak",
    "org.freedesktop.impl.portal.PermissionStore",
    "org.freedesktop.impl.portal.desktop.gtk",
    "org.freedesktop.impl.portal.desktop.gnome",
    "org.freedesktop.impl.portal.desktop.kde",
    "org.freedesktop.impl.portal.desktop.hyprland",
    "org.freedesktop.impl.portal.desktop.wlr",
    "org.freedesktop.Notifications",
    "org.freedesktop.FileManager1",
    "org.kde.StatusNotifierWatcher",
];

/// The private bus's configuration: the system session defaults, then the denials above.
pub fn session_conf() -> String {
    let mut c = String::from("<!DOCTYPE busconfig PUBLIC \"-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN\" \"http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd\">\n<busconfig>\n  <include>/usr/share/dbus-1/session.conf</include>\n  <policy context=\"default\">\n");
    for d in DENIED {
        c.push_str(&format!("    <deny send_destination=\"{d}\"/>\n    <deny own=\"{d}\"/>\n"));
    }
    c.push_str("  </policy>\n</busconfig>\n");
    c
}

fn spawn(cmd: &mut Command, group: u32) -> Result<Child, String> {
    use std::os::unix::process::CommandExt;
    // SAFETY: only async-signal-safe calls between fork and exec (one prctl). If the daemon dies,
    // however it dies, the kernel kills this child.
    unsafe {
        cmd.pre_exec(|| {
            libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL);
            Ok(())
        });
    }
    cmd.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).process_group(group as i32);
    cmd.spawn().map_err(|e| format!("cannot start {:?}: {e}", cmd.get_program()))
}

fn wait_for(deadline: Duration, mut ready: impl FnMut() -> bool) -> bool {
    let end = Instant::now() + deadline;
    while Instant::now() < end {
        if ready() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    false
}

// ---- tying the stacks to the daemon's life ----------------------------------------------------

/// The process groups of the stacks that are up, readable from a signal handler.
static GROUPS: [AtomicI32; 512] = [const { AtomicI32::new(0) }; 512];

fn register(group: u32) {
    for slot in GROUPS.iter() {
        if slot.compare_exchange(0, group as i32, Ordering::SeqCst, Ordering::SeqCst).is_ok() {
            return;
        }
    }
}

fn unregister(group: u32) {
    for slot in GROUPS.iter() {
        let _ = slot.compare_exchange(group as i32, 0, Ordering::SeqCst, Ordering::SeqCst);
    }
}

/// Kills every stack that is up. Async-signal-safe: atomics and `kill` only.
pub fn kill_all() {
    for slot in GROUPS.iter() {
        let g = slot.load(Ordering::SeqCst);
        if g > 1 {
            // SAFETY: a signal to a process group this module created.
            unsafe { libc::kill(-g, libc::SIGKILL) };
        }
    }
}

extern "C" fn on_signal(_: libc::c_int) {
    kill_all();
    // SAFETY: _exit is async-signal-safe.
    unsafe { libc::_exit(0) };
}

/// Takes down every stack when the daemon is told to stop (SIGTERM, SIGINT, SIGHUP). A daemon that
/// dies any other way (SIGKILL, a crash, a panic that ends the process) takes its children with it
/// through PR_SET_PDEATHSIG; the next daemon also sweeps anything that slipped through.
pub fn install_signal_handlers() {
    for sig in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
        // SAFETY: installing a handler that only calls async-signal-safe functions.
        unsafe { libc::signal(sig, on_signal as *const () as libc::sighandler_t) };
    }
}

type Job = (PathBuf, String, Sender<Result<(Vec<Child>, BusInfo), String>>);

/// A thread that lives as long as the daemon and does all the spawning: PR_SET_PDEATHSIG follows the
/// *thread* that forked, and the short-lived threads that serve a request would end it early.
fn spawner() -> &'static Mutex<Sender<Job>> {
    static S: OnceLock<Mutex<Sender<Job>>> = OnceLock::new();
    S.get_or_init(|| {
        let (tx, rx) = channel::<Job>();
        std::thread::spawn(move || {
            for (run, token, reply) in rx {
                let _ = reply.send(start_here(&run, &token));
            }
        });
        Mutex::new(tx)
    })
}

/// Starts the stack on the spawner thread.
pub fn start(run: &Path, token: &str) -> Result<(Vec<Child>, BusInfo), String> {
    let (tx, rx) = channel();
    spawner().lock().unwrap_or_else(|p| p.into_inner()).send((run.to_path_buf(), token.to_string(), tx)).map_err(|_| "the spawner is gone".to_string())?;
    rx.recv().map_err(|_| "the spawner is gone".to_string())?
}

/// Kills the leftovers of an earlier daemon: any bus-stack process of ours whose directory is gone,
/// and any in `run` that no live token owns. Returns how many it killed.
pub fn sweep(run: &Path, live_tags: &HashSet<String>) -> usize {
    let Ok(dir) = std::fs::read_dir("/proc") else { return 0 };
    let me = std::process::id();
    let mut killed = 0;
    for pid in dir.flatten().filter_map(|e| e.file_name().to_str()?.parse::<u32>().ok()) {
        if pid == me {
            continue;
        }
        let mut text = std::fs::read(format!("/proc/{pid}/cmdline")).unwrap_or_default();
        text.push(0);
        text.extend(std::fs::read(format!("/proc/{pid}/environ")).unwrap_or_default().split(|b| *b == 0).filter(|kv| kv.starts_with(b"XDG_RUNTIME_DIR=")).flatten());
        if let Some((base, tag)) = stack_path(&String::from_utf8_lossy(&text)) {
            let orphan = !base.exists() || (base == run && !live_tags.contains(&tag));
            if orphan {
                // SAFETY: SIGKILL to a process whose command line named one of our stacks.
                unsafe { libc::kill(pid as i32, libc::SIGKILL) };
                killed += 1;
            }
        }
    }
    killed
}

/// `(…/baneyspaces, tag)` from the first word that names a stack: `…/baneyspaces/bus-<tag>` or
/// `…/baneyspaces/rt-<tag>…`.
pub fn stack_path(text: &str) -> Option<(PathBuf, String)> {
    for word in text.split(['\0', ' ']) {
        for marker in ["/baneyspaces/bus-", "/baneyspaces/rt-"] {
            if let Some(i) = word.find(marker) {
                let start = word[..i].rfind(['=', ':']).map(|c| c + 1).unwrap_or(0);
                let base = PathBuf::from(format!("{}/baneyspaces", &word[start..i]));
                let tag: String = word[i + marker.len()..].chars().take_while(|c| c.is_ascii_alphanumeric()).collect();
                return Some((base, tag));
            }
        }
    }
    None
}

/// Starts the stack and waits until the accessibility bus exists. The children are returned to be
/// reaped; `BusInfo.pid` is the group to signal.
fn start_here(run: &Path, token: &str) -> Result<(Vec<Child>, BusInfo), String> {
    let sock = socket_path(run, token);
    let rt = rt_dir(run, token);
    let _ = std::fs::remove_file(&sock);
    std::fs::create_dir_all(&rt).map_err(|e| format!("cannot create {}: {e}", rt.display()))?;
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&rt, std::fs::Permissions::from_mode(0o700));
    }
    for bin in [LAUNCHER, REGISTRYD] {
        if !Path::new(bin).exists() {
            return Err(format!("{bin} is missing (at-spi2-core)"));
        }
    }
    let addr = format!("unix:path={}", sock.display());
    let mut daemon = Command::new("/usr/bin/dbus-daemon");
    // Its own runtime directory too: everything the bus activates (a portal, the document portal's
    // FUSE mount, gvfs) lands there and never on top of yours.
    let conf = rt.join("session.conf");
    std::fs::write(&conf, session_conf()).map_err(|e| format!("cannot write {}: {e}", conf.display()))?;
    daemon.arg(format!("--config-file={}", conf.display())).args(["--nofork", "--nopidfile", &format!("--address={addr}")]).env("XDG_RUNTIME_DIR", &rt);
    let leader = spawn(&mut daemon, 0).map_err(|e| format!("{e} (is dbus installed?)"))?;
    let group = leader.id();
    register(group);
    let mut kids = vec![leader];
    let fail = |kids: &mut Vec<Child>, msg: String| -> String {
        unregister(group);
        unsafe { libc::kill(-(group as i32), libc::SIGKILL) };
        for k in kids.iter_mut() {
            let _ = k.wait();
        }
        let _ = std::fs::remove_file(&sock);
        let _ = std::fs::remove_dir_all(&rt);
        msg
    };
    if !wait_for(Duration::from_secs(3), || sock.exists()) {
        return Err(fail(&mut kids, "the private session bus did not come up".into()));
    }
    // The accessibility bus: the launcher owns org.a11y.Bus on the private session bus and starts the
    // a11y bus under the private runtime directory, so it cannot touch yours.
    let mut launcher = Command::new(LAUNCHER);
    launcher.arg("--launch-immediately").env("XDG_RUNTIME_DIR", &rt).env("DBUS_SESSION_BUS_ADDRESS", &addr);
    match spawn(&mut launcher, group) {
        Ok(k) => kids.push(k),
        Err(e) => return Err(fail(&mut kids, e)),
    }
    let a11y_up = || std::fs::read_dir(rt.join("at-spi")).is_ok_and(|d| d.flatten().any(|e| e.file_name().to_string_lossy().starts_with("bus")));
    if !wait_for(Duration::from_secs(3), a11y_up) {
        return Err(fail(&mut kids, "the private accessibility bus did not come up".into()));
    }
    let mut registry = Command::new(REGISTRYD);
    registry.arg("--use-gnome-session").env("XDG_RUNTIME_DIR", &rt).env("DBUS_SESSION_BUS_ADDRESS", &addr);
    match spawn(&mut registry, group) {
        Ok(k) => kids.push(k),
        Err(e) => return Err(fail(&mut kids, e)),
    }
    let start = crate::proc::start_time(group).unwrap_or(0);
    Ok((kids, BusInfo { addr, pid: group, start }))
}

/// Lazily unmounts the FUSE mounts a portal or gvfs left in a private runtime directory.
fn unmount_all(rt: &Path) {
    for sub in ["doc", "gvfs"] {
        let m = rt.join(sub);
        if m.exists() {
            let _ = Command::new("fusermount3").args(["-uz"]).arg(&m).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).status();
        }
    }
}

/// Everything needed to take a stack down. It is separate from the Core lock on purpose: stopping
/// waits for processes to exit, and the daemon must not hold up your keys for that.
pub struct StopJob {
    pub run: PathBuf,
    pub token: String,
    pub kids: Option<Vec<Child>>,
    pub info: Option<BusInfo>,
}

impl StopJob {
    pub fn run(mut self) {
        stop(&self.run, &self.token, self.kids.as_mut(), self.info.as_ref());
    }
}

/// Stops the stack: SIGTERM to the whole process group so portals and gvfs unmount, a short wait in
/// which the children are reaped (a zombie keeps its group looking alive), SIGKILL for what is left,
/// then the sockets, the mounts and the private runtime directory.
pub fn stop(run: &Path, token: &str, mut kids: Option<&mut Vec<Child>>, info: Option<&BusInfo>) {
    if let Some(i) = info {
        unregister(i.pid);
        if i.pid > 1 && crate::proc::start_time(i.pid) == Some(i.start) {
            // SAFETY: a signal to the group this module created; its leader's identity was just checked.
            unsafe { libc::kill(-(i.pid as i32), libc::SIGTERM) };
            wait_for(Duration::from_millis(800), || {
                let mut all_reaped = true;
                if let Some(k) = kids.as_mut() {
                    for c in k.iter_mut() {
                        all_reaped &= c.try_wait().map(|s| s.is_some()).unwrap_or(true);
                    }
                }
                all_reaped && unsafe { libc::kill(-(i.pid as i32), 0) } != 0
            });
            unsafe { libc::kill(-(i.pid as i32), libc::SIGKILL) };
        }
    }
    if let Some(k) = kids {
        for c in k.iter_mut() {
            let _ = c.kill();
            let _ = c.wait();
        }
    }
    let rt = rt_dir(run, token);
    unmount_all(&rt);
    let _ = std::fs::remove_file(socket_path(run, token));
    let _ = std::fs::remove_dir_all(&rt);
}

/// Removes the private runtime directories of stacks no live token owns (a daemon that was killed
/// outright could not clean up), unmounting what is mounted in them first.
pub fn sweep_dirs(run: &Path, live_tags: &HashSet<String>) {
    let Ok(dir) = std::fs::read_dir(run) else { return };
    for e in dir.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        let tag = name.strip_prefix("rt-").or_else(|| name.strip_prefix("bus-"));
        if let Some(tag) = tag {
            if !live_tags.contains(tag) {
                unmount_all(&run.join(format!("rt-{tag}")));
                let _ = std::fs::remove_file(socket_path(run, tag));
                let _ = std::fs::remove_dir_all(run.join(format!("rt-{tag}")));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_private_bus_refuses_portals_and_notifications() {
        let c = session_conf();
        assert!(c.contains("<include>/usr/share/dbus-1/session.conf</include>"));
        for d in ["org.freedesktop.portal.Desktop", "org.freedesktop.Notifications", "org.freedesktop.impl.portal.desktop.gtk"] {
            assert!(c.contains(&format!("<deny send_destination=\"{d}\"/>")), "{d}");
        }
        // The denials come after the include, so they win.
        assert!(c.find("<include>").unwrap() < c.find("<deny").unwrap());
    }

    #[test]
    fn stack_paths_are_found_in_command_lines_and_environments() {
        let (b, t) = stack_path("dbus-daemon\0--session\0--address=unix:path=/tmp/x/run/baneyspaces/bus-8f452a09\0").unwrap();
        assert_eq!((b, t.as_str()), (PathBuf::from("/tmp/x/run/baneyspaces"), "8f452a09"));
        let (b, t) = stack_path("XDG_RUNTIME_DIR=/tmp/y/baneyspaces/rt-0123abcd").unwrap();
        assert_eq!((b, t.as_str()), (PathBuf::from("/tmp/y/baneyspaces"), "0123abcd"));
        assert!(stack_path("dbus-daemon --session").is_none());
    }

    #[test]
    fn the_sweep_kills_a_stack_whose_directory_is_gone_and_spares_a_live_one() {
        let run = std::env::temp_dir().join(format!("bs-sweep-{}/baneyspaces", std::process::id()));
        std::fs::create_dir_all(&run).unwrap();
        // $0 of `sh -c` carries the marker, as a bus daemon's --address would.
        let gone = Command::new("sh").args(["-c", "sleep 60; :", "/nonexistent-zz/baneyspaces/bus-deadbeef"]).spawn().unwrap();
        let live = Command::new("sh").args(["-c", "sleep 60; :", &format!("{}/bus-11112222", run.display())]).spawn().unwrap();
        let orphan = Command::new("sh").args(["-c", "sleep 60; :", &format!("{}/bus-99998888", run.display())]).spawn().unwrap();
        let tags: HashSet<String> = ["11112222".to_string()].into();
        assert_eq!(sweep(&run, &tags), 2);
        let (mut gone, mut live, mut orphan) = (gone, live, orphan);
        assert!(gone.wait().is_ok_and(|s| !s.success()), "killed");
        assert!(orphan.wait().is_ok_and(|s| !s.success()), "killed");
        assert!(live.try_wait().unwrap().is_none(), "the one a live token owns is still running");
        let _ = live.kill();
        let _ = live.wait();
        let _ = std::fs::remove_dir_all(run.parent().unwrap());
    }

    #[test]
    fn a_private_stack_starts_has_its_own_a11y_bus_and_stops_clean() {
        if ![LAUNCHER, REGISTRYD, "/usr/bin/dbus-daemon"].iter().all(|p| Path::new(p).exists()) {
            return;
        }
        let run = std::env::temp_dir().join(format!("bs-bus-{}", std::process::id()));
        std::fs::create_dir_all(&run).unwrap();
        let tok = "0123456789abcdef";
        let (mut kids, info) = start(&run, tok).unwrap();
        assert!(socket_path(&run, tok).exists());
        assert!(rt_dir(&run, tok).join("at-spi").exists(), "the a11y bus lives in the private runtime dir");
        assert!(info.addr.starts_with("unix:path="));
        stop(&run, tok, Some(&mut kids), Some(&info));
        assert!(!socket_path(&run, tok).exists());
        assert!(!rt_dir(&run, tok).exists());
        assert!(crate::proc::start_time(info.pid) != Some(info.start), "the leader is gone");
        let _ = std::fs::remove_dir_all(&run);
    }
}
