//! `baneyspaces skill install|path|print`: the agent skill for Linux (`platforms/linux/skill/SKILL.md`),
//! built into the binary, so the installed skill always teaches the installed command.
//!
//! The text sits in the file between two markers, so `polycarp version` can read the skill this binary
//! would write without running it (cli/src/version.rs, `SKILL_BEGIN` and `SKILL_END`, must match).

use baneyspaces_core::envelope::{Envelope, Retry};
use serde_json::json;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

pub const BEGIN: &str = "polycarp-skill|v1|begin|\n";
pub const END: &str = "polycarp-skill|v1|end|";

/// The skill inside its markers. `concat!` takes literals only, so the markers are spelled out here
/// and a test checks they are `BEGIN` and `END`.
#[used]
static FRAMED: &str = concat!(
    "polycarp-skill|v1|begin|\n",
    include_str!("../../skill/SKILL.md"),
    "polycarp-skill|v1|end|"
);

/// The SKILL.md this binary writes.
pub fn text() -> &'static str {
    &FRAMED[BEGIN.len()..FRAMED.len() - END.len()]
}

/// Where the skill goes: Claude Code's skills folder always, and the shared `~/.agents/skills` folder
/// when this home has it or has Codex.
pub fn targets(home: &Path) -> Vec<PathBuf> {
    let mut t = vec![home.join(".claude/skills/baneyspaces/SKILL.md")];
    if home.join(".agents/skills").is_dir() || home.join(".codex").is_dir() {
        t.push(home.join(".agents/skills/baneyspaces/SKILL.md"));
    }
    t
}

/// "current" (the same text this binary writes), "differs" or "missing".
fn state(path: &Path) -> &'static str {
    match fs::read(path) {
        Ok(b) if b == text().as_bytes() => "current",
        Ok(_) => "differs",
        Err(_) => "missing",
    }
}

/// Writes the whole file next to its final place, then renames it there, so a reader never sees half a
/// skill.
fn write_atomic(path: &Path, text: &str) -> std::io::Result<()> {
    let dir = path
        .parent()
        .ok_or_else(|| std::io::Error::other("no parent folder"))?;
    fs::create_dir_all(dir)?;
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let tmp = dir.join(format!(".{name}.{}.tmp", std::process::id()));
    let written = fs::File::create(&tmp).and_then(|mut f| {
        f.write_all(text.as_bytes())?;
        f.sync_all()
    });
    match written.and_then(|()| fs::rename(&tmp, path)) {
        Ok(()) => Ok(()),
        Err(e) => {
            let _ = fs::remove_file(&tmp);
            Err(e)
        }
    }
}

/// HOME, which must be an absolute path.
fn home(home: Option<PathBuf>) -> Result<PathBuf, Envelope> {
    match home {
        Some(h) if h.is_absolute() => Ok(h),
        _ => Err(Envelope::err(
            "invalid_args",
            "HOME is not set to an absolute path",
            Retry::Never,
            "Run it as yourself, with HOME set.",
        )),
    }
}

/// `--path P`: that one file instead of the usual places. A path that names an `.md` file is that file;
/// anything else is a folder, made if it isn't there yet, with `SKILL.md` inside it.
fn chosen(path: &str) -> Result<PathBuf, Envelope> {
    let p = PathBuf::from(path);
    if !p.is_absolute() {
        return Err(Envelope::err(
            "invalid_args",
            format!("--path takes an absolute path, not {path:?}"),
            Retry::Never,
            "Example: baneyspaces skill install --path ~/.config/opencode/skills/baneyspaces",
        ));
    }
    let is_md = p.extension().is_some_and(|e| e.eq_ignore_ascii_case("md"));
    Ok(if is_md && !p.is_dir() { p } else { p.join("SKILL.md") })
}

fn usage() -> Envelope {
    Envelope::err(
        "invalid_args",
        "usage: skill install [--path P] | skill path | skill print",
        Retry::Never,
        "Run `baneyspaces help`.",
    )
}

pub fn install(targets: &[PathBuf]) -> Envelope {
    let mut written = vec![];
    for t in targets {
        let changed = state(t) != "current";
        if changed {
            if let Err(e) = write_atomic(t, text()) {
                return Envelope::err(
                    "internal",
                    format!("could not write {}: {e}", t.display()),
                    Retry::Safe,
                    "Check that the folder is yours and writable, then run it again.",
                )
                .with_data(json!({ "written": written }));
            }
        }
        written.push(json!({ "path": t.display().to_string(), "changed": changed }));
    }
    Envelope::ok(json!({ "skill": "baneyspaces", "written": written }))
}

