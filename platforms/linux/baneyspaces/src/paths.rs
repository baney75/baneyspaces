//! Where the daemon keeps things. State lives under `$XDG_STATE_HOME/baneyspaces`
//! (default `~/.local/state/baneyspaces`); the control socket under `$XDG_RUNTIME_DIR/baneyspaces`.

use std::fs;
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::PathBuf;

#[derive(Clone, Debug)]
pub struct Paths {
    pub state: PathBuf,
    pub run: PathBuf,
}

impl Paths {
    pub fn from_env() -> Self {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
        let state = std::env::var("XDG_STATE_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from(&home).join(".local/state"))
            .join("baneyspaces");
        let run = std::env::var("XDG_RUNTIME_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("/tmp"))
            .join("baneyspaces");
        Self { state, run }
    }

    pub fn ensure(&self) -> Result<(), String> {
        for d in [&self.state, &self.run] {
            fs::create_dir_all(d).map_err(|e| format!("cannot create {}: {e}", d.display()))?;
            fs::set_permissions(d, fs::Permissions::from_mode(0o700))
                .map_err(|e| format!("cannot protect {}: {e}", d.display()))?;
        }
        Ok(())
    }

    pub fn ctl_socket(&self) -> PathBuf {
        self.run.join("ctl.sock")
    }

    pub fn read(&self, name: &str) -> Option<String> {
        fs::read_to_string(self.state.join(name)).ok()
    }

    /// Whole-file write that never leaves half a file for a reader.
    pub fn write_atomic(&self, name: &str, text: &str) {
        let tmp = self.state.join(format!(".{name}.tmp"));
        let ok = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&tmp)
            .and_then(|mut f| f.write_all(text.as_bytes()))
            .is_ok();
        if ok {
            let _ = fs::rename(&tmp, self.state.join(name));
        }
    }

    pub fn append(&self, name: &str, line: &str) {
        if let Ok(mut f) = fs::OpenOptions::new()
            .append(true)
            .create(true)
            .mode(0o600)
            .open(self.state.join(name))
        {
            let _ = writeln!(f, "{line}");
        }
    }
}
