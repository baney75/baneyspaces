//! `agent shot`: a picture of one agent window, taken by the compositor from the window itself, so it
//! works while the window sits hidden on `special:agent` and never shows it, focuses it or touches
//! the user's workspaces.
//!
//! The route is `grim -T <identifier>` (grim 1.5 or later), which asks Hyprland for the window through
//! `ext-foreign-toplevel-list-v1` and `ext-image-copy-capture-v1`. Hyprland names each window in that
//! list by the `stableId` that `hyprctl clients` reports, so the daemon never has to guess which
//! window it is.
//!
//! A window on a hidden special workspace gets no frame callbacks, so it does not repaint on its own:
//! the first capture can show the window as it was before the last action. A capture is itself a
//! frame for the app, though, and the app repaints after it. So the daemon captures until two
//! captures in a row are the same picture (at most `TRIES`), and answers with the last one.
//! `evidence.settled` says whether that happened; an app that keeps animating never settles, and its
//! picture is then the newest frame it drew, at most one frame old.
//!
//! The scope guard runs before every capture and once more before the file is written: the window,
//! its process, its start time, its `stableId` and its workspace must still be what they were.

use crate::daemon::{append_record, now, record, Shared};
use crate::hands::{guard, screen_state};
use baneyspaces_core::agent::ActionRecord;
use baneyspaces_core::envelope::{Envelope, Retry};
use serde_json::{json, Value};
use std::io::Read;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// Captures until two in a row match, at most this many.
pub const TRIES: usize = 5;
/// Between captures: a frame or two for the app to repaint after the last one.
const GAP: Duration = Duration::from_millis(120);
/// One capture.
const CAPTURE_TIMEOUT: Duration = Duration::from_secs(8);
/// The whole call, well inside the client's wait.
const BUDGET: Duration = Duration::from_secs(30);
/// The route name in the action log.
const ROUTE: &str = "grim";

/// The same rule as the Mac's `HandoffPath.isPlainFileName`: a name, never a path.
pub fn plain_file_name(name: &str) -> bool {
    !name.is_empty()
        && name.chars().count() <= 120
        && !name.contains('/')
        && !name.contains('\\')
        && !name.starts_with('.')
        && !name.contains('\0')
}

/// The file name a shot is written to: the caller's plain name, or `window-<address>-<unix time>.png`.
pub fn shot_name(out: Option<&str>, window: &str, at: u64) -> Result<String, Envelope> {
    match out {
        Some(n) if plain_file_name(n) => Ok(n.to_string()),
        Some(_) => Err(Envelope::err(
            "invalid_args",
            "out must be a file name, not a path",
            Retry::Safe,
            "Pass just a name like `page.png`; shots are written in BaneySpaces' own shots folder.",
        )),
        None => Ok(format!("window-{}-{at}.png", window.trim_start_matches("0x"))),
    }
}

/// Hyprland's `stableId` is a short hex string. Anything else is not passed to grim.
pub fn valid_stable_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 16 && id.bytes().all(|b| b.is_ascii_hexdigit())
}

/// grim's command line for one capture. The identifier is checked first, so it can never be read as
/// an option, and the file is a path the daemon made.
pub fn grim_argv(stable_id: &str, file: &Path) -> Result<Vec<String>, Envelope> {
    if !valid_stable_id(stable_id) {
        return Err(Envelope::err(
            "not_supported",
            "Hyprland did not report a usable stableId for this window",
            Retry::Never,
            "agent shot needs Hyprland 0.5x or later, which names windows for ext-foreign-toplevel-list.",
        ));
    }
    Ok(vec!["-t".into(), "png".into(), "-T".into(), stable_id.into(), file.display().to_string()])
}

/// Whether grim's usage text offers `-T` (grim 1.5 or later).
pub fn grim_has_toplevel(help: &str) -> bool {
    help.lines().any(|l| l.trim_start().starts_with("-T "))
}

/// Finds grim: `$BANEYSPACES_GRIM`, else the system binary (never a copy earlier on PATH).
pub fn locate_grim() -> Option<PathBuf> {
    let mut c: Vec<PathBuf> = vec![];
    if let Ok(p) = std::env::var("BANEYSPACES_GRIM") {
        c.push(p.into());
    }
    c.extend(["/usr/bin/grim", "/usr/local/bin/grim", "/bin/grim"].map(PathBuf::from));
    c.into_iter().find(|p| p.is_file())
}

