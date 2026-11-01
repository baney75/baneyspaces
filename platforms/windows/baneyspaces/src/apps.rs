//! Which apps an agent may start. Deny by default (spec/workspaces.md, "agent scope").
//!
//! The line is drawn by process: an agent drives only a process BaneySpaces started for it as a new
//! instance. An app that might forward to a copy you already run (a Store app, Explorer, a browser)
//! can open the agent's request in YOUR process, and an agent's copy can become the instance your
//! later launches forward to. So an app is started for an agent only if it is listed here, each
//! one checked live to run as its own process while a copy of yours is open. Anything else is refused
//! before launch with `needs_sandbox`.

/// Verified in the Windows 11 VM with Notepad windows of the user's already open: the agent's launch
/// was a new process (a different pid) with a window of its own, and the user's windows were untouched.
const SEPARATE: &[&str] = &["notepad"];

fn base(app: &str) -> String {
    let name = app.rsplit(['\\', '/']).next().unwrap_or(app).to_lowercase();
    name.strip_suffix(".exe").map(String::from).unwrap_or(name)
}

pub fn allowed() -> Vec<&'static str> {
    SEPARATE.to_vec()
}

/// Is this app (a name or a path) on the list?
pub fn known(app: &str) -> bool {
    SEPARATE.contains(&base(app).as_str())
}

/// A daemon started with BANEYSPACES_TEST_OPS set (the live test only) may start any program, so the
/// test can run baneyspaces from inside an agent's job. A normal daemon never does.
pub fn may_start(app: &str) -> bool {
    known(app) || std::env::var_os("BANEYSPACES_TEST_OPS").is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_listed_apps_may_start() {
        assert!(known("notepad"));
        assert!(known("Notepad.EXE"));
        assert!(known(r"C:\Windows\System32\notepad.exe"));
        for unlisted in ["explorer", "calc", "msedge", "cmd", "powershell", "mspaint", "baneyspaces", ""] {
            assert!(!known(unlisted), "{unlisted}");
        }
    }
}
