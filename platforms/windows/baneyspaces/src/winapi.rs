//! Thin, safe-ish wrappers over the Win32 calls the daemon needs: listing windows, who owns them,
//! which display they are on, the foreground. Everything here is cheap and never blocks.

use std::ffi::c_void;
use windows_sys::Win32::Foundation::{CloseHandle, FILETIME, HWND, LPARAM, RECT, TRUE};
use windows_sys::Win32::Graphics::Dwm::{DwmGetWindowAttribute, DWMWA_CLOAKED};
use windows_sys::Win32::Graphics::Gdi::{EnumDisplayMonitors, GetMonitorInfoW, MonitorFromWindow, HDC, HMONITOR, MONITORINFO, MONITORINFOEXW, MONITOR_DEFAULTTONEAREST};
use windows_sys::Win32::System::SystemInformation::GetTickCount;
use windows_sys::Win32::System::Threading::{GetCurrentThreadId, GetProcessTimes, OpenProcess, QueryFullProcessImageNameW, PROCESS_QUERY_LIMITED_INFORMATION};
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{GetLastInputInfo, LASTINPUTINFO};
use windows_sys::Win32::UI::WindowsAndMessaging::*;

pub fn hwnd(id: i64) -> HWND {
    id as isize as HWND
}

pub fn id_of(h: HWND) -> i64 {
    h as isize as i64
}

/// The window id BaneySpaces and the engine share: `w-<hwnd in decimal>`.
pub fn window_name(id: i64) -> String {
    format!("w-{id}")
}

pub fn parse_window_name(s: &str) -> Option<i64> {
    s.strip_prefix("w-").unwrap_or(s).parse::<i64>().ok().filter(|n| *n != 0)
}

fn wide_to_string(buf: &[u16]) -> String {
    let n = buf.iter().position(|c| *c == 0).unwrap_or(buf.len());
    String::from_utf16_lossy(&buf[..n])
}

pub fn title(h: HWND) -> String {
    let mut buf = [0u16; 512];
    let n = unsafe { GetWindowTextW(h, buf.as_mut_ptr(), buf.len() as i32) };
    wide_to_string(&buf[..n.max(0) as usize])
}

pub fn class(h: HWND) -> String {
    let mut buf = [0u16; 256];
    let n = unsafe { GetClassNameW(h, buf.as_mut_ptr(), buf.len() as i32) };
    wide_to_string(&buf[..n.max(0) as usize])
}

pub fn exists(h: HWND) -> bool {
    unsafe { IsWindow(h) != 0 }
}

pub fn is_visible(h: HWND) -> bool {
    unsafe { IsWindowVisible(h) != 0 }
}

pub fn is_iconic(h: HWND) -> bool {
    unsafe { IsIconic(h) != 0 }
}

/// 0 when not cloaked; DWM_CLOAKED_APP 1, SHELL 2, INHERITED 4.
pub fn cloaked(h: HWND) -> u32 {
    let mut v: u32 = 0;
    let hr = unsafe { DwmGetWindowAttribute(h, DWMWA_CLOAKED as u32, &mut v as *mut u32 as *mut c_void, 4) };
    if hr < 0 {
        0
    } else {
        v
    }
}

pub fn pid_of(h: HWND) -> u32 {
    let mut pid = 0u32;
    unsafe { GetWindowThreadProcessId(h, &mut pid) };
    pid
}

pub fn rect(h: HWND) -> Option<[i32; 4]> {
    let mut r = RECT { left: 0, top: 0, right: 0, bottom: 0 };
    (unsafe { GetWindowRect(h, &mut r) } != 0).then_some([r.left, r.top, r.right, r.bottom])
}

pub fn ex_style(h: HWND) -> i64 {
    unsafe { GetWindowLongPtrW(h, GWL_EXSTYLE) as i64 }
}

pub fn set_ex_style(h: HWND, v: i64) {
    unsafe { SetWindowLongPtrW(h, GWL_EXSTYLE, v as isize) };
}

