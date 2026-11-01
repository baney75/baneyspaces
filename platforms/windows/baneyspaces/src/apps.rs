//! Which apps an agent may start on Windows: none, until there is a sandbox.
//!
//! The line is drawn by process: an agent drives only a process BaneySpaces started for it as a new
//! instance. On Windows no app is known to be safe to hand an agent:
//!
//! * Notepad forwards a second launch into a copy of yours that is already running (seen live), and
//!   restores your unsaved tabs into a new process, so an agent's Notepad can show text you never saved.
//! * Explorer, the Store apps and browsers forward to a running copy too.
//!
//! So in production `agent open` is refused for every app with `needs_sandbox`, before launch. A real
//! answer is a Windows sandbox phase (Windows Sandbox or a Hyper-V VM) where the agent's apps run
//! apart from your session; that is a follow-up, not part 1.
//!
//! The live tests need something to drive. `bs-testapp` (platforms/windows/testapp) is a window with a
//! text box, its own process every time, nothing remembered. A daemon started with
//! `BANEYSPACES_TEST_OPS` set may start it (and, for the tests' agent-peer check, any program).
//! A normal daemon never does.

/// The test window's program name.
const TEST_APP: &str = "bs-testapp";

fn base(app: &str) -> String {
    let name = app.rsplit(['\\', '/']).next().unwrap_or(app).to_lowercase();
    name.strip_suffix(".exe").map(String::from).unwrap_or(name)
}

/// The apps an agent may start in production: none.
pub fn allowed() -> Vec<&'static str> {
    vec![]
}

/// Is this program the bundled test window?
pub fn is_test_app(app: &str) -> bool {
    base(app) == TEST_APP
}

/// May the daemon start `app` for an agent? Only a test daemon may, and only when it says so.
pub fn may_start(app: &str) -> bool {
    test_ops() && (is_test_app(app) || any_for_tests())
}

fn test_ops() -> bool {
    std::env::var_os("BANEYSPACES_TEST_OPS").is_some()
}

/// The live test runs `baneyspaces` from inside an agent's job to check that user operations are
/// refused to it; that needs a launch of an arbitrary program (cmd.exe), so a test daemon allows any.
fn any_for_tests() -> bool {
    test_ops()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn production_allows_nothing() {
        assert!(allowed().is_empty());
        // Without BANEYSPACES_TEST_OPS nothing may start, not even the test window.
        if std::env::var_os("BANEYSPACES_TEST_OPS").is_none() {
            for app in ["notepad", "explorer", "bs-testapp", r"C:\x\bs-testapp.exe", "cmd.exe", ""] {
                assert!(!may_start(app), "{app}");
            }
        }
    }

    #[test]
    fn the_test_window_is_found_by_name_or_path() {
        assert!(is_test_app("bs-testapp"));
        assert!(is_test_app(r"C:\bs\target\release\BS-TestApp.EXE"));
        assert!(!is_test_app("notepad"));
    }
}
