//! Taking a window out of sight, and putting it back.
//!
//! Three ways, each used for one job (the reasons are in platforms/windows/README.md):
//!
//! - **Cloak** (your workspaces): the shell's own `IApplicationView::SetCloak`, reached through
//!   ImmersiveShell COM, the same call komorebi and GlazeWM make. The window stays exactly where it
//!   is, un-drawn, with no animation. The state lives in the shell, so it survives explorer.exe
//!   restarting, and the taskbar button stays put (no churn). The interfaces are undocumented, so
//!   if the call fails the window is **parked** instead.
//! - **Park** (the fallback): moved to (-32000, -32000), where Windows itself puts minimized windows.
//! - **Ghost** (the agent workspace only): fully transparent, click-through, unable to take focus,
//!   still on screen and *not* cloaked. The hands engine skips cloaked windows, so an agent's window
//!   must not be one; a ghost is invisible to you and still drivable.
//!
//! Callers write the window to `state.json` before calling anything here, and take it out after.

use crate::hidden::{Hidden, How};
use crate::winapi;
use std::ffi::c_void;
use windows_sys::core::GUID;
use windows_sys::Win32::Foundation::HWND;
use windows_sys::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_ALL, COINIT_MULTITHREADED};
use windows_sys::Win32::UI::WindowsAndMessaging::{WS_EX_LAYERED, WS_EX_NOACTIVATE, WS_EX_TRANSPARENT};

const CLSID_IMMERSIVE_SHELL: GUID = GUID::from_u128(0xC2F03A33_21F5_47FA_B4BB_156362A2F239);
const IID_ISERVICE_PROVIDER: GUID = GUID::from_u128(0x6D5140C1_7436_11CE_8034_00AA006009FA);
const IID_IAPPLICATION_VIEW_COLLECTION: GUID = GUID::from_u128(0x1841c6d7_4f9d_42c0_af41_8747538f10e5);
const CLSID_TASKBAR_LIST: GUID = GUID::from_u128(0x56FDF344_FD6D_11d0_958A_006097C9A090);
const IID_ITASKBAR_LIST: GUID = GUID::from_u128(0x56FDF342_FD6D_11d0_958A_006097C9A090);

/// A parked window sits here, as minimized windows do.
pub const PARK: i32 = -32000;

thread_local! {
    static COM: () = unsafe { CoInitializeEx(std::ptr::null(), COINIT_MULTITHREADED as u32); };
}

unsafe fn slot(obj: *mut c_void, index: usize) -> *const c_void {
    let table = *(obj as *const *const *const c_void);
    *table.add(index)
}

unsafe fn release(obj: *mut c_void) {
    if !obj.is_null() {
        let f: unsafe extern "system" fn(*mut c_void) -> u32 = std::mem::transmute(slot(obj, 2));
        f(obj);
    }
}

/// A live handle on the shell's view collection. Made fresh for each batch of work, never kept:
/// explorer.exe may restart between two of them.
pub struct Cloaker {
    provider: *mut c_void,
    collection: *mut c_void,
}

impl Cloaker {
    pub fn new() -> Result<Self, i32> {
        COM.with(|_| ());
        unsafe {
            let mut provider: *mut c_void = std::ptr::null_mut();
            let hr = CoCreateInstance(&CLSID_IMMERSIVE_SHELL, std::ptr::null_mut(), CLSCTX_ALL, &IID_ISERVICE_PROVIDER, &mut provider);
            if hr < 0 || provider.is_null() {
                return Err(hr);
            }
            let mut collection: *mut c_void = std::ptr::null_mut();
            let query: unsafe extern "system" fn(*mut c_void, *const GUID, *const GUID, *mut *mut c_void) -> i32 = std::mem::transmute(slot(provider, 3));
            let hr = query(provider, &IID_IAPPLICATION_VIEW_COLLECTION, &IID_IAPPLICATION_VIEW_COLLECTION, &mut collection);
            if hr < 0 || collection.is_null() {
                release(provider);
                return Err(hr);
            }
            Ok(Self { provider, collection })
        }
    }

