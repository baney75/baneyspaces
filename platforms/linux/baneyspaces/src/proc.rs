//! Process identity from /proc: start time (so a reused pid is told apart), the launch token in a
//! process's environment, and liveness. Same-user only; nothing here needs privilege.

use std::fs;

/// Start time in clock ticks since boot (field 22 of /proc/<pid>/stat), or None if gone.
pub fn start_time(pid: u32) -> Option<u64> {
    let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    parse_start(&stat)
}

pub fn parse_start(stat: &str) -> Option<u64> {
    parse_stat(stat).map(|s| s.start)
}

/// The two fields of /proc/<pid>/stat that place a process in the tree.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Stat {
    pub ppid: u32,
    /// Clock ticks since boot (field 22).
    pub start: u64,
}

pub fn parse_stat(stat: &str) -> Option<Stat> {
    // The command name is in parentheses and may contain spaces and parentheses: split after the last ')'.
    let rest: Vec<&str> = stat[stat.rfind(')')? + 1..].split_whitespace().collect();
    Some(Stat { ppid: rest.get(1)?.parse().ok()?, start: rest.get(19)?.parse().ok()? })
}

/// What the tree walk reads about a process. `Live` reads /proc; tests give a fake tree.
pub trait Procs {
    fn stat(&self, pid: u32) -> Option<Stat>;
    /// The launch token in the process's environment, as `token_of` reads it.
    fn token(&self, pid: u32) -> Option<String>;
}

pub struct Live;

impl Procs for Live {
    fn stat(&self, pid: u32) -> Option<Stat> {
        parse_stat(&fs::read_to_string(format!("/proc/{pid}/stat")).ok()?)
    }
    fn token(&self, pid: u32) -> Option<String> {
        token_of(pid)
    }
}

/// How far up the tree a window's process is looked for in a launch: a browser's window is two or
/// three steps from the launch's anchor.
const MAX_DEPTH: usize = 16;

/// The launch token `pid` inherits from the nearest ancestor that carries one, when `ours` says we
/// issued it. For a process whose own environ no longer says (Chromium's setproctitle writes its command
/// line over the environ in place, so the browser, its zygotes and helpers all read back without the
/// token). Each step reads the child's parent and checks it again after the parent is read: the
/// parent must have started no later than the child, and the child must still have that parent with
/// the same start time, so a parent that exited and whose pid went to a new process is never taken.
/// Only the nearest token counts: a nearer token we did not issue ends the walk.
pub fn inherited_token(p: &dyn Procs, pid: u32, ours: &dyn Fn(&str) -> bool) -> Option<String> {
    let mut child = pid;
    let mut was = p.stat(child)?;
    for _ in 0..MAX_DEPTH {
        let parent = was.ppid;
        if parent <= 1 {
            return None;
        }
        let up = p.stat(parent)?;
        if up.start > was.start || p.stat(child)? != was {
            return None;
        }
        if let Some(tok) = p.token(parent) {
            return ours(&tok).then_some(tok);
        }
        child = parent;
        was = up;
    }
    None
}

/// `$0` of the shell a launch runs its app under when the app rewrites its own environ (a
/// Chromium-family browser): the shell keeps the token, waits for the app and is its parent, so the
/// browser's processes are found as its descendants.
pub const ANCHOR: &str = "baneyspaces-launch";

/// The command that runs `argv` under the anchor shell. The shell forks (a command follows), so it
/// stays the app's parent for as long as the app runs, and exits with its status.
pub fn anchored(argv: &[String]) -> Vec<String> {
    let mut v: Vec<String> = vec!["/bin/sh".into(), "-c".into(), "\"$@\"; exit $?".into(), ANCHOR.into()];
    v.extend(argv.iter().cloned());
    v
}

/// Whether a command line (NUL separated, as /proc/<pid>/cmdline) is the anchor shell's.
pub fn is_anchor_cmdline(cmdline: &[u8]) -> bool {
    cmdline.split(|b| *b == 0).nth(3) == Some(ANCHOR.as_bytes())
}

/// The process a launch started, from the live processes carrying its token: the one that started
/// first (the app, or the anchor shell, before anything the app spawns), and under an anchor the
/// anchor's first child, which is the app. Never a helper the app spawned and sent off on its own
/// (Chromium's crash handler keeps the token but is a child of the session's reaper, not the
/// anchor's, and starts after the browser).
pub fn launch_pid(p: &dyn Procs, carriers: &[u32], is_anchor: &dyn Fn(u32) -> bool, all: &[u32]) -> Option<u32> {
    let (root, rs) = carriers.iter().filter_map(|c| Some((*c, p.stat(*c)?))).min_by_key(|(c, s)| (s.start, *c))?;
    if !is_anchor(root) {
        return Some(root);
    }
    all.iter().filter_map(|c| Some((*c, p.stat(*c)?))).filter(|(_, s)| s.ppid == root && s.start >= rs.start).min_by_key(|(c, s)| (s.start, *c)).map(|(c, _)| c)
}

