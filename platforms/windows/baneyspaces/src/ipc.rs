//! The control channel between the CLI and the daemon: one JSON request line, one envelope line,
//! over a named pipe that only this user can open.

use crate::paths::Paths;
use baneyspaces_core::envelope::{Envelope, Retry};
use serde_json::Value;

pub fn down() -> Envelope {
    Envelope::err("daemon_down", "baneyspaces daemon is not running", Retry::Safe, "Start it: baneyspaces daemon (the Startup shortcut runs it at sign-in).")
}

/// Sends one request to the running daemon.
#[cfg(windows)]
pub fn call(paths: &Paths, req: &Value) -> Envelope {
    use std::io::{BufRead, BufReader, Write};
    let Ok(mut f) = std::fs::OpenOptions::new().read(true).write(true).open(paths.pipe_name()) else {
        return down();
    };
    if writeln!(f, "{req}").is_err() || f.flush().is_err() {
        return down();
    }
    let mut out = String::new();
    if BufReader::new(f).read_line(&mut out).is_err() || out.trim().is_empty() {
        return down();
    }
    serde_json::from_str(&out).unwrap_or_else(|_| Envelope::err("internal", "unreadable reply from the daemon", Retry::Never, ""))
}

#[cfg(not(windows))]
pub fn call(_paths: &Paths, _req: &Value) -> Envelope {
    down()
}
