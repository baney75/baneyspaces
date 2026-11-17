//! The built command: `agent <verb> --help` prints that verb's usage and exits 0. On main,
//! `agent open --help` went to the daemon as an app named "--help". Help exits before any daemon
//! call, so this needs no daemon and reaches none.
use std::process::Command;

fn run(args: &[&str]) -> (i32, String) {
    let out = Command::new(env!("CARGO_BIN_EXE_baneyspaces"))
        .args(args)
        .env("XDG_STATE_HOME", env!("CARGO_TARGET_TMPDIR"))
        .env("XDG_RUNTIME_DIR", env!("CARGO_TARGET_TMPDIR"))
        .output()
        .expect("runs");
    (out.status.code().unwrap_or(-1), String::from_utf8_lossy(&out.stdout).into_owned())
}

#[test]
fn agent_verb_help_prints_usage_and_exits_zero() {
    for args in [&["agent", "open", "--help"][..], &["agent", "move", "-h"], &["agent", "run", "--help"], &["agent", "--help"]] {
        let (code, out) = run(args);
        assert_eq!(code, 0, "{args:?}: {out}");
        assert!(out.starts_with("usage: baneyspaces agent "), "{args:?}: {out}");
        assert!(!out.contains("\"ok\""), "no envelope, so nothing was sent: {args:?}: {out}");
    }
    let (_, open) = run(&["agent", "open", "--help"]);
    assert!(open.contains("agent open <app>") && !open.contains("agent bring"), "{open}");
}
