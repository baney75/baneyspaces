//! The hooks and the one hidden window the daemon runs, each on its own thread with its own message loop.
//!
//! * `WH_KEYBOARD_LL` swallows exactly the chords in `keys::bindings()` (Win+1-9, Win+Shift+1-9,
//!   Win+`). Explorer owns Win+number, so `RegisterHotKey` would fail. The callback only matches a
//!   table and posts to the worker; it takes no lock, allocates nothing, and never waits, because
//!   Windows drops a low-level hook whose callback is slow.
//! * `SetWinEventHook` reports foreground changes and windows appearing, hiding and closing, so
//!   the worker reacts within milliseconds instead of waiting for its next poll.
//! * A hidden top-level window (not a message-only one: only top-level windows are told about sign-out
//!   and about the taskbar being rebuilt) hears `WM_QUERYENDSESSION` and `WM_ENDSESSION` (the daemon has no
//!   console when it runs in the background, so no console event reaches it), session lock and unlock,
//!   and `TaskbarCreated` (explorer.exe restarted).

use crate::keys::{lookup, Binding, ModState, MOD_KEYS};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::mpsc::Sender;
use std::sync::OnceLock;
use windows_sys::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::System::RemoteDesktop::WTSRegisterSessionNotification;
use windows_sys::Win32::System::SystemInformation::GetTickCount;
use windows_sys::Win32::System::Threading::GetCurrentThreadId;
use windows_sys::Win32::UI::Accessibility::{SetWinEventHook, UnhookWinEvent, HWINEVENTHOOK};
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP};
use windows_sys::Win32::UI::WindowsAndMessaging::*;

/// What the hooks tell the worker.
#[derive(Debug)]
pub enum Msg {
    /// A swallowed chord: the CLI arguments it runs.
    Chord(Vec<String>),
    /// A window event: the WinEvent id and the window.
    Win { event: u32, hwnd: i64 },
    /// Look at every window again now: explorer.exe restarted, or the session was unlocked.
    Resync,
    Quit,
}

static TX: OnceLock<Sender<Msg>> = OnceLock::new();
static TABLE: OnceLock<Vec<Binding>> = OnceLock::new();
static ON_END: OnceLock<fn(EndSession)> = OnceLock::new();
#[allow(clippy::declare_interior_mutable_const)]
const OFF: AtomicBool = AtomicBool::new(false);
static SWALLOWED: [AtomicBool; 256] = [OFF; 256];
static MODS: ModState = ModState::new();
static KB_THREAD: AtomicU32 = AtomicU32::new(0);
static EV_THREAD: AtomicU32 = AtomicU32::new(0);
static SESSION_THREAD: AtomicU32 = AtomicU32::new(0);

/// Sign-out and shutdown, as the hidden window hears them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EndSession {
    /// `WM_QUERYENDSESSION`: apps are about to be asked to save; put windows back first.
    Query,
    /// `WM_ENDSESSION` with true: it is happening.
    Ending,
    /// `WM_ENDSESSION` with false: it was cancelled.
    Cancelled,
}

pub const EVENT_SYSTEM_FOREGROUND: u32 = 0x0003;
pub const EVENT_SYSTEM_DESKTOPSWITCH: u32 = 0x0020;
pub const EVENT_SYSTEM_MINIMIZEEND: u32 = 0x0017;
pub const EVENT_OBJECT_CREATE: u32 = 0x8000;
pub const EVENT_OBJECT_DESTROY: u32 = 0x8001;
pub const EVENT_OBJECT_SHOW: u32 = 0x8002;
pub const EVENT_OBJECT_HIDE: u32 = 0x8003;

fn held(vk: u32) -> bool {
    unsafe { GetAsyncKeyState(vk as i32) as u16 & 0x8000 != 0 }
}

/// Forget the modifiers and any chord being held: the input desktop changed or the session locked.
pub fn reset_keys() {
    MODS.reset();
    for s in SWALLOWED.iter() {
        s.store(false, Ordering::Relaxed);
    }
}