/// Every live pid.
pub fn all_pids() -> Vec<u32> {
    fs::read_dir("/proc").map(|d| d.flatten().filter_map(|e| e.file_name().to_str()?.parse::<u32>().ok()).collect()).unwrap_or_default()
}

/// Whether the live process `pid` is a launch's anchor shell.
pub fn is_anchor(pid: u32) -> bool {
    fs::read(format!("/proc/{pid}/cmdline")).is_ok_and(|c| is_anchor_cmdline(&c))
}

/// How long ago the process started, from its start time and the system's uptime, or None if gone.
pub fn age(pid: u32) -> Option<std::time::Duration> {
    let up: f64 = fs::read_to_string("/proc/uptime").ok()?.split_whitespace().next()?.parse().ok()?;
    // SAFETY: sysconf has no preconditions.
    let hz = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
    let started = start_time(pid)? as f64 / if hz > 0 { hz as f64 } else { 100.0 };
    Some(std::time::Duration::from_secs_f64((up - started).max(0.0)))
}

#[allow(dead_code)]
pub fn alive(pid: u32) -> bool {
    start_time(pid).is_some()
}

/// The value of `BANEYSPACES_AGENT_TOKEN` in the process's environment, if it has one.
pub fn token_of(pid: u32) -> Option<String> {
    let env = fs::read(format!("/proc/{pid}/environ")).ok()?;
    parse_token(&env)
}

/// `token_of` for a process that may have just started. Right after its exec, a process's environ can read back
/// empty for a moment (measured under load: about 13% of reads right after spawn, none 50 ms later), and a window
/// mapped then would not be taken for the agent's. An empty read is tried again, 5 times 10 ms apart at most. Not for
/// sweeps over /proc: kernel threads have an empty environ for good.
pub fn settled_token_of(pid: u32) -> Option<String> {
    settle(|| read_environ(pid), 5, || std::thread::sleep(std::time::Duration::from_millis(10)))
}

#[cfg(test)]
thread_local! {
    /// Tests: this many of this thread's next adopt reads come back empty, as right after an exec.
    pub static EMPTY_ENVIRON_READS: std::cell::Cell<u32> = const { std::cell::Cell::new(0) };
}

fn read_environ(pid: u32) -> Option<Vec<u8>> {
    #[cfg(test)]
    if EMPTY_ENVIRON_READS.with(|n| n.get() > 0 && { n.set(n.get() - 1); true }) {
        return Some(Vec::new());
    }
    fs::read(format!("/proc/{pid}/environ")).ok()
}

/// Reads until a read is not empty or `tries` are used; a failed read (the process is gone) ends it at once.
pub fn settle(read: impl Fn() -> Option<Vec<u8>>, tries: u32, pause: impl Fn()) -> Option<String> {
    for i in 0..tries {
        let env = read()?;
        if !env.is_empty() || i + 1 == tries {
            return parse_token(&env);
        }
        pause();
    }
    None
}

pub fn parse_token(environ: &[u8]) -> Option<String> {
    environ.split(|b| *b == 0).find_map(|kv| {
        let kv = std::str::from_utf8(kv).ok()?;
        kv.strip_prefix("BANEYSPACES_AGENT_TOKEN=")
            .map(String::from)
    })
}

/// Pids of live processes carrying `token` in their environment.
pub fn pids_with_token(token: &str) -> Vec<u32> {
    all_pids().into_iter().filter(|p| token_of(*p).as_deref() == Some(token)).collect()
}

/// Every live process carrying a launch token, by token: one pass over /proc for all of them.
pub fn pids_by_token() -> std::collections::HashMap<String, Vec<u32>> {
    let mut m: std::collections::HashMap<String, Vec<u32>> = std::collections::HashMap::new();
    for p in all_pids() {
        if let Some(t) = token_of(p) {
            m.entry(t).or_default().push(p);
        }
    }
    m
}