/// The width and height in a PNG's header, or None for anything that is not a PNG.
pub fn png_size(b: &[u8]) -> Option<(u32, u32)> {
    const SIG: &[u8] = b"\x89PNG\r\n\x1a\n";
    if b.len() < 24 || &b[..8] != SIG || &b[12..16] != b"IHDR" {
        return None;
    }
    let w = u32::from_be_bytes(b[16..20].try_into().ok()?);
    let h = u32::from_be_bytes(b[20..24].try_into().ok()?);
    (w > 0 && h > 0).then_some((w, h))
}

/// SHA-256 as lowercase hex (FIPS 180-4). Here so the capture hash needs no new dependency.
pub fn sha256_hex(data: &[u8]) -> String {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ];
    let mut h: [u32; 8] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
    let mut msg = data.to_vec();
    let bits = (data.len() as u64).wrapping_mul(8);
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&bits.to_be_bytes());
    for block in msg.chunks_exact(64) {
        let mut w = [0u32; 64];
        for (i, word) in block.chunks_exact(4).enumerate() {
            w[i] = u32::from_be_bytes([word[0], word[1], word[2], word[3]]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16].wrapping_add(s0).wrapping_add(w[i - 7]).wrapping_add(s1);
        }
        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut hh] = h;
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ (!e & g);
            let t1 = hh.wrapping_add(s1).wrapping_add(ch).wrapping_add(K[i]).wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let t2 = s0.wrapping_add(maj);
            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(t1);
            d = c;
            c = b;
            b = a;
            a = t1.wrapping_add(t2);
        }
        for (x, y) in h.iter_mut().zip([a, b, c, d, e, f, g, hh]) {
            *x = x.wrapping_add(y);
        }
    }
    h.iter().map(|x| format!("{x:08x}")).collect()
}

/// Runs a program with a hard deadline in a process group of its own; the group is killed at the
/// deadline. Ok holds stdout and stderr; Err holds stderr (or why it could not run).
fn run_with_deadline(prog: &Path, args: &[String], timeout: Duration) -> Result<String, String> {
    use std::os::unix::process::CommandExt;
    let mut child = Command::new(prog)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0)
        .spawn()
        .map_err(|e| format!("cannot start {}: {e}", prog.display()))?;
    let group = child.id() as i32;
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                let mut out = String::new();
                let mut err = String::new();
                if let Some(mut o) = child.stdout.take() {
                    let _ = o.read_to_string(&mut out);
                }
                if let Some(mut e) = child.stderr.take() {
                    let _ = e.read_to_string(&mut err);
                }
                return if status.success() {
                    Ok(out + &err)
                } else {
                    Err(out + &err)
                };
            }
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(10)),
            _ => {
                // SAFETY: a signal to the process group this call created.
                unsafe { libc::kill(-group, libc::SIGKILL) };
                let _ = child.wait();
                return Err("it did not finish in time".into());
            }
        }
    }
}

/// What one shot captured, before it is published.
#[derive(Debug, PartialEq)]
pub struct Settled {
    pub bytes: Vec<u8>,
    pub frames: usize,
    pub settled: bool,
}

/// Captures until two captures in a row are identical, or `tries` captures were taken. `check` runs
/// before every capture and stops the loop with its error. `capture` returns one PNG.
pub fn settle(
    tries: usize,
    gap: Duration,
    mut check: impl FnMut() -> Result<(), Envelope>,
    mut capture: impl FnMut() -> Result<Vec<u8>, Envelope>,
) -> Result<Settled, Envelope> {
    let mut last: Option<Vec<u8>> = None;
    for n in 1..=tries.max(2) {
        check()?;
        let now = capture()?;
        if last.as_deref() == Some(now.as_slice()) {
            return Ok(Settled { bytes: now, frames: n, settled: true });
        }
        last = Some(now);
        if n < tries.max(2) {
            std::thread::sleep(gap);
        }
    }
    Ok(Settled { bytes: last.unwrap_or_default(), frames: tries.max(2), settled: false })
}

