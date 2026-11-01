//! Where the daemon keeps things: `%LOCALAPPDATA%\BaneySpaces` (state.json, the action log).
//! The control channel is a named pipe named for the user (see ipc.rs).

use std::fs;
use std::io::Write;
use std::path::PathBuf;

#[derive(Clone, Debug)]
pub struct Paths {
    pub state: PathBuf,
}

impl Paths {
    pub fn from_env() -> Self {
        // BANEYSPACES_STATE_DIR lets a test use a throwaway directory.
        if let Ok(d) = std::env::var("BANEYSPACES_STATE_DIR") {
            return Self { state: PathBuf::from(d) };
        }
        let base = std::env::var("LOCALAPPDATA")
            .map(PathBuf::from)
            .or_else(|_| std::env::var("HOME").map(|h| PathBuf::from(h).join(".local/state")))
            .unwrap_or_else(|_| std::env::temp_dir());
        Self { state: base.join("BaneySpaces") }
    }

    pub fn ensure(&self) -> Result<(), String> {
        fs::create_dir_all(&self.state).map_err(|e| format!("cannot create {}: {e}", self.state.display()))?;
        // Temporary files a run that was killed mid-write left behind.
        if let Ok(rd) = fs::read_dir(&self.state) {
            for e in rd.flatten() {
                let n = e.file_name().to_string_lossy().to_string();
                if n.starts_with('.') && n.ends_with(".tmp") {
                    let _ = fs::remove_file(e.path());
                }
            }
        }
        Ok(())
    }

    pub fn read(&self, name: &str) -> Option<String> {
        fs::read_to_string(self.state.join(name)).ok()
    }

    /// Whole-file write that never leaves half a file for a reader: write a temporary file, flush it
    /// to disk, rename it over the target. The rename is retried with a short backoff because another
    /// process (antivirus, a backup, the indexer) may hold the target open for a moment. Returns why
    /// it failed, so a caller that must not go on without it (hiding a window) can refuse.
    pub fn write_atomic(&self, name: &str, text: &str) -> Result<(), String> {
        // A temporary name no other write shares (this process, this call): two writers can never truncate
        // each other's file or rename the wrong one.
        static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let tmp = self.state.join(format!(".{name}.{}.{n}.tmp", std::process::id()));
        let dst = self.state.join(name);
        fs::File::create(&tmp)
            .and_then(|mut f| f.write_all(text.as_bytes()).and_then(|_| f.sync_all()))
            .map_err(|e| format!("cannot write {}: {e}", tmp.display()))?;
        let mut last = String::new();
        for attempt in 0..6u64 {
            match fs::rename(&tmp, &dst) {
                Ok(()) => return Ok(()),
                Err(e) => last = e.to_string(),
            }
            std::thread::sleep(std::time::Duration::from_millis(10 * (1 << attempt.min(5))));
        }
        let _ = fs::remove_file(&tmp);
        Err(format!("cannot replace {}: {last}", dst.display()))
    }

    pub fn append(&self, name: &str, line: &str) {
        if let Ok(mut f) = fs::OpenOptions::new().append(true).create(true).open(self.state.join(name)) {
            let _ = writeln!(f, "{line}");
        }
    }

    /// The pipe the daemon listens on. Named for the user's SID, not the user name: the name is
    /// machine-wide, and two names can collapse into one once the odd characters are filtered out.
    pub fn pipe_name(&self) -> String {
        format!(r"\\.\pipe\baneyspaces-{}", user_key())
    }

    /// The name of the single-instance mutex (per user, per session).
    pub fn mutex_name(&self) -> String {
        format!(r"Local\BaneySpaces-{}", user_key())
    }
}

/// A short stable key for this user: the account SID on Windows.
pub fn user_key() -> String {
    #[cfg(windows)]
    {
        crate::winapi::user_sid_string().unwrap_or_else(|| "user".into())
    }
    #[cfg(not(windows))]
    {
        std::env::var("USER").unwrap_or_else(|_| "user".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn atomic_write_replaces_and_reads_back() {
        let dir = std::env::temp_dir().join(format!("bsw-paths-{}", std::process::id()));
        let p = Paths { state: dir.clone() };
        p.ensure().unwrap();
        assert!(p.write_atomic("a.json", "one").is_ok());
        assert!(p.write_atomic("a.json", "two").is_ok());
        assert_eq!(p.read("a.json").as_deref(), Some("two"));
        p.append("log", "x");
        p.append("log", "y");
        assert_eq!(p.read("log").as_deref(), Some("x\ny\n"));
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn concurrent_writes_never_corrupt_the_file() {
        let dir = std::env::temp_dir().join(format!("bsw-conc-{}", std::process::id()));
        let p = Paths { state: dir.clone() };
        p.ensure().unwrap();
        let threads: Vec<_> = (0..8)
            .map(|t| {
                let p = p.clone();
                std::thread::spawn(move || {
                    for i in 0..40 {
                        let body = format!("{{\"writer\":{t},\"i\":{i},\"pad\":\"{}\"}}", "x".repeat(2000));
                        let _ = p.write_atomic("c.json", &body);
                    }
                })
            })
            .collect();
        for t in threads {
            t.join().unwrap();
        }
        let text = p.read("c.json").unwrap();
        assert!(serde_json::from_str::<serde_json::Value>(&text).is_ok(), "the file is whole JSON, not a mix of two writes");
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn a_failed_write_says_so() {
        // The state directory does not exist: the write must fail, not pretend.
        let p = Paths { state: std::env::temp_dir().join(format!("bsw-missing-{}/nope", std::process::id())) };
        assert!(p.write_atomic("a.json", "x").is_err());
    }

    #[test]
    fn the_rename_is_retried_while_another_process_holds_the_file() {
        // A directory where the target should be makes every rename fail: the error comes back after the
        // retries, and no temporary file is left behind.
        let dir = std::env::temp_dir().join(format!("bsw-held-{}", std::process::id()));
        let p = Paths { state: dir.clone() };
        p.ensure().unwrap();
        fs::create_dir_all(dir.join("held.json").join("child")).unwrap();
        let t = std::time::Instant::now();
        assert!(p.write_atomic("held.json", "x").is_err());
        assert!(t.elapsed() >= std::time::Duration::from_millis(100), "it did not retry");
        let left: Vec<_> = fs::read_dir(&dir).unwrap().flatten().filter(|e| e.file_name().to_string_lossy().ends_with(".tmp")).collect();
        assert!(left.is_empty(), "a temporary file was left behind");
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn pipe_and_mutex_names_come_from_one_key() {
        let p = Paths { state: PathBuf::new() };
        assert!(p.pipe_name().starts_with(r"\\.\pipe\baneyspaces-"));
        assert!(p.mutex_name().starts_with(r"Local\BaneySpaces-"));
        assert!(p.pipe_name().ends_with(&user_key()));
    }
}