/// 128 random bits as hex, from the kernel.
pub fn random_token() -> std::io::Result<String> {
    use std::io::Read;
    let mut b = [0u8; 16];
    fs::File::open("/dev/urandom")?.read_exact(&mut b)?;
    Ok(b.iter().map(|x| format!("{x:02x}")).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn start_time_survives_a_hostile_command_name() {
        let stat = "123 (we ird) name) S 1 123 123 0 -1 4194560 100 0 0 0 1 2 0 0 20 0 1 0 987654 1000 100 18446744073709551615";
        assert_eq!(parse_start(stat), Some(987654));
    }

    #[test]
    fn own_process_has_a_start_time() {
        assert!(start_time(std::process::id()).is_some());
        assert!(alive(std::process::id()));
        assert!(!alive(u32::MAX - 1));
    }

    #[test]
    fn token_is_read_from_environ_bytes() {
        assert_eq!(
            parse_token(b"A=1\0BANEYSPACES_AGENT_TOKEN=abc\0B=2\0"),
            Some("abc".into())
        );
        assert_eq!(parse_token(b"A=1\0XBANEYSPACES_AGENT_TOKEN=abc\0"), None);
    }

    #[test]
    fn an_environ_that_reads_empty_right_after_exec_is_read_again() {
        let reads = std::cell::Cell::new(0);
        let read = || {
            reads.set(reads.get() + 1);
            Some(if reads.get() < 3 { Vec::new() } else { b"A=1\0BANEYSPACES_AGENT_TOKEN=abc\0".to_vec() })
        };
        assert_eq!(settle(read, 5, || {}), Some("abc".into()));
        assert_eq!(reads.get(), 3);
        // Empty for good (a kernel thread): it stops after its tries.
        let n = std::cell::Cell::new(0);
        assert_eq!(settle(|| { n.set(n.get() + 1); Some(Vec::new()) }, 5, || {}), None);
        assert_eq!(n.get(), 5);
        // Gone: no second read.
        let m = std::cell::Cell::new(0);
        assert_eq!(settle(|| { m.set(m.get() + 1); None }, 5, || {}), None);
        assert_eq!(m.get(), 1);
    }

    #[test]
    fn a_process_just_started_is_young_and_a_gone_one_has_no_age() {
        let mut child = std::process::Command::new("sleep").arg("5").spawn().unwrap();
        let young = age(child.id()).unwrap();
        assert!(young < std::time::Duration::from_secs(2), "{young:?}");
        // This test process has run at least as long as the child it started.
        assert!(age(std::process::id()).unwrap() >= young);
        let _ = child.kill();
        let _ = child.wait();
        assert_eq!(age(child.id()), None);
    }

    /// A fake /proc: pid -> (parent, start time, token in its environ).
    struct Tree(std::collections::HashMap<u32, (u32, u64, Option<&'static str>)>);

    impl Tree {
        fn new(rows: &[(u32, u32, u64, Option<&'static str>)]) -> Tree {
            Tree(rows.iter().map(|(p, pp, st, t)| (*p, (*pp, *st, *t))).collect())
        }
    }

    impl Procs for Tree {
        fn stat(&self, pid: u32) -> Option<Stat> {
            self.0.get(&pid).map(|(ppid, start, _)| Stat { ppid: *ppid, start: *start })
        }
        fn token(&self, pid: u32) -> Option<String> {
            self.0.get(&pid).and_then(|(_, _, t)| t.map(String::from))
        }
    }

    fn ours(t: &str) -> bool {
        t == "tok"
    }

    /// Parish1, 11-15: the anchor shell keeps the token; the browser, its zygotes and renderers read
    /// back without it; the crash handler keeps it but is the session reaper's child.
    fn chromium() -> Tree {
        Tree::new(&[
            (1942, 1, 10, None),           // systemd --user, the reaper
            (500, 1942, 100, Some("tok")), // the anchor shell
            (501, 500, 101, None),         // the browser (its window's pid)
            (505, 1942, 102, Some("tok")), // chrome_crashpad_handler, sent off to the reaper
            (510, 501, 103, None),         // zygote
            (511, 510, 104, None),         // zygote's fork
            (520, 511, 105, None),         // renderer
            (600, 1942, 50, None),         // your own Chromium
            (601, 600, 51, None),          // its zygote
        ])
    }

    #[test]
    fn a_browser_whose_environ_was_rewritten_inherits_its_anchors_token() {
        let t = chromium();
        assert_eq!(inherited_token(&t, 501, &ours), Some("tok".into()));
        assert_eq!(inherited_token(&t, 520, &ours), Some("tok".into()), "three steps down");
    }

    #[test]
    fn a_process_outside_the_launch_inherits_nothing() {
        let t = chromium();
        assert_eq!(inherited_token(&t, 600, &ours), None, "your Chromium, a child of the reaper");
        assert_eq!(inherited_token(&t, 601, &ours), None);
        assert_eq!(inherited_token(&t, 1942, &ours), None);
        assert_eq!(inherited_token(&t, 9999, &ours), None, "gone");
    }

    #[test]
    fn a_reused_parent_pid_is_not_an_ancestor() {
        // The anchor exited and its pid went to a new process carrying the token, started after the
        // browser: the browser's stat still names the pid, but that process cannot be its parent.
        let t = Tree::new(&[(500, 1942, 200, Some("tok")), (501, 500, 101, None)]);
        assert_eq!(inherited_token(&t, 501, &ours), None);
        // One level up too: the step from the zygote to the browser is fine, the browser's parent is not.
        let t = Tree::new(&[(500, 1942, 200, Some("tok")), (501, 500, 101, None), (510, 501, 103, None)]);
        assert_eq!(inherited_token(&t, 510, &ours), None);
    }

    #[test]
    fn a_child_reparented_while_it_is_read_is_not_taken() {
        // The first read of the browser says parent 500; by the time 500 is read the browser was
        // handed to the reaper (500 exited, and its pid was given out again with the same start tick).
        struct Moving(std::cell::Cell<u32>);
        impl Procs for Moving {
            fn stat(&self, pid: u32) -> Option<Stat> {
                match pid {
                    501 => {
                        self.0.set(self.0.get() + 1);
                        Some(Stat { ppid: if self.0.get() == 1 { 500 } else { 1942 }, start: 101 })
                    }
                    500 => Some(Stat { ppid: 1942, start: 100 }),
                    _ => None,
                }
            }
            fn token(&self, pid: u32) -> Option<String> {
                (pid == 500).then(|| "tok".into())
            }
        }
        assert_eq!(inherited_token(&Moving(std::cell::Cell::new(0)), 501, &ours), None);
    }

    #[test]
    fn only_the_nearest_token_counts() {
        // A process that carries a token we did not issue, under a launch of ours, is not ours.
        let t = Tree::new(&[(500, 1942, 100, Some("tok")), (501, 500, 101, Some("other")), (502, 501, 102, None)]);
        assert_eq!(inherited_token(&t, 502, &ours), None);
        // And a token of ours only up past the reaper does not count either: the walk stops at 1.
        let t = Tree::new(&[(1, 0, 1, Some("tok")), (502, 1, 102, None)]);
        assert_eq!(inherited_token(&t, 502, &ours), None);
    }

    #[test]
    fn a_launch_is_its_app_never_the_crash_handler() {
        let t = chromium();
        let all: Vec<u32> = t.0.keys().copied().collect();
        // The crash handler carries the token too, and its pid can be anything.
        assert_eq!(launch_pid(&t, &[505, 500], &|p| p == 500, &all), Some(501));
        // The anchor has not forked yet: nothing to report.
        let early = Tree::new(&[(500, 1942, 100, Some("tok"))]);
        assert_eq!(launch_pid(&early, &[500], &|p| p == 500, &[500]), None);
        // An app with no anchor (a terminal): the process that started first.
        let foot = Tree::new(&[(700, 1942, 300, Some("tok")), (701, 700, 301, Some("tok"))]);
        assert_eq!(launch_pid(&foot, &[701, 700], &|_| false, &[700, 701]), Some(700));
        assert_eq!(launch_pid(&foot, &[], &|_| false, &[700, 701]), None);
    }

    #[test]
    fn the_anchor_shell_stays_the_parent_of_an_app_that_drops_its_environment() {
        let argv = anchored(&["env".into(), "-i".into(), "sleep".into(), "30".into()]);
        let mut sh = std::process::Command::new(&argv[0]).args(&argv[1..]).env("BANEYSPACES_AGENT_TOKEN", "livetok").spawn().unwrap();
        let anchor = sh.id();
        let mut app = None;
        for _ in 0..200 {
            app = all_pids().into_iter().find(|p| Live.stat(*p).is_some_and(|s| s.ppid == anchor) && fs::read(format!("/proc/{p}/comm")).is_ok_and(|c| c == b"sleep\n"));
            if app.is_some() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        let app = app.expect("the anchor ran its app as a child");
        assert!(is_anchor(anchor));
        assert!(!is_anchor(app));
        assert_eq!(token_of(app), None, "env -i dropped the token, as Chromium's setproctitle does");
        assert_eq!(inherited_token(&Live, app, &|t| t == "livetok"), Some("livetok".into()));
        assert_eq!(inherited_token(&Live, app, &|t| t == "another"), None);
        assert_eq!(launch_pid(&Live, &pids_with_token("livetok"), &|p| is_anchor(p), &all_pids()), Some(app));
        let _ = std::process::Command::new("kill").arg(app.to_string()).status();
        let _ = sh.wait();
    }

    #[test]
    fn stat_reads_the_parent_too() {
        let stat = "123 (we ird) name) S 77 123 123 0 -1 4194560 100 0 0 0 1 2 0 0 20 0 1 0 987654 1000 100 18446744073709551615";
        assert_eq!(parse_stat(stat), Some(Stat { ppid: 77, start: 987654 }));
        assert_eq!(parse_stat("123 (x) S"), None);
    }

    #[test]
    fn tokens_are_random() {
        assert_ne!(random_token().unwrap(), random_token().unwrap());
        assert_eq!(random_token().unwrap().len(), 32);
    }
}