fn shots_dir(state: &Path) -> Result<PathBuf, Envelope> {
    let d = state.join("shots");
    std::fs::create_dir_all(&d)
        .and_then(|_| std::fs::set_permissions(&d, std::fs::Permissions::from_mode(0o700)))
        .map_err(|e| Envelope::err("engine_error", format!("cannot create {}: {e}", d.display()), Retry::Safe, "Check the disk and the state folder's permissions."))?;
    Ok(d)
}

/// Writes the picture under its name: a temporary file made 0600, then renamed, so a reader never
/// sees half a file.
fn publish(dir: &Path, name: &str, bytes: &[u8]) -> Result<PathBuf, Envelope> {
    use std::io::Write;
    let fail = |e: std::io::Error| Envelope::err("engine_error", format!("couldn't write the capture: {e}"), Retry::Safe, "Check disk space.");
    let tmp = dir.join(format!(".{}-{}.part", std::process::id(), now_nanos()));
    let mut f = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&tmp).map_err(fail)?;
    f.write_all(bytes).and_then(|_| f.sync_all()).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        fail(e)
    })?;
    let file = dir.join(name);
    std::fs::rename(&tmp, &file).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        fail(e)
    })?;
    Ok(file)
}

fn now_nanos() -> u128 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0)
}

pub fn run(shared: &Shared, agent: &str, args: &Value) -> Envelope {
    let window = args["window"].as_str().map(String::from);
    let out = args["out"].as_str();
    let refuse = |env: Envelope, pid: Option<u32>| {
        let c = crate::daemon::lock(shared);
        record(&c, agent, "shot", pid, window.as_deref(), None, ROUTE, &env);
        env
    };
    let Some(window) = window.clone() else {
        return refuse(Envelope::err("invalid_args", "--window <id> is required (see `baneyspaces agent status`)", Retry::Never, "Run `baneyspaces help`."), None);
    };
    let name = match shot_name(out, &window, now()) {
        Ok(n) => n,
        Err(e) => return refuse(e, None),
    };

    // 1. The scope guard, under the lock, exactly as for every other verb.
    let (plan, stable, before, state) = {
        let c = crate::daemon::lock(shared);
        let plan = match guard(&c, &window, None) {
            Ok(p) => p,
            Err(env) => {
                record(&c, agent, "shot", None, Some(&window), None, ROUTE, &env);
                return env;
            }
        };
        let stable = plan.stable.clone();
        (plan, stable, screen_state(&c), c.paths.state.clone())
    };
    let Some(grim) = locate_grim() else {
        return refuse(Envelope::err("not_supported", "agent shot needs grim (1.5 or later), and it is not installed", Retry::Never, "Install grim, which Omarchy ships, or read the window with snapshot."), Some(plan.pid));
    };
    // grim prints its usage for -h; some versions exit non-zero after it, so either answer is read.
    match run_with_deadline(&grim, &["-h".into()], Duration::from_secs(5)) {
        Ok(help) | Err(help) if grim_has_toplevel(&help) => {}
        _ => return refuse(Envelope::err("not_supported", "this grim cannot capture one window (it has no -T; grim 1.5 or later can)", Retry::Never, "Update grim, or read the window with snapshot."), Some(plan.pid)),
    }
    let dir = match shots_dir(&state) {
        Ok(d) => d,
        Err(e) => return refuse(e, Some(plan.pid)),
    };

    // 2. Capture, without the lock. Before each capture the window must still be the one guarded.
    let stall = crate::daemon::lock(shared).stall_ms;
    if stall > 0 && std::env::var("BANEYSPACES_TEST_OPS").is_ok_and(|v| v == "1") {
        std::thread::sleep(Duration::from_millis(stall)); // test only: lets nested.sh move the window mid-shot
    }
    let started = Instant::now();
    let expect = crate::hands::SnapInfo { window: plan.window.clone(), pid: plan.pid, start: plan.start, stable: plan.stable.clone() };
    let still_ours = || -> Result<(), Envelope> {
        let c = crate::daemon::lock(shared);
        let same_window = c.client(&plan.window).is_some_and(|cl| cl.stable_id == stable);
        if guard(&c, &plan.window, Some(&expect)).is_err() || !same_window {
            return Err(Envelope::err("not_in_scope", "the window changed while it was being captured (it moved, or its process changed), so no picture was kept", Retry::Never, "Take a new snapshot of a window on the agent workspace."));
        }
        if started.elapsed() > BUDGET {
            return Err(Envelope::err("timeout", "the capture took too long", Retry::Safe, "Try again."));
        }
        Ok(())
    };
    let part = dir.join(format!(".capture-{}-{}.png", std::process::id(), now_nanos()));
    let capture = || -> Result<Vec<u8>, Envelope> {
        let argv = grim_argv(&stable, &part)?;
        run_with_deadline(&grim, &argv, CAPTURE_TIMEOUT).map_err(|e| Envelope::err("engine_error", format!("grim could not capture the window: {}", e.lines().next().unwrap_or("it failed")), Retry::Safe, "Try again; if it keeps failing, check that Hyprland offers ext-image-copy-capture-v1."))?;
        let bytes = std::fs::read(&part).map_err(|e| Envelope::err("engine_error", format!("grim wrote no picture: {e}"), Retry::Safe, "Try again."));
        let _ = std::fs::remove_file(&part);
        let bytes = bytes?;
        if png_size(&bytes).is_none() {
            return Err(Envelope::err("engine_error", "grim's output is not a PNG", Retry::Safe, "Try again."));
        }
        Ok(bytes)
    };
    let result = settle(TRIES, GAP, still_ours, capture);
    let _ = std::fs::remove_file(&part);

    // 3. Scope once more before anything is published, then write, record, answer.
    let result = result.and_then(|s| still_ours().map(|_| s));
    let mut env = match result {
        Err(e) => e,
        Ok(s) => match publish(&dir, &name, &s.bytes) {
            Err(e) => e,
            Ok(path) => {
                let (w, h) = png_size(&s.bytes).unwrap_or((0, 0));
                Envelope::ok(json!({
                    "path": path.display().to_string(),
                    "width": w,
                    "height": h,
                    "cursor": false,
                    "evidence": { "kind": "capture_hash", "sha256": sha256_hex(&s.bytes), "frames": s.frames, "settled": s.settled },
                    "target": { "pid": plan.pid, "window": plan.window, "app": plan.class, "scope": "agent workspace" },
                }))
            }
        },
    };
    let c = crate::daemon::lock(shared);
    let changed = screen_state(&c) != before;
    if let Some(d) = env.data.as_mut() {
        d["screen_changed"] = json!(changed);
        d["window"] = json!(plan.window);
        d["pid"] = json!(plan.pid);
    }
    let mut rec = ActionRecord::from_result(now(), agent, "shot", Some(plan.pid), Some(&plan.window), None, ROUTE, &env);
    rec.screen_changed = changed;
    append_record(&c, &rec);
    env
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn out_is_a_plain_name_or_a_default() {
        assert_eq!(shot_name(None, "0x5da0a52143c0", 7).unwrap(), "window-5da0a52143c0-7.png");
        assert_eq!(shot_name(Some("page.png"), "0x1", 7).unwrap(), "page.png");
        for bad in ["", "../x.png", "a/b.png", "/tmp/x.png", ".hidden.png", "a\\b.png", "a\0b", &"x".repeat(121)] {
            let e = shot_name(Some(bad), "0x1", 7).unwrap_err().error.unwrap();
            assert_eq!(e.code, "invalid_args", "{bad:?}");
        }
    }

    #[test]
    fn the_grim_command_names_one_window_and_nothing_else() {
        let a = grim_argv("18000002", Path::new("/s/.capture-1.png")).unwrap();
        assert_eq!(a, ["-t", "png", "-T", "18000002", "/s/.capture-1.png"]);
        // Never the whole screen: no -o, no -g, and the identifier is always given.
        assert!(!a.iter().any(|x| x == "-o" || x == "-g" || x == "-c"));
        // An identifier that is not Hyprland's hex stableId is refused, never passed on as an option or empty.
        for bad in ["", "-o", "--help", "18000002 -o", "0x18", "g1", &"a".repeat(17)] {
            assert_eq!(grim_argv(bad, Path::new("/s/x.png")).unwrap_err().error.unwrap().code, "not_supported", "{bad:?}");
        }
    }

    #[test]
    fn only_a_grim_with_toplevel_capture_is_used() {
        let new = "Usage: grim [options...] [output-file]\n  -o <output>     Set the output name to capture.\n  -T <identifier> Set the identifier of a foreign toplevel handle to capture.\n";
        let old = "Usage: grim [options...] [output-file]\n  -t png|ppm|jpeg Set the output filetype.\n  -o <output>     Set the output name to capture.\n";
        assert!(grim_has_toplevel(new));
        assert!(!grim_has_toplevel(old));
    }

    #[test]
    fn png_size_reads_the_header_and_rejects_anything_else() {
        let mut png = b"\x89PNG\r\n\x1a\n\0\0\0\x0dIHDR".to_vec();
        png.extend_from_slice(&1878u32.to_be_bytes());
        png.extend_from_slice(&1038u32.to_be_bytes());
        assert_eq!(png_size(&png), Some((1878, 1038)));
        assert_eq!(png_size(b"P6\n1 1\n255\n\0\0\0"), None);
        assert_eq!(png_size(&png[..20]), None);
    }

    #[test]
    fn sha256_matches_the_standard_vectors() {
        assert_eq!(sha256_hex(b""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
        assert_eq!(sha256_hex(b"abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        assert_eq!(
            sha256_hex(b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        );
        assert_eq!(sha256_hex(&vec![b'a'; 1_000_000]), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
    }

    #[test]
    fn a_capture_is_kept_only_once_two_in_a_row_agree() {
        // A hidden window shows its old frame first and repaints after it is captured.
        let frames = ["count 0", "count 1", "count 1"];
        let mut i = 0;
        let s = settle(5, Duration::ZERO, || Ok(()), || { i += 1; Ok(frames[i - 1].as_bytes().to_vec()) }).unwrap();
        assert_eq!(s, Settled { bytes: b"count 1".to_vec(), frames: 3, settled: true });
        // Even a window that is current at once is captured twice.
        let mut n = 0;
        let s = settle(5, Duration::ZERO, || Ok(()), || { n += 1; Ok(b"same".to_vec()) }).unwrap();
        assert_eq!((n, s.frames, s.settled), (2, 2, true));
        // A window that never settles stops at the limit with its newest frame, and says so.
        let mut k = 0u8;
        let s = settle(4, Duration::ZERO, || Ok(()), || { k += 1; Ok(vec![k]) }).unwrap();
        assert_eq!(s, Settled { bytes: vec![4], frames: 4, settled: false });
    }

    #[test]
    fn a_window_that_leaves_scope_mid_shot_is_not_captured_again() {
        let mut checks = 0;
        let mut captures = 0;
        let e = settle(
            5,
            Duration::ZERO,
            || {
                checks += 1;
                if checks == 2 { Err(Envelope::err("not_in_scope", "moved", Retry::Never, "")) } else { Ok(()) }
            },
            || { captures += 1; Ok(vec![captures]) },
        )
        .unwrap_err();
        assert_eq!(e.error.unwrap().code, "not_in_scope");
        assert_eq!(captures, 1, "nothing is captured after the check fails");
    }

    #[test]
    fn a_capture_error_ends_the_shot() {
        let e = settle(5, Duration::ZERO, || Ok(()), || Err(Envelope::err("engine_error", "no", Retry::Safe, ""))).unwrap_err();
        assert_eq!(e.error.unwrap().code, "engine_error");
    }

    #[test]
    fn publish_writes_a_private_file_atomically() {
        let dir = std::env::temp_dir().join(format!("bs-shot-{}-{}", std::process::id(), now_nanos()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = publish(&dir, "a.png", b"one").unwrap();
        assert_eq!(std::fs::read(&p).unwrap(), b"one");
        assert_eq!(std::fs::metadata(&p).unwrap().permissions().mode() & 0o777, 0o600);
        // The same name again replaces it, and no temporary file is left behind.
        publish(&dir, "a.png", b"two").unwrap();
        assert_eq!(std::fs::read(&p).unwrap(), b"two");
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