unsafe extern "system" fn keyboard(code: i32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    if code == HC_ACTION as i32 {
        let k = &*(lp as *const KBDLLHOOKSTRUCT);
        let injected = k.flags & LLKHF_INJECTED != 0;
        let vk = k.vkCode;
        let down = wp as u32 == WM_KEYDOWN || wp as u32 == WM_SYSKEYDOWN;
        let up = wp as u32 == WM_KEYUP || wp as u32 == WM_SYSKEYUP;
        if vk < 256 && (down || up) {
            MODS.event(vk, down, k.time);
        }
        if !injected && vk < 256 {
            if down {
                if SWALLOWED[vk as usize].load(Ordering::Relaxed) {
                    return 1; // auto-repeat of a chord we took
                }
                // A candidate chord: confirm the modifiers against the system's own state, so a key-up that
                // was missed (the secure desktop, an elevated window) cannot leave one stuck.
                if !MOD_KEYS.contains(&vk) {
                    let mods = MODS.mods(k.time, held);
                    if mods.win {
                        if let (Some(table), Some(tx)) = (TABLE.get(), TX.get()) {
                            if let Some(b) = lookup(table, vk, mods) {
                                SWALLOWED[vk as usize].store(true, Ordering::Relaxed);
                                let _ = tx.send(Msg::Chord(b.args.clone()));
                                return 1;
                            }
                        }
                    }
                }
            } else if up && SWALLOWED[vk as usize].swap(false, Ordering::Relaxed) {
                return 1;
            }
        }
    }
    CallNextHookEx(std::ptr::null_mut(), code, wp, lp)
}

unsafe extern "system" fn win_event(_h: HWINEVENTHOOK, event: u32, hwnd: HWND, id_object: i32, id_child: i32, _thread: u32, _time: u32) {
    if event == EVENT_SYSTEM_DESKTOPSWITCH {
        // To or from the secure desktop (Win+L, Ctrl+Alt+Del, a UAC prompt): key-ups may have been missed.
        reset_keys();
        if let Some(tx) = TX.get() {
            let _ = tx.send(Msg::Resync);
        }
        return;
    }
    if id_object == OBJID_WINDOW && id_child == 0 && !hwnd.is_null() {
        if let Some(tx) = TX.get() {
            let _ = tx.send(Msg::Win { event, hwnd: hwnd as isize as i64 });
        }
    }
}