pub fn paths(home: &Path) -> Envelope {
    let list: Vec<_> = targets(home)
        .iter()
        .map(|t| json!({ "path": t.display().to_string(), "state": state(t) }))
        .collect();
    Envelope::ok(json!({ "skill": "baneyspaces", "paths": list }))
}

/// What `skill ...` prints: an envelope, or for `print` the bare text, so a script can compare it.
pub enum Out {
    Envelope(Envelope),
    Text(&'static str),
}

/// `skill ...` from the command line, with `$HOME`.
pub fn run(args: &[String], home_dir: Option<PathBuf>) -> Out {
    let mut a = args.to_vec();
    let path = match a.iter().position(|x| x == "--path") {
        Some(i) if i + 1 < a.len() => {
            let p = a.remove(i + 1);
            a.remove(i);
            Some(p)
        }
        Some(_) => return Out::Envelope(usage()),
        None => None,
    };
    let words: Vec<&str> = a.iter().map(String::as_str).collect();
    let with_home = |f: &dyn Fn(&Path) -> Envelope| Out::Envelope(home(home_dir.clone()).map(|h| f(&h)).unwrap_or_else(|e| e));
    match (words.as_slice(), path.as_deref()) {
        (["print"], None) => Out::Text(text()),
        (["install"], Some(p)) => Out::Envelope(chosen(p).map(|t| install(&[t])).unwrap_or_else(|e| e)),
        (["install"], None) => with_home(&|h| install(&targets(h))),
        (["path"], None) => with_home(&paths),
        _ => Out::Envelope(usage()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    fn temp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("bs-skill-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn the_skill_is_the_file_inside_the_markers_polycarp_reads() {
        assert_eq!(text(), include_str!("../../skill/SKILL.md"));
        assert!(FRAMED.starts_with(BEGIN) && FRAMED.ends_with(END));
        // cli/src/version.rs looks for these exact markers.
        assert_eq!((BEGIN, END), ("polycarp-skill|v1|begin|\n", "polycarp-skill|v1|end|"));
        assert!(!text().contains(END), "the skill must not hold the end marker");
        assert!(text().starts_with("---\nname: baneyspaces\ndescription: "), "the front matter Claude Code reads");
    }

    /// Skill loaders parse the front matter as YAML. A plain value with `: ` or ` #` in it, or one that
    /// starts with a YAML indicator, is not the string it looks like, and the skill never loads.
    #[test]
    fn the_front_matter_is_plain_yaml_a_loader_reads_as_written() {
        let body = text().strip_prefix("---\n").expect("front matter");
        let (front, _) = body.split_once("\n---\n").expect("front matter ends");
        for line in front.lines() {
            let (key, value) = line.split_once(": ").unwrap_or_else(|| panic!("not `key: value`: {line}"));
            assert!(key.chars().all(|c| c.is_ascii_lowercase() || c == '-'), "key {key}");
            assert!(!value.contains(": ") && !value.contains(" #"), "{key} would not parse as one string");
            assert!(!value.starts_with(['"', '\'', '[', '{', '&', '*', '!', '|', '>', '%', '@', '`', '-', '?']), "{key}");
        }
    }

    #[test]
    fn the_shared_skills_folder_is_used_only_when_this_home_has_it_or_codex() {
        let h = temp("targets");
        assert_eq!(targets(&h), [h.join(".claude/skills/baneyspaces/SKILL.md")]);
        fs::create_dir_all(h.join(".codex")).unwrap();
        assert_eq!(targets(&h)[1], h.join(".agents/skills/baneyspaces/SKILL.md"));
        fs::remove_dir_all(h.join(".codex")).unwrap();
        fs::create_dir_all(h.join(".agents/skills")).unwrap();
        assert_eq!(targets(&h).len(), 2);
        let _ = fs::remove_dir_all(&h);
    }

    #[test]
    fn install_writes_whole_files_and_says_which_changed() {
        let h = temp("install");
        fs::create_dir_all(h.join(".codex")).unwrap();
        let t = targets(&h);
        let env = install(&t);
        assert!(env.ok, "{}", env.to_json());
        let written = &env.data.as_ref().unwrap()["written"];
        assert_eq!(written.as_array().unwrap().len(), 2);
        assert!(written.as_array().unwrap().iter().all(|w| w["changed"] == true));
        for p in &t {
            assert_eq!(fs::read_to_string(p).unwrap(), text());
            let left: Vec<_> = fs::read_dir(p.parent().unwrap()).unwrap().map(|e| e.unwrap().file_name()).collect();
            assert_eq!(left, ["SKILL.md"], "no temp file is left beside it");
        }
        // Again: nothing to change.
        let env = install(&t);
        assert!(env.data.as_ref().unwrap()["written"].as_array().unwrap().iter().all(|w| w["changed"] == false));
        assert!(paths(&h).data.unwrap()["paths"].as_array().unwrap().iter().all(|p| p["state"] == "current"));
        // An older or edited copy is replaced.
        fs::write(&t[0], "old skill").unwrap();
        assert_eq!(paths(&h).data.unwrap()["paths"][0]["state"], "differs");
        assert_eq!(install(&t).data.unwrap()["written"][0]["changed"], true);
        assert_eq!(fs::read_to_string(&t[0]).unwrap(), text());
        let _ = fs::remove_dir_all(&h);
    }

    #[test]
    fn a_chosen_path_must_be_absolute_and_a_folder_gets_skill_md() {
        let h = temp("chosen");
        assert_eq!(chosen("rel/SKILL.md").unwrap_err().error.unwrap().code, "invalid_args");
        assert_eq!(chosen(h.to_str().unwrap()).unwrap(), h.join("SKILL.md"));
        let f = h.join("x/SKILL.md");
        assert_eq!(chosen(f.to_str().unwrap()).unwrap(), f);
        // A folder that doesn't exist yet, as in the error's own example, is still a folder.
        let new = h.join("opencode/skills/baneyspaces");
        assert_eq!(chosen(new.to_str().unwrap()).unwrap(), new.join("SKILL.md"));
        // A folder that cannot be made: an error envelope, not a panic.
        fs::write(h.join("file"), "").unwrap();
        let env = install(&[h.join("file/SKILL.md")]);
        assert_eq!(env.error.unwrap().code, "internal");
        let _ = fs::remove_dir_all(&h);
    }

    fn v(words: &[&str]) -> Vec<String> {
        words.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn the_command_line_takes_install_path_and_print_only() {
        assert!(matches!(run(&v(&["print"]), None), Out::Text(t) if t == text()), "print needs no HOME");
        for bad in [&["install", "--path"][..], &["path", "--path", "/x"], &["remove"], &[]] {
            assert!(matches!(run(&v(bad), Some(PathBuf::from("/nowhere"))), Out::Envelope(e) if e.error.as_ref().unwrap().code == "invalid_args"), "{bad:?}");
        }
    }

    #[test]
    fn skill_install_with_a_temp_home_writes_what_print_and_path_report() {
        let h = temp("run");
        fs::create_dir_all(h.join(".codex")).unwrap();
        let Out::Envelope(env) = run(&v(&["install"]), Some(h.clone())) else { panic!() };
        assert!(env.ok, "{}", env.to_json());
        for p in [".claude/skills/baneyspaces/SKILL.md", ".agents/skills/baneyspaces/SKILL.md"] {
            assert_eq!(fs::read_to_string(h.join(p)).unwrap(), text(), "{p}");
        }
        let Out::Envelope(env) = run(&v(&["path"]), Some(h.clone())) else { panic!() };
        assert!(env.data.unwrap()["paths"].as_array().unwrap().iter().all(|p| p["state"] == "current"));
        let f = h.join("other/SKILL.md");
        let Out::Envelope(env) = run(&v(&["install", "--path", f.to_str().unwrap()]), None) else { panic!() };
        assert!(env.ok && fs::read_to_string(&f).unwrap() == text(), "--path needs no HOME: {}", env.to_json());
        for home in [None, Some(PathBuf::from("relative"))] {
            let Out::Envelope(env) = run(&v(&["install"]), home) else { panic!() };
            assert_eq!(env.error.unwrap().code, "invalid_args");
        }
        let _ = fs::remove_dir_all(&h);
    }

    /// `polycarp version` finds the skill in the file by its markers, so they must survive the build.
    #[test]
    fn the_framed_skill_is_in_the_built_file() {
        let exe = fs::read(std::env::current_exe().unwrap()).unwrap();
        assert!(exe.windows(FRAMED.len()).any(|w| w == FRAMED.as_bytes()));
    }

    /// The commands `HELP` lists: `agent open`, `skill install`, `switch`, ... and the ones it marks as
    /// not supported yet.
    fn usage_commands() -> (HashSet<String>, HashSet<String>) {
        let (mut known, mut unsupported) = (HashSet::new(), HashSet::new());
        for line in crate::HELP.lines().filter(|l| l.starts_with("  ") && !l.starts_with("   ")) {
            for (i, seg) in line.trim().split("  ").map(str::trim).filter(|s| !s.is_empty()).enumerate() {
                let w: Vec<&str> = seg.split_whitespace().collect();
                let (group, verbs) = match w.as_slice() {
                    [g @ ("agent" | "skill"), verbs, ..] => (format!("{g} "), *verbs),
                    [verbs, ..] if i == 0 => (String::new(), *verbs),
                    _ => continue,
                };
                for verb in verbs.split('|') {
                    known.insert(format!("{group}{verb}"));
                    if line.contains("not supported") {
                        unsupported.insert(format!("{group}{verb}"));
                    }
                }
            }
        }
        (known, unsupported)
    }

    fn usage_flags() -> HashSet<String> {
        crate::HELP
            .split(|c: char| c.is_whitespace() || "[]|(),:".contains(c))
            .filter(|w| w.starts_with('-'))
            .map(|w| w.split('=').next().unwrap().to_string())
            .collect()
    }

    /// "agent open" for `agent open foot`, "doctor" for `doctor`; None for words that are not a command.
    fn verb_of(words: &[&str]) -> Option<String> {
        match words {
            ["agent" | "skill", sub, ..] => Some(format!("{} {sub}", words[0])),
            [w, ..] => Some(w.to_string()),
            [] => None,
        }
    }

    /// Every command the skill names exists in this binary, so the skill cannot drift from it: each
    /// `baneyspaces ...` line in a code block is a command `HELP` lists, with flags `HELP` lists, that
    /// the command line accepts, and each inline `agent ...` names a listed verb.
    #[test]
    fn every_command_the_skill_names_is_in_the_binary() {
        let (known, unsupported) = usage_commands();
        let flags = usage_flags();
        assert!(known.contains("agent open") && known.contains("skill install") && known.contains("agent windows"), "{known:?}");
        assert!(unsupported.contains("agent press"), "{unsupported:?}");
        let (mut in_block, mut checked) = (false, 0);
        for line in text().lines() {
            if line.starts_with("```") {
                in_block = !in_block;
                continue;
            }
            if in_block {
                let Some(cmd) = line.strip_prefix("baneyspaces ") else {
                    panic!("a code block line that is not a baneyspaces command: {line:?}");
                };
                let words: Vec<&str> = cmd.split_whitespace().take_while(|w| *w != "#").collect();
                let verb = verb_of(&words).unwrap();
                assert!(known.contains(&verb) && !unsupported.contains(&verb), "the skill runs `{verb}`, which HELP does not offer: {line:?}");
                for f in words.iter().take_while(|w| **w != "--").filter(|w| w.starts_with('-')) {
                    assert!(flags.contains(f.split('=').next().unwrap()), "the skill uses {f}, which HELP does not list: {line:?}");
                }
                if !matches!(words[0], "doctor" | "skill" | "keys" | "help") {
                    let parsed = crate::request(v(&words));
                    assert!(parsed.is_ok(), "the command line refuses the skill's {line:?}: {}", parsed.unwrap_err().to_json());
                }
                checked += 1;
                continue;
            }
            for span in line.split('`').skip(1).step_by(2) {
                let words: Vec<&str> = span.trim_start_matches("baneyspaces ").split_whitespace().collect();
                if words.first() == Some(&"agent") {
                    let verb = verb_of(&words).unwrap();
                    assert!(known.contains(&verb), "the skill names `{span}`, which HELP does not list");
                    checked += 1;
                } else if span.starts_with("--") {
                    assert!(flags.contains(span.split(['=', ' ']).next().unwrap()), "the skill names {span}, which HELP does not list");
                }
            }
        }
        assert!(checked >= 25, "the check found only {checked} commands: is the parser still reading the skill?");
    }
}
