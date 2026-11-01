//! The control channel between the CLI and the daemon: one JSON request line, one envelope line,
//! over a named pipe that only this user can open.

use crate::paths::Paths;
use baneyspaces_core::envelope::{Envelope, Retry};
use serde_json::Value;

pub fn down() -> Envelope {
    Envelope::err("daemon_down", "baneyspaces daemon is not running", Retry::Safe, "Start it: baneyspaces daemon --background (the Startup shortcut runs it at sign-in).")
}

/// Opens the pipe. A daemon between two clients has no free instance for a moment (ERROR_PIPE_BUSY):
/// wait for one instead of calling that "not running". Opened for identification only, so a server
/// that is not ours cannot act as this user.
#[cfg(windows)]
fn open(paths: &Paths) -> Result<std::fs::File, Envelope> {
    use std::os::windows::fs::OpenOptionsExt;
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Foundation::{ERROR_FILE_NOT_FOUND, ERROR_PIPE_BUSY};
    use windows_sys::Win32::System::Pipes::{GetNamedPipeServerProcessId, WaitNamedPipeW};
    let name = paths.pipe_name();
    let wname: Vec<u16> = name.encode_utf16().chain(std::iter::once(0)).collect();
    const SECURITY_IDENTIFICATION: u32 = 0x0001_0000;
    for _ in 0..20 {
        match std::fs::OpenOptions::new().read(true).write(true).security_qos_flags(SECURITY_IDENTIFICATION).open(&name) {
            Ok(f) => {
                let mut pid = 0u32;
                let ok = unsafe { GetNamedPipeServerProcessId(f.as_raw_handle() as _, &mut pid) } != 0;
                if !ok || !crate::winapi::same_user(pid) {
                    return Err(Envelope::err("daemon_down", "the control pipe is served by another account, not by your daemon", Retry::Never, "Something else created the pipe first. Sign out and in, or ask an administrator."));
                }
                return Ok(f);
            }
            Err(e) if e.raw_os_error() == Some(ERROR_PIPE_BUSY as i32) => unsafe {
                WaitNamedPipeW(wname.as_ptr(), 500);
            },
            Err(e) if e.raw_os_error() == Some(ERROR_FILE_NOT_FOUND as i32) => return Err(down()),
            Err(_) => return Err(down()),
        }
    }
    Err(Envelope::err("timeout", "the daemon is busy and did not take the request", Retry::Safe, "Try again in a moment."))
}

/// Sends one request to the running daemon.
#[cfg(windows)]
pub fn call(paths: &Paths, req: &Value) -> Envelope {
    use std::io::{BufRead, BufReader, Write};
    let mut f = match open(paths) {
        Ok(f) => f,
        Err(e) => return e,
    };
    if writeln!(f, "{req}").is_err() || f.flush().is_err() {
        return down();
    }
    let mut out = String::new();
    if BufReader::new(f).read_line(&mut out).is_err() || out.trim().is_empty() {
        // The request went out and no answer came back: it may have been carried out.
        return Envelope::err("timeout", "the request was sent and the daemon did not answer", Retry::Never, "Check `baneyspaces state` before trying again: it may have been carried out.");
    }
    serde_json::from_str(&out).unwrap_or_else(|_| Envelope::err("internal", "unreadable reply from the daemon", Retry::Never, ""))
}

#[cfg(not(windows))]
pub fn call(_paths: &Paths, _req: &Value) -> Envelope {
    down()
}