/// A Store (UWP) app lives in an `ApplicationFrameWindow` owned by ApplicationFrameHost; the app's
/// own process owns a `Windows.UI.Core.CoreWindow` child. This returns that process, else the frame's.
pub fn real_pid(h: HWND) -> u32 {
    let pid = pid_of(h);
    if class(h) != "ApplicationFrameWindow" {
        return pid;
    }
    struct Search {
        host: u32,
        found: u32,
    }
    unsafe extern "system" fn each(child: HWND, lp: LPARAM) -> i32 {
        let s = &mut *(lp as *mut Search);
        let p = pid_of(child);
        if p != s.host && p != 0 {
            s.found = p;
            return 0;
        }
        TRUE
    }
    let mut s = Search { host: pid, found: 0 };
    unsafe { EnumChildWindows(h, Some(each), &mut s as *mut Search as LPARAM) };
    if s.found != 0 {
        s.found
    } else {
        pid
    }
}

/// The process creation time as FILETIME ticks: with the pid, an identity that survives pid reuse.
pub fn process_start(pid: u32) -> u64 {
    unsafe {
        let p = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if p.is_null() {
            return 0;
        }
        let z = FILETIME { dwLowDateTime: 0, dwHighDateTime: 0 };
        let (mut c, mut e, mut k, mut u) = (z, z, z, z);
        let ok = GetProcessTimes(p, &mut c, &mut e, &mut k, &mut u) != 0;
        CloseHandle(p);
        if ok {
            ((c.dwHighDateTime as u64) << 32) | c.dwLowDateTime as u64
        } else {
            0
        }
    }
}

/// The program's file name without `.exe`, lower case: `notepad`.
pub fn process_name(pid: u32) -> String {
    unsafe {
        let p = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if p.is_null() {
            return String::new();
        }
        let mut buf = [0u16; 1024];
        let mut n = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(p, 0, buf.as_mut_ptr(), &mut n) != 0;
        CloseHandle(p);
        if !ok {
            return String::new();
        }
        let path = String::from_utf16_lossy(&buf[..n as usize]);
        let file = path.rsplit(['\\', '/']).next().unwrap_or("").to_lowercase();
        file.strip_suffix(".exe").unwrap_or(&file).to_string()
    }
}

pub fn alive(pid: u32, start: u64) -> bool {
    let s = process_start(pid);
    s != 0 && (start == 0 || s == start)
}

pub fn list_top_level() -> Vec<HWND> {
    unsafe extern "system" fn each(h: HWND, lp: LPARAM) -> i32 {
        (*(lp as *mut Vec<HWND>)).push(h);
        TRUE
    }
    let mut v: Vec<HWND> = vec![];
    unsafe { EnumWindows(Some(each), &mut v as *mut Vec<HWND> as LPARAM) };
    v
}

/// Windows the shell and system own, which are never a user's to move.
const SHELL_CLASSES: &[&str] = &[
    "Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "Windows.UI.Core.CoreWindow", "XamlExplorerHostIslandWindow",
    "TopLevelWindowForOverflowXamlIsland", "NotifyIconOverflowWindow", "ForegroundStaging", "MultitaskingViewFrame", "TaskListThumbnailWnd",
];

/// Is this a window a person would call an app window? Visible (or hidden by us), titled, not a
/// tool window or a popup the shell draws, not owned by another window, not cloaked by someone else.
pub fn is_manageable(h: HWND, hidden_by_us: bool, our_pid: u32) -> bool {
    if h.is_null() || !exists(h) {
        return false;
    }
    if !hidden_by_us && (!is_visible(h) || cloaked(h) != 0) {
        return false;
    }
    let ex = ex_style(h);
    let style = unsafe { GetWindowLongPtrW(h, GWL_STYLE) as u32 };
    // A ghosted agent window carries WS_EX_NOACTIVATE and a layered alpha of 0 on purpose.
    let ghosted = hidden_by_us;
    if ex & WS_EX_TOOLWINDOW as i64 != 0 && ex & WS_EX_APPWINDOW as i64 == 0 {
        return false;
    }
    if !ghosted && ex & WS_EX_NOACTIVATE as i64 != 0 && ex & WS_EX_APPWINDOW as i64 == 0 {
        return false;
    }
    if style & WS_CHILD != 0 {
        return false;
    }
    if unsafe { !GetWindow(h, GW_OWNER).is_null() } && ex & WS_EX_APPWINDOW as i64 == 0 {
        return false;
    }
    if title(h).is_empty() {
        return false;
    }
    if SHELL_CLASSES.contains(&class(h).as_str()) {
        return false;
    }
    let pid = pid_of(h);
    pid != 0 && pid != our_pid
}