fn message_loop() {
    unsafe {
        let mut msg: MSG = std::mem::zeroed();
        while GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) > 0 {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

const WM_WTSSESSION_CHANGE: u32 = 0x02B1;
const WTS_SESSION_LOCK: usize = 7;
const WTS_SESSION_UNLOCK: usize = 8;
static TASKBAR_CREATED: AtomicU32 = AtomicU32::new(0);

unsafe extern "system" fn session_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    let end = |e: EndSession| {
        if let Some(f) = ON_END.get() {
            f(e);
        }
    };
    match msg {
        WM_QUERYENDSESSION => {
            end(EndSession::Query);
            1
        }
        WM_ENDSESSION => {
            end(if wp != 0 { EndSession::Ending } else { EndSession::Cancelled });
            0
        }
        WM_WTSSESSION_CHANGE if wp == WTS_SESSION_LOCK || wp == WTS_SESSION_UNLOCK => {
            reset_keys();
            if let Some(tx) = TX.get() {
                let _ = tx.send(Msg::Resync);
            }
            0
        }
        m if m != 0 && m == TASKBAR_CREATED.load(Ordering::Relaxed) => {
            // explorer.exe restarted: the shell's cloak handles are new. Look at every window again.
            if let Some(tx) = TX.get() {
                let _ = tx.send(Msg::Resync);
            }
            0
        }
        _ => DefWindowProcW(hwnd, msg, wp, lp),
    }
}

/// Starts the hook threads and the hidden window. Returns what could not be installed, if anything.
pub fn start(tx: Sender<Msg>, table: Vec<Binding>, on_end: fn(EndSession)) -> Vec<String> {
    let _ = TX.set(tx);
    let _ = TABLE.set(table);
    let _ = ON_END.set(on_end);
    let (ready_tx, ready_rx) = std::sync::mpsc::channel::<Result<(), String>>();
    let r1 = ready_tx.clone();
    let r3 = ready_tx.clone();
    std::thread::Builder::new().name("kbd-hook".into()).spawn(move || unsafe {
        KB_THREAD.store(GetCurrentThreadId(), Ordering::Relaxed);
        // Modifiers already down when the hook goes in.
        let now = GetTickCount();
        for k in MOD_KEYS {
            if held(k) {
                MODS.assume_down(k, now);
            }
        }
        let h = SetWindowsHookExW(WH_KEYBOARD_LL, Some(keyboard), std::ptr::null_mut(), 0);
        if h.is_null() {
            let _ = r1.send(Err(format!("WH_KEYBOARD_LL not installed (error {})", windows_sys::Win32::Foundation::GetLastError())));
            return;
        }
        let _ = r1.send(Ok(()));
        message_loop();
        UnhookWindowsHookEx(h);
    }).ok();
    std::thread::Builder::new().name("win-events".into()).spawn(move || unsafe {
        EV_THREAD.store(GetCurrentThreadId(), Ordering::Relaxed);
        let flags = WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS;
        let a = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, std::ptr::null_mut(), Some(win_event), 0, 0, flags);
        let b = SetWinEventHook(EVENT_OBJECT_CREATE, EVENT_OBJECT_HIDE, std::ptr::null_mut(), Some(win_event), 0, 0, flags);
        let c = SetWinEventHook(EVENT_SYSTEM_MINIMIZEEND, EVENT_SYSTEM_MINIMIZEEND, std::ptr::null_mut(), Some(win_event), 0, 0, flags);
        let d = SetWinEventHook(EVENT_SYSTEM_DESKTOPSWITCH, EVENT_SYSTEM_DESKTOPSWITCH, std::ptr::null_mut(), Some(win_event), 0, 0, flags);
        if a.is_null() || b.is_null() || c.is_null() || d.is_null() {
            let _ = ready_tx.send(Err("SetWinEventHook failed: the daemon will rely on polling".into()));
        } else {
            let _ = ready_tx.send(Ok(()));
        }
        message_loop();
        for h in [a, b, c, d] {
            if !h.is_null() {
                UnhookWinEvent(h);
            }
        }
    }).ok();
    std::thread::Builder::new().name("session-window".into()).spawn(move || unsafe {
        SESSION_THREAD.store(GetCurrentThreadId(), Ordering::Relaxed);
        let hi = GetModuleHandleW(std::ptr::null());
        let class = wide("BaneySpacesSession");
        let wc = WNDCLASSW { style: 0, lpfnWndProc: Some(session_proc), cbClsExtra: 0, cbWndExtra: 0, hInstance: hi, hIcon: std::ptr::null_mut(), hCursor: std::ptr::null_mut(), hbrBackground: std::ptr::null_mut(), lpszMenuName: std::ptr::null(), lpszClassName: class.as_ptr() };
        RegisterClassW(&wc);
        TASKBAR_CREATED.store(RegisterWindowMessageW(wide("TaskbarCreated").as_ptr()), Ordering::Relaxed);
        // Never shown: a window with no WS_VISIBLE, but top-level, so it is sent the broadcasts.
        let title = wide("BaneySpaces");
        let hwnd = CreateWindowExW(0, class.as_ptr(), title.as_ptr(), WS_POPUP, 0, 0, 0, 0, std::ptr::null_mut(), std::ptr::null_mut(), hi, std::ptr::null());
        if hwnd.is_null() {
            let _ = r3.send(Err("the session window could not be created: sign-out will not put windows back".into()));
            return;
        }
        WTSRegisterSessionNotification(hwnd, 0);
        let _ = r3.send(Ok(()));
        message_loop();
    }).ok();
    let mut problems = vec![];
    for _ in 0..3 {
        match ready_rx.recv_timeout(std::time::Duration::from_secs(5)) {
            Ok(Err(e)) => problems.push(e),
            Err(_) => problems.push("a hook thread did not start".into()),
            Ok(Ok(())) => {}
        }
    }
    problems
}

pub fn stop() {
    for t in [&KB_THREAD, &EV_THREAD, &SESSION_THREAD] {
        let id = t.load(Ordering::Relaxed);
        if id != 0 {
            unsafe { PostThreadMessageW(id, WM_QUIT, 0, 0) };
        }
    }
}

/// Windows opens the Start menu when Win is released with nothing pressed in between. We took the
/// digit, so press and release an unassigned key (VK 0xE8) while Win is still down: Windows
/// then counts the chord as used. The hook ignores it because it is injected.
pub fn mask_start_menu() {
    let key = |flags| INPUT { r#type: INPUT_KEYBOARD, Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: 0xE8, wScan: 0, dwFlags: flags, time: 0, dwExtraInfo: 0 } } };
    let inputs = [key(0), key(KEYEVENTF_KEYUP)];
    unsafe { SendInput(2, inputs.as_ptr(), std::mem::size_of::<INPUT>() as i32) };
}
