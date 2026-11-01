#![cfg_attr(windows, windows_subsystem = "windows")]
//! `bs-testapp`: one window with one text box, for the BaneySpaces live tests. It exists because the
//! apps Windows ships either forward a second launch into a running copy (Notepad) or restore
//! the user's unsaved text (Notepad), so none is safe to hand an agent. This one is its own
//! process every time, keeps nothing between runs, and its text box is a plain Win32 EDIT control, which
//! UI Automation reads and sets through the ValuePattern.
//!
//! A second control, a button named "Open dialog", opens a MessageBox owned by the window: the live test
//! uses it to check that a dialog an agent's app opens is hidden too.
//!
//! It is only ever started by the live tests (`BANEYSPACES_TEST_OPS`); the daemon refuses to start
//! it otherwise. The first `ShowWindow` honors the launcher's show command, so a launch with
//! `SW_SHOWMINNOACTIVE` starts minimized and never draws.

#[cfg(windows)]
fn main() {
    use windows_sys::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};
    use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows_sys::Win32::UI::WindowsAndMessaging::*;

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }

    unsafe extern "system" fn proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
        match msg {
            WM_CREATE => {
                let hi = GetModuleHandleW(std::ptr::null());
                let edit = wide("EDIT");
                let empty = wide("");
                CreateWindowExW(
                    WS_EX_CLIENTEDGE,
                    edit.as_ptr(),
                    empty.as_ptr(),
                    WS_CHILD | WS_VISIBLE | WS_VSCROLL | ES_MULTILINE as u32 | ES_AUTOVSCROLL as u32,
                    0,
                    0,
                    400,
                    208,
                    hwnd,
                    1 as _,
                    hi,
                    std::ptr::null(),
                );
                let button = wide("BUTTON");
                let label = wide("Open dialog");
                CreateWindowExW(0, button.as_ptr(), label.as_ptr(), WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON as u32, 4, 212, 120, 26, hwnd, 2 as _, hi, std::ptr::null());
                0
            }
            WM_COMMAND => {
                if (wp & 0xFFFF) == 2 {
                    // Posted, not run here: a UI Automation click on the button returns at once instead of
                    // waiting for a modal box to close.
                    PostMessageW(hwnd, WM_APP, 0, 0);
                }
                0
            }
            WM_APP => {
                let text = wide("A dialog opened by the test app.");
                let caption = wide("Test dialog");
                MessageBoxW(hwnd, text.as_ptr(), caption.as_ptr(), MB_OK);
                0
            }
            WM_SIZE => {
                let (w, h) = ((lp & 0xFFFF) as i32, ((lp >> 16) & 0xFFFF) as i32);
                // The first child created is the last in z-order: find them by id.
                let edit = GetDlgItem(hwnd, 1);
                let button = GetDlgItem(hwnd, 2);
                if !edit.is_null() {
                    MoveWindow(edit, 0, 0, w, (h - 32).max(0), 1);
                }
                if !button.is_null() {
                    MoveWindow(button, 4, (h - 30).max(0), 120, 26, 1);
                }
                0
            }
            WM_DESTROY => {
                PostQuitMessage(0);
                0
            }
            _ => DefWindowProcW(hwnd, msg, wp, lp),
        }
    }

    unsafe {
        let hi = GetModuleHandleW(std::ptr::null());
        let class = wide("BaneySpacesTestApp");
        let wc = WNDCLASSW {
            style: 0,
            lpfnWndProc: Some(proc),
            cbClsExtra: 0,
            cbWndExtra: 0,
            hInstance: hi,
            hIcon: std::ptr::null_mut(),
            hCursor: LoadCursorW(std::ptr::null_mut(), IDC_ARROW),
            hbrBackground: 6 as _, // COLOR_WINDOW + 1
            lpszMenuName: std::ptr::null(),
            lpszClassName: class.as_ptr(),
        };
        RegisterClassW(&wc);
        let title = wide("BaneySpaces test app");
        let hwnd = CreateWindowExW(0, class.as_ptr(), title.as_ptr(), WS_OVERLAPPEDWINDOW, 140, 140, 420, 280, std::ptr::null_mut(), std::ptr::null_mut(), hi, std::ptr::null());
        ShowWindow(hwnd, SW_SHOWDEFAULT);
        let mut msg: MSG = std::mem::zeroed();
        while GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) > 0 {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
}

#[cfg(not(windows))]
fn main() {
    eprintln!("bs-testapp is a Windows test window");
}
