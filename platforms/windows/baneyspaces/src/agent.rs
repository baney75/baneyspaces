//! Starting an app for an agent as its own process, inside a job object.
//!
//! The job is how the agent line is drawn on Windows: a process BaneySpaces started, and anything
//! it starts in turn, is in the job, and a window whose process is in the job belongs to the agent.
//! (Linux does the same with a launch token in the process environment; Windows cannot read
//! another process's environment cheaply, but a job answers the question directly.) The job has
//! no kill-on-close limit: if the daemon dies the agent's app keeps running, and the next daemon
//! finds it again by pid and start time.
//!
//! The app starts minimized without taking focus (`SW_SHOWMINNOACTIVE`), so a window that honors
//! the show command is never drawn on your screen before the daemon hides it.

use crate::cmdline;
use crate::winapi;
use std::path::Path;
use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
use windows_sys::Win32::System::JobObjects::{AssignProcessToJobObject, CreateJobObjectW, IsProcessInJob};
use windows_sys::Win32::System::Threading::*;
use windows_sys::Win32::UI::WindowsAndMessaging::SW_SHOWMINNOACTIVE;

pub struct Job(pub HANDLE);
unsafe impl Send for Job {}

pub struct Spawned {
    pub pid: u32,
    pub start: u64,
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// A new, empty job for one agent launch.
pub fn new_job() -> Option<Job> {
    let h = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
    (!h.is_null()).then_some(Job(h))
}

/// Starts `exe` with `args`, suspended, puts it in `job`, then lets it run.
pub fn spawn(exe: &Path, args: &[String], cwd: Option<&str>, job: &Job, console: bool) -> Result<Spawned, String> {
    unsafe {
        let mut cmd = wide(&cmdline::command_line(exe, args));
        let app = wide(&exe.to_string_lossy());
        let dir = cwd.map(wide);
        let mut si: STARTUPINFOW = std::mem::zeroed();
        si.cb = std::mem::size_of::<STARTUPINFOW>() as u32;
        si.dwFlags = STARTF_USESHOWWINDOW;
        si.wShowWindow = SW_SHOWMINNOACTIVE as u16;
        let mut pi: PROCESS_INFORMATION = std::mem::zeroed();
        let flags = CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT | if console { CREATE_NEW_CONSOLE } else { 0 };
        let ok = CreateProcessW(
            app.as_ptr(),
            cmd.as_mut_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            0,
            flags,
            std::ptr::null(),
            dir.as_ref().map_or(std::ptr::null(), |d| d.as_ptr()),
            &si,
            &mut pi,
        );
        if ok == 0 {
            return Err(format!("CreateProcess failed (error {})", windows_sys::Win32::Foundation::GetLastError()));
        }
        // A job that cannot be joined (we are in a restrictive one) is not fatal: the pid is
        // still registered, only grandchildren would be missed.
        let _ = AssignProcessToJobObject(job.0, pi.hProcess);
        ResumeThread(pi.hThread);
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        Ok(Spawned { pid: pi.dwProcessId, start: winapi::process_start(pi.dwProcessId) })
    }
}

/// Is this process in `job`?
pub fn in_job(job: &Job, pid: u32) -> bool {
    unsafe {
        let p = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if p.is_null() {
            return false;
        }
        let mut inside = 0;
        let ok = IsProcessInJob(p, job.0, &mut inside) != 0;
        CloseHandle(p);
        ok && inside != 0
    }
}
