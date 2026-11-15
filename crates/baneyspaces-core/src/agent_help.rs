//! `baneyspaces agent <verb> --help` (or `-h`): that verb's lines from the platform's usage, exit 0,
//! and nothing sent to the daemon. Without it `agent open --help` asked the daemon to open an app
//! named "--help". Weak models reach for --help first, so every verb answers it the same way.

const WORDS: [&str; 2] = ["--help", "-h"];

/// Flags that take a value, so `agent find --name -h` searches for "-h".
const VALUED: [&str; 14] = [
    "--window", "--frame", "--dir", "--since", "--role", "--name", "--text", "--out", "--session", "--wait", "--app",
    "--button", "--item", "--log",
];

/// Verbs whose words after their first positional are data: the app's own arguments (`open`), the
/// command (`run`) or the text to enter (`type`, `set-value`, `select`).
const DATA_AFTER_FIRST: [&str; 5] = ["open", "run", "type", "set-value", "select"];

/// Whether `rest` (the words after `agent`) asks for help: `--help` or `-h` before any `--`, not as
/// a flag's value, and not where the verb's data has started (`agent run claude --help`).
pub fn asked(rest: &[String]) -> bool {
    let Some(verb) = rest.first() else { return false };
    if WORDS.contains(&verb.as_str()) {
        return true;
    }
    let data_after_first = DATA_AFTER_FIRST.contains(&verb.as_str());
    let mut previous: Option<&str> = None;
    for word in &rest[1..] {
        let w = word.as_str();
        if w == "--" {
            return false;
        }
        let is_value = previous.is_some_and(|p| VALUED.contains(&p));
        if !is_value {
            if WORDS.contains(&w) {
                return true;
            }
            if data_after_first && !w.starts_with('-') {
                return false;
            }
        }
        previous = Some(w);
    }
    false
}

/// The verb's help from `usage`: every line naming `agent <verb>` (lines holding several commands
/// come whole) with its continuation lines. No verb, or one `usage` doesn't name, gets every `agent`
/// line, so the reply is always the list of what exists.
pub fn text(verb: Option<&str>, usage: &str) -> String {
    let (mut all, mut mine) = (Vec::new(), Vec::new());
    let (mut in_agent, mut in_mine) = (false, false);
    for line in usage.lines() {
        let trimmed = line.trim_start();
        if line.len() - trimmed.len() >= 30 && !trimmed.is_empty() {
            if in_agent {
                all.push(line);
            }
            if in_mine {
                mine.push(line);
            }
            continue;
        }
        in_agent = trimmed.starts_with("agent ");
        in_mine = in_agent && verb.is_some_and(|v| names(trimmed).contains(&v));
        if in_agent {
            all.push(line);
        }
        if in_mine {
            mine.push(line);
        }
    }
    let (head, lines) = match verb {
        Some(v) if !mine.is_empty() => (v, mine),
        _ => ("<command>", all),
    };
    format!("usage: baneyspaces agent {head}\n{}\n", lines.join("\n"))
}

/// The verbs a usage line names: the first word after each `agent ` that opens a column, split on
/// `|` (`agent status|windows` names both; `agent arrange full|halves` names only arrange).
fn names(line: &str) -> Vec<&str> {
    line.split("  ")
        .map(str::trim)
        .filter_map(|seg| seg.strip_prefix("agent "))
        .filter_map(|cmd| cmd.split_whitespace().next())
        .flat_map(|first| first.split('|'))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(words: &[&str]) -> Vec<String> {
        words.iter().map(|s| s.to_string()).collect()
    }

    const USAGE: &str = "baneyspaces (test)

  ls                             windows by workspace
  agent status|windows           what is on the agent workspace
  agent open <app> [file...] [--new_window=false] [--wait S]
                                 start an allowlisted app on the agent workspace
                                 with files from the handoff folder only
  agent arrange full|halves|thirds|grid [window...]
                                 lay out the agent workspace's windows
  agent move --window W [--frame x,y,w,h]   an agent window onto the agent workspace
  agent move <window>            park one of your windows there
  agent get <ref> <property>     agent click <ref>      agent toggle <ref>
  agent-workspace show|hide|toggle   show the agent workspace (you only)
  doctor                         what works and what does not
";

    #[test]
    fn help_is_asked_for_on_every_verb_but_not_as_a_value_data_or_after_dash_dash() {
        for rest in [
            &["open", "--help"][..],
            &["open", "-h"],
            &["move", "--help"],
            &["move", "--window", "4", "-h"],
            &["run", "--dir", "/tmp", "--help"],
            &["find", "--window", "w", "--help"],
            &["status", "-h"],
            &["type", "--help"],
            &["--help"],
            &["-h"],
        ] {
            assert!(asked(&v(rest)), "{rest:?}");
        }
        for rest in [
            &["run", "--", "claude", "--help"][..],
            &["run", "claude", "--help"],
            &["open", "code", "--help"],
            &["type", "@s:e1", "--help"],
            &["type", "--", "-h"],
            &["set-value", "@s:e1", "-h"],
            &["find", "--name", "-h"],
            &["run", "--dir", "-h", "ls"],
            &["move", "notes"],
            &["status"],
            &[],
        ] {
            assert!(!asked(&v(rest)), "{rest:?}");
        }
    }

    #[test]
    fn each_verb_gets_its_own_lines() {
        let open = text(Some("open"), USAGE);
        assert!(open.starts_with("usage: baneyspaces agent open\n"), "{open}");
        assert!(open.contains("with files from the handoff folder only"), "continuation lines come along: {open}");
        assert!(!open.contains("arrange") && !open.contains("doctor"), "{open}");

        let mv = text(Some("move"), USAGE);
        assert!(mv.contains("agent move --window W") && mv.contains("agent move <window>"), "both moves: {mv}");
        assert!(!mv.contains("lay out"), "{mv}");

        assert!(text(Some("windows"), USAGE).contains("agent status|windows"));
        assert!(text(Some("click"), USAGE).contains("agent click <ref>"), "a second column names a verb too");
        assert!(text(Some("halves"), USAGE).starts_with("usage: baneyspaces agent <command>"), "an argument isn't a verb");

        let all = text(None, USAGE);
        assert!(all.starts_with("usage: baneyspaces agent <command>\n"), "{all}");
        assert!(all.contains("agent open") && all.contains("agent toggle"), "{all}");
        assert!(!all.contains("doctor") && !all.contains("agent-workspace") && !all.contains("  ls"), "{all}");
        assert_eq!(text(Some("nope"), USAGE), all);
    }
}
