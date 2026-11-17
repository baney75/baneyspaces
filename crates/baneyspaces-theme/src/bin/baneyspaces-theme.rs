//! `baneyspaces-theme theme ...` runs what `baneyspaces theme ...` runs, and `baneyspaces-theme doctor`
//! prints the Omarchy line `baneyspaces doctor` reports. For the tests; see Cargo.toml.
use std::ffi::OsString;

fn main() {
    let args: Vec<OsString> = std::env::args_os().skip(1).collect();
    let code = match args.first().and_then(|a| a.to_str()) {
        Some("theme") => baneyspaces_theme::run(&args[1..]),
        Some("doctor") => {
            if let Some(line) = baneyspaces_theme::doctor_line() {
                println!("{line}");
            }
            0
        }
        _ => {
            eprintln!("usage: baneyspaces-theme theme <command> ... | doctor");
            2
        }
    };
    std::process::exit(code);
}
