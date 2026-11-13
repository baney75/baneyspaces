//! Process identity from /proc: start time (so a reused pid is told apart), the launch token in a
//! process's environment, and liveness. Same-user only; nothing here needs privilege.

use std::fs;

/// Start time in clock ticks since boot (field 22 of /proc/<pid>/stat), or None if gone.
pub fn start_time(pid: u32) -> Option<u64> {
    let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    parse_start(&stat)
}

pub fn parse_start(stat: &str) -> Option<u64> {
    // The command name is in parentheses and may contain spaces and parentheses: split after the last ')'.
    let rest = &stat[stat.rfind(')')? + 1..];
    rest.split_whitespace().nth(19)?.parse().ok()
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
    let Ok(dir) = fs::read_dir("/proc") else {
        return vec![];
    };
    dir.flatten()
        .filter_map(|e| e.file_name().to_str()?.parse::<u32>().ok())
        .filter(|p| token_of(*p).as_deref() == Some(token))
        .collect()
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
    fn tokens_are_random() {
        assert_ne!(random_token().unwrap(), random_token().unwrap());
        assert_eq!(random_token().unwrap().len(), 32);
    }
}
