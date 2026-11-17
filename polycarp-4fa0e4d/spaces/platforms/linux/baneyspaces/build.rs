//! Stamps the binary with the monorepo commit it was built from, as one line of text inside it:
//!
//!   polycarp-build|v1|<full sha>|<commit date, UTC>|<1 when tracked files had changes, else 0>|<version>|end|
//!
//! `baneyspaces --version` prints it, and `polycarp version` reads it from the file without running
//! the binary. Outside a git checkout the sha and the date are empty. POLYCARP_BUILD_COMMIT,
//! POLYCARP_BUILD_DATE and POLYCARP_BUILD_DIRTY override what git says (a build from a source archive).

use std::process::Command;

fn git(args: &[&str]) -> Option<String> {
    let out = Command::new("git")
        .args(args)
        .env("TZ", "UTC")
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

fn main() {
    for key in [
        "POLYCARP_BUILD_COMMIT",
        "POLYCARP_BUILD_DATE",
        "POLYCARP_BUILD_DIRTY",
    ] {
        println!("cargo:rerun-if-env-changed={key}");
    }
    // Naming any file turns off cargo's own "rerun when the package changes", so name the sources too.
    for path in [
        "build.rs",
        "src",
        "Cargo.toml",
        "../../../crates/baneyspaces-core",
    ] {
        println!("cargo:rerun-if-changed={path}");
    }
    // HEAD's log changes on every commit, checkout and reset; the index changes when files are staged.
    for file in ["logs/HEAD", "HEAD", "index"] {
        if let Some(path) = git(&["rev-parse", "--git-path", file]) {
            println!("cargo:rerun-if-changed={path}");
        }
    }
    let given = |key: &str| std::env::var(key).ok().filter(|v| !v.is_empty());
    let commit = given("POLYCARP_BUILD_COMMIT")
        .or_else(|| git(&["rev-parse", "HEAD"]))
        .filter(|c| c.len() >= 7 && c.chars().all(|ch| ch.is_ascii_hexdigit()))
        .unwrap_or_default();
    let date = given("POLYCARP_BUILD_DATE")
        .or_else(|| {
            git(&[
                "log",
                "-1",
                "--format=%cd",
                "--date=format-local:%Y-%m-%dT%H:%M:%SZ",
            ])
        })
        .filter(|d| !d.contains('|'))
        .unwrap_or_default();
    // Tracked files only: build output and the engine checkout are untracked or ignored.
    let dirty = match given("POLYCARP_BUILD_DIRTY") {
        Some(v) => v == "1" || v == "true",
        None => {
            git(&["status", "--porcelain", "--untracked-files=no"]).is_some_and(|s| !s.is_empty())
        }
    };
    let version = std::env::var("CARGO_PKG_VERSION").unwrap_or_default();
    println!(
        "cargo:rustc-env=POLYCARP_BUILD_STAMP=polycarp-build|v1|{commit}|{date}|{}|{version}|end|",
        if dirty { 1 } else { 0 }
    );
}