#[derive(Clone, Debug)]
pub struct Monitor {
    pub name: String,
    pub rect: [i32; 4],
    pub primary: bool,
}

/// Displays, primary first (slot 0), then by position.
pub fn monitors() -> Vec<Monitor> {
    unsafe extern "system" fn each(m: HMONITOR, _dc: HDC, _r: *mut RECT, lp: LPARAM) -> i32 {
        let mut info: MONITORINFOEXW = std::mem::zeroed();
        info.monitorInfo.cbSize = std::mem::size_of::<MONITORINFOEXW>() as u32;
        if GetMonitorInfoW(m, &mut info as *mut MONITORINFOEXW as *mut MONITORINFO) != 0 {
            let r = info.monitorInfo.rcWork;
            (*(lp as *mut Vec<Monitor>)).push(Monitor {
                name: wide_to_string(&info.szDevice),
                rect: [r.left, r.top, r.right, r.bottom],
                primary: info.monitorInfo.dwFlags & 1 != 0,
            });
        }
        TRUE
    }
    let mut v: Vec<Monitor> = vec![];
    unsafe { EnumDisplayMonitors(std::ptr::null_mut(), std::ptr::null(), Some(each), &mut v as *mut Vec<Monitor> as LPARAM) };
    v.sort_by_key(|m| (!m.primary, m.rect[0], m.rect[1]));
    v
}

pub fn monitor_name_of(h: HWND) -> Option<String> {
    unsafe {
        let m = MonitorFromWindow(h, MONITOR_DEFAULTTONEAREST);
        let mut info: MONITORINFOEXW = std::mem::zeroed();
        info.monitorInfo.cbSize = std::mem::size_of::<MONITORINFOEXW>() as u32;
        (GetMonitorInfoW(m, &mut info as *mut MONITORINFOEXW as *mut MONITORINFO) != 0).then(|| wide_to_string(&info.szDevice))
    }
}

pub fn foreground() -> HWND {
    unsafe { GetForegroundWindow() }
}

/// Puts `h` in front. Windows only lets the process that got the last input do this, so a
/// daemon acting on a key or a CLI call attaches to the current foreground thread's input first.
pub fn set_foreground(h: HWND) -> bool {
    unsafe {
        if h.is_null() {
            return false;
        }
        let fg = GetForegroundWindow();
        let me = GetCurrentThreadId();
        let fg_thread = if fg.is_null() { 0 } else { GetWindowThreadProcessId(fg, std::ptr::null_mut()) };
        let attached = fg_thread != 0 && fg_thread != me && windows_sys::Win32::System::Threading::AttachThreadInput(me, fg_thread, 1) != 0;
        let ok = SetForegroundWindow(h) != 0;
        if attached {
            windows_sys::Win32::System::Threading::AttachThreadInput(me, fg_thread, 0);
        }
        ok
    }
}

pub fn shell_window() -> HWND {
    unsafe { GetShellWindow() }
}

/// Milliseconds since the last keyboard or mouse input anywhere.
pub fn idle_ms() -> u32 {
    unsafe {
        let mut li = LASTINPUTINFO { cbSize: std::mem::size_of::<LASTINPUTINFO>() as u32, dwTime: 0 };
        if GetLastInputInfo(&mut li) == 0 {
            return u32::MAX;
        }
        GetTickCount().wrapping_sub(li.dwTime)
    }
}

pub fn set_pos(h: HWND, x: i32, y: i32) {
    unsafe { SetWindowPos(h, std::ptr::null_mut(), x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE) };
}

pub fn set_layered_alpha(h: HWND, alpha: u8) {
    unsafe { SetLayeredWindowAttributes(h, 0, alpha, LWA_ALPHA) };
}

pub fn restore_minimized_no_activate(h: HWND) {
    unsafe { ShowWindow(h, SW_SHOWNOACTIVATE) };
}


#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn window_names_round_trip() {
        assert_eq!(window_name(197330), "w-197330");
        assert_eq!(parse_window_name("w-197330"), Some(197330));
        assert_eq!(parse_window_name("197330"), Some(197330));
        assert_eq!(parse_window_name("w-"), None);
        assert_eq!(parse_window_name("w-0"), None);
        assert_eq!(parse_window_name("notepad"), None);
    }
}
