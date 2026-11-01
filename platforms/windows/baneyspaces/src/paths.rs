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
        fs::create_dir_all(&self.state).map_err(|e| format!("cannot create {}: {e}", self.state.display()))
    }

    pub fn read(&self, name: &str) -> Option<String> {
        fs::read_to_string(self.state.join(name)).ok()
    }

    /// Whole-file write that never leaves half a file for a reader.
    pub fn write_atomic(&self, name: &str, text: &str) -> bool {
        let tmp = self.state.join(format!(".{name}.tmp"));
        let ok = fs::File::create(&tmp)
            .and_then(|mut f| f.write_all(text.as_bytes()).and_then(|_| f.sync_all()))
            .is_ok();
        ok && fs::rename(&tmp, self.state.join(name)).is_ok()
    }

    pub fn append(&self, name: &str, line: &str) {
        if let Ok(mut f) = fs::OpenOptions::new().append(true).create(true).open(self.state.join(name)) {
            let _ = writeln!(f, "{line}");
        }
    }

    /// The pipe the daemon listens on. One per user name, so two users on one machine do not collide.
    pub fn pipe_name(&self) -> String {
        let user = std::env::var("USERNAME").unwrap_or_else(|_| "user".into());
        let clean: String = user.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-').collect();
        format!(r"\\.\pipe\baneyspaces-{clean}")
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
        assert!(p.write_atomic("a.json", "one"));
        assert!(p.write_atomic("a.json", "two"));
        assert_eq!(p.read("a.json").as_deref(), Some("two"));
        p.append("log", "x");
        p.append("log", "y");
        assert_eq!(p.read("log").as_deref(), Some("x\ny\n"));
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn pipe_name_has_no_path_separators_from_the_user_name() {
        let p = Paths { state: PathBuf::new() };
        assert!(p.pipe_name().starts_with(r"\\.\pipe\baneyspaces-"));
        assert!(!p.pipe_name()[9..].contains('\\'));
    }
}
