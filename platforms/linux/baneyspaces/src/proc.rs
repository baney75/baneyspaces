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

/// The process's executable name (`/proc/<pid>/comm`, at most 15 bytes), for matching device apps.
pub fn comm(pid: u32) -> Option<String> {
    std::fs::read_to_string(format!("/proc/{pid}/comm")).ok().map(|s| s.trim().to_string()).filter(|s| !s.is_empty())
}

/// The process's command line (`/proc/<pid>/cmdline`), at most 64 arguments: device apps are told apart
/// by it (the Android emulator's qemu is started with `-avd`, a plain QEMU never is).
pub fn cmdline(pid: u32) -> Vec<String> {
    let raw = std::fs::read(format!("/proc/{pid}/cmdline")).unwrap_or_default();
    raw.split(|b| *b == 0).filter(|a| !a.is_empty()).take(64).map(|a| String::from_utf8_lossy(a).into_owned()).collect()
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
    fn tokens_are_random() {
        assert_ne!(random_token().unwrap(), random_token().unwrap());
        assert_eq!(random_token().unwrap().len(), 32);
    }
}
