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
//! `BANEYSPACES_TEST_OPS` set, **built with the `test-ops` feature**, may start it (and `cmd`, for the tests'
//! agent-peer check). A release build made without the feature ignores the variable.

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

/// What a test build may start besides the test window: only `cmd`, which the live test runs
/// `baneyspaces` from inside an agent's job with, to check that user operations are refused to it.
const TEST_EXTRA: &[&str] = &["cmd"];

/// The rule, as a pure function: with test ops off nothing starts; with them on, the test window and
/// the one extra program.
pub fn may_start_with(app: &str, test_ops: bool) -> bool {
    test_ops && (is_test_app(app) || TEST_EXTRA.contains(&base(app).as_str()))
}

/// Test ops are on only in a build made with the `test-ops` feature, and then only when the daemon
/// was started with `BANEYSPACES_TEST_OPS` set. A production build (no feature) ignores the variable.
pub fn test_ops_enabled() -> bool {
    cfg!(feature = "test-ops") && std::env::var_os("BANEYSPACES_TEST_OPS").is_some()
}

/// May the daemon start `app` for an agent?
pub fn may_start(app: &str) -> bool {
    may_start_with(app, test_ops_enabled())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn production_allows_nothing() {
        assert!(allowed().is_empty());
        for app in ["notepad", "explorer", "bs-testapp", r"C:\x\bs-testapp.exe", "cmd.exe", "powershell", ""] {
            assert!(!may_start_with(app, false), "{app}");
        }
    }

    #[test]
    fn test_ops_allow_the_test_window_and_cmd_and_nothing_else() {
        assert!(may_start_with(r"C:\bs\target\release\bs-testapp.exe", true));
        assert!(may_start_with("cmd.exe", true));
        for app in ["notepad", "explorer", "powershell", "msedge", "calc", "baneyspaces"] {
            assert!(!may_start_with(app, false) && !may_start_with(app, true), "{app}");
        }
    }

    #[test]
    fn a_build_without_the_feature_ignores_the_environment() {
        // Whatever BANEYSPACES_TEST_OPS holds, a build without the feature is not in test mode.
        if !cfg!(feature = "test-ops") {
            std::env::set_var("BANEYSPACES_TEST_OPS", "1");
            assert!(!test_ops_enabled());
            assert!(!may_start("bs-testapp"));
            std::env::remove_var("BANEYSPACES_TEST_OPS");
        }
    }

    #[test]
    fn the_test_window_is_found_by_name_or_path() {
        assert!(is_test_app("bs-testapp"));
        assert!(is_test_app(r"C:\bs\target\release\BS-TestApp.EXE"));
        assert!(!is_test_app("notepad"));
    }
}
