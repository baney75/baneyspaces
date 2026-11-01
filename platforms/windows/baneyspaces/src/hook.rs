//! The two hooks the daemon runs, each on its own thread with its own message loop.
//!
//! * `WH_KEYBOARD_LL` swallows exactly the chords in `keys::bindings()` (Win+1-9, Win+Shift+1-9,
//!   Win+`). Explorer owns Win+number, so `RegisterHotKey` would fail. The callback only matches a
//!   table and posts to the worker; it never takes a lock, allocates a window, or waits, because
//!   Windows drops a low-level hook whose callback is slow.
//! * `SetWinEventHook` reports foreground changes and windows appearing, hiding and closing, so
//!   the worker reacts within milliseconds instead of waiting for its next poll.

use crate::keys::{lookup, Binding, Mods, VK_LWIN, VK_RWIN};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::mpsc::Sender;
use std::sync::OnceLock;
use windows_sys::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};
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
    Quit,
}

static TX: OnceLock<Sender<Msg>> = OnceLock::new();
static TABLE: OnceLock<Vec<Binding>> = OnceLock::new();
#[allow(clippy::declare_interior_mutable_const)]
const OFF: AtomicBool = AtomicBool::new(false);
static SWALLOWED: [AtomicBool; 256] = [OFF; 256];
/// Which modifier keys are down, kept from the hook's own events. `GetAsyncKeyState` can lag the
/// event being processed when two keys arrive in the same millisecond (a chord sent by a VM or a
/// remote session), so the hook counts the modifiers itself.
#[allow(clippy::declare_interior_mutable_const)]
static MOD_DOWN: [AtomicBool; 256] = [OFF; 256];
const MOD_KEYS: [u32; 11] = [0x5B, 0x5C, 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0x10, 0x11, 0x12];

fn mod_held(keys: &[u32]) -> bool {
    keys.iter().any(|k| MOD_DOWN[*k as usize].load(Ordering::Relaxed))
}

static KB_THREAD: AtomicU32 = AtomicU32::new(0);
static EV_THREAD: AtomicU32 = AtomicU32::new(0);

pub const EVENT_SYSTEM_FOREGROUND: u32 = 0x0003;
pub const EVENT_SYSTEM_MINIMIZEEND: u32 = 0x0017;
pub const EVENT_OBJECT_CREATE: u32 = 0x8000;
pub const EVENT_OBJECT_DESTROY: u32 = 0x8001;
pub const EVENT_OBJECT_SHOW: u32 = 0x8002;
pub const EVENT_OBJECT_HIDE: u32 = 0x8003;

fn held(vk: u16) -> bool {
    unsafe { GetAsyncKeyState(vk as i32) as u16 & 0x8000 != 0 }
}

unsafe extern "system" fn keyboard(code: i32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    if code == HC_ACTION as i32 {
        let k = &*(lp as *const KBDLLHOOKSTRUCT);
        let injected = k.flags & LLKHF_INJECTED != 0;
        let vk = k.vkCode;
        let down = wp as u32 == WM_KEYDOWN || wp as u32 == WM_SYSKEYDOWN;
        let up = wp as u32 == WM_KEYUP || wp as u32 == WM_SYSKEYUP;
        if vk < 256 && MOD_KEYS.contains(&vk) && (down || up) {
            MOD_DOWN[vk as usize].store(down, Ordering::Relaxed);
        }
        if !injected && vk < 256 {
            if down {
                if SWALLOWED[vk as usize].load(Ordering::Relaxed) {
                    return 1; // auto-repeat of a chord we took
                }
                let mods = Mods {
                    win: mod_held(&[VK_LWIN, VK_RWIN]),
                    shift: mod_held(&[0xA0, 0xA1, 0x10]),
                    alt: mod_held(&[0xA4, 0xA5, 0x12]),
                    ctrl: mod_held(&[0xA2, 0xA3, 0x11]),
                };
                if mods.win {
                    if let (Some(table), Some(tx)) = (TABLE.get(), TX.get()) {
                        if let Some(b) = lookup(table, vk, mods) {
                            SWALLOWED[vk as usize].store(true, Ordering::Relaxed);
                            let _ = tx.send(Msg::Chord(b.args.clone()));
                            return 1;
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

/// Starts both hook threads. Returns what could not be installed, if anything.
pub fn start(tx: Sender<Msg>, table: Vec<Binding>) -> Vec<String> {
    let _ = TX.set(tx);
    let _ = TABLE.set(table);
    let (ready_tx, ready_rx) = std::sync::mpsc::channel::<Result<(), String>>();
    let r1 = ready_tx.clone();
    std::thread::Builder::new().name("kbd-hook".into()).spawn(move || unsafe {
        KB_THREAD.store(GetCurrentThreadId(), Ordering::Relaxed);
        // Modifiers already down when the hook goes in.
        for k in MOD_KEYS {
            MOD_DOWN[k as usize].store(held(k as u16), Ordering::Relaxed);
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
        if a.is_null() || b.is_null() || c.is_null() {
            let _ = ready_tx.send(Err("SetWinEventHook failed: the daemon will rely on polling".into()));
        } else {
            let _ = ready_tx.send(Ok(()));
        }
        message_loop();
        for h in [a, b, c] {
            if !h.is_null() {
                UnhookWinEvent(h);
            }
        }
    }).ok();
    let mut problems = vec![];
    for _ in 0..2 {
        match ready_rx.recv_timeout(std::time::Duration::from_secs(5)) {
            Ok(Err(e)) => problems.push(e),
            Err(_) => problems.push("a hook thread did not start".into()),
            Ok(Ok(())) => {}
        }
    }
    problems
}

pub fn stop() {
    for t in [&KB_THREAD, &EV_THREAD] {
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
