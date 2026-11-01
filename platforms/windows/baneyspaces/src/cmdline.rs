//! Building a Windows command line, and finding a program the way `CreateProcess` would.
//! Pure, so it is tested on any host.

use std::path::{Path, PathBuf};

/// One argument as `CommandLineToArgvW` reads it back: quoted when it has a space, tab or quote,
/// backslashes doubled before a quote.
pub fn quote_arg(a: &str) -> String {
    if !a.is_empty() && !a.contains([' ', '\t', '\n', '\u{b}', '"']) {
        return a.to_string();
    }
    let mut out = String::from("\"");
    let mut backslashes = 0usize;
    for c in a.chars() {
        match c {
            '\\' => backslashes += 1,
            '"' => {
                out.push_str(&"\\".repeat(backslashes * 2 + 1));
                out.push('"');
                backslashes = 0;
            }
            c => {
                out.push_str(&"\\".repeat(backslashes));
                backslashes = 0;
                out.push(c);
            }
        }
    }
    out.push_str(&"\\".repeat(backslashes * 2));
    out.push('"');
    out
}

pub fn command_line(exe: &Path, args: &[String]) -> String {
    let mut parts = vec![quote_arg(&exe.to_string_lossy())];
    parts.extend(args.iter().map(|a| quote_arg(a)));
    parts.join(" ")
}

/// `app` is a path, or a bare name looked up in `dirs` with `.exe` tried when it has no extension.
/// `is_file` is the filesystem check, passed in so the lookup can be tested.
pub fn find_program(app: &str, dirs: &[PathBuf], is_file: impl Fn(&Path) -> bool) -> Option<PathBuf> {
    let has_ext = Path::new(app).extension().is_some();
    let names: Vec<String> = if has_ext { vec![app.to_string()] } else { vec![format!("{app}.exe"), app.to_string()] };
    if app.contains(['\\', '/']) || Path::new(app).is_absolute() {
        return names.iter().map(PathBuf::from).find(|p| is_file(p));
    }
    dirs.iter().flat_map(|d| names.iter().map(move |n| d.join(n))).find(|p| is_file(p))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quoting_round_trips_the_hard_cases() {
        assert_eq!(quote_arg("plain"), "plain");
        assert_eq!(quote_arg(""), "\"\"");
        assert_eq!(quote_arg("a b"), "\"a b\"");
        assert_eq!(quote_arg(r#"say "hi""#), r#""say \"hi\"""#);
        assert_eq!(quote_arg(r"C:\dir with space\"), r#""C:\dir with space\\""#);
        assert_eq!(quote_arg(r"C:\no_space\x"), r"C:\no_space\x");
    }

    #[test]
    fn programs_are_found_by_name_or_path() {
        let dirs = vec![PathBuf::from("C:/Windows/System32"), PathBuf::from("C:/Windows")];
        let have = |p: &Path| p == Path::new("C:/Windows/System32/notepad.exe") || p == Path::new("C:/tools/x.exe");
        assert_eq!(find_program("notepad", &dirs, have), Some(PathBuf::from("C:/Windows/System32/notepad.exe")));
        assert_eq!(find_program("notepad.exe", &dirs, have), Some(PathBuf::from("C:/Windows/System32/notepad.exe")));
        assert_eq!(find_program("C:/tools/x.exe", &dirs, have), Some(PathBuf::from("C:/tools/x.exe")));
        assert_eq!(find_program("nothing", &dirs, have), None);
    }
}