    /// `IApplicationView::SetCloak(1, 2)` hides; `(1, 0)` shows.
    pub fn set(&self, h: HWND, on: bool) -> Result<(), i32> {
        unsafe {
            let mut view: *mut c_void = std::ptr::null_mut();
            let get: unsafe extern "system" fn(*mut c_void, HWND, *mut *mut c_void) -> i32 = std::mem::transmute(slot(self.collection, 6));
            let hr = get(self.collection, h, &mut view);
            if hr < 0 || view.is_null() {
                return Err(if hr < 0 { hr } else { -1 });
            }
            let set_cloak: unsafe extern "system" fn(*mut c_void, u32, i32) -> i32 = std::mem::transmute(slot(view, 12));
            let hr = set_cloak(view, 1, if on { 2 } else { 0 });
            release(view);
            if hr < 0 {
                Err(hr)
            } else {
                Ok(())
            }
        }
    }
}

impl Drop for Cloaker {
    fn drop(&mut self) {
        unsafe {
            release(self.collection);
            release(self.provider);
        }
    }
}

/// Best effort: take the window's button off the taskbar (agent windows only), or put it back.
pub fn taskbar_button(h: HWND, visible: bool) {
    COM.with(|_| ());
    unsafe {
        let mut list: *mut c_void = std::ptr::null_mut();
        if CoCreateInstance(&CLSID_TASKBAR_LIST, std::ptr::null_mut(), CLSCTX_ALL, &IID_ITASKBAR_LIST, &mut list) < 0 || list.is_null() {
            return;
        }
        let init: unsafe extern "system" fn(*mut c_void) -> i32 = std::mem::transmute(slot(list, 3));
        if init(list) >= 0 {
            let f: unsafe extern "system" fn(*mut c_void, HWND) -> i32 = std::mem::transmute(slot(list, if visible { 4 } else { 5 }));
            f(list, h);
        }
        release(list);
    }
}

/// Hides one of your windows. Returns how it was hidden: cloaked, or parked if the cloak was
/// refused or did not take. The caller has already recorded the window.
pub fn hide_user(h: HWND, cloaker: Option<&Cloaker>) -> How {
    if let Some(c) = cloaker {
        if c.set(h, true).is_ok() && winapi::cloaked(h) != 0 {
            return How::Cloak;
        }
    }
    winapi::set_pos(h, PARK, PARK);
    How::Park
}

/// Hides an agent's window: a ghost. Returns the extended style to put back.
pub fn ghost(h: HWND) -> i64 {
    let ex = winapi::ex_style(h);
    winapi::set_ex_style(h, ex | (WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE) as i64);
    winapi::set_layered_alpha(h, 0);
    taskbar_button(h, false);
    ex
}

/// Puts a window back as it was, whichever way it was hidden. Safe to call on a window that is
/// not hidden. Cloak and park are both undone, so an entry written just before a crash is fine
/// whichever of them had happened.
pub fn show(entry: &Hidden, cloaker: Option<&Cloaker>) {
    let h = winapi::hwnd(entry.hwnd);
    if !winapi::exists(h) {
        return;
    }
    match entry.how {
        How::Ghost => {
            winapi::set_layered_alpha(h, 255);
            if let Some(ex) = entry.ex_style {
                winapi::set_ex_style(h, ex);
            }
            taskbar_button(h, true);
        }
        How::Cloak | How::Park => {
            if let Some(c) = cloaker {
                let _ = c.set(h, false);
            }
            if let (Some(r), Some(now)) = (entry.rect, winapi::rect(h)) {
                if now[0] <= PARK + 2000 {
                    winapi::set_pos(h, r[0], r[1]);
                }
            }
        }
    }
}
