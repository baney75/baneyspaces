//! What a key does (`spec/config.md` Keys): any `baneyspaces` CLI command line, plus `exec <command>`,
//! `mode <name>` and `none`. The CLI commands are the ones in `spec/cli.md`.

/// A parsed action.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Action {
    /// Unbind a default.
    None,
    /// Enter a mode (`default` leaves the current one).
    Mode(String),
    /// Run a command as the user.
    Exec(String),
    /// A `baneyspaces` command line, as separate words.
    Cli(Vec<String>),
}

/// Longest action text accepted.
pub const MAX_ACTION_LEN: usize = 1000;

/// Splits a command line into words: whitespace separates, single and double quotes group,
/// a backslash escapes the next character outside single quotes.
pub fn words(s: &str) -> Result<Vec<String>, String> {
    let mut out = vec![];
    let mut cur = String::new();
    let mut have = false;
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            c if c.is_whitespace() => {
                if have {
                    out.push(std::mem::take(&mut cur));
                    have = false;
                }
            }
            '\'' => {
                have = true;
                loop {
                    match chars.next() {
                        Some('\'') => break,
                        Some(c) => cur.push(c),
                        None => return Err("unclosed ' quote".into()),
                    }
                }
            }
            '"' => {
                have = true;
                loop {
                    match chars.next() {
                        Some('"') => break,
                        Some('\\') => match chars.next() {
                            Some(c) => cur.push(c),
                            None => return Err("a backslash at the end".into()),
                        },
                        Some(c) => cur.push(c),
                        None => return Err("unclosed \" quote".into()),
                    }
                }
            }
            '\\' => {
                have = true;
                match chars.next() {
                    Some(c) => cur.push(c),
                    None => return Err("a backslash at the end".into()),
                }
            }
            c => {
                have = true;
                cur.push(c);
            }
        }
    }
    if have {
        out.push(cur);
    }
    Ok(out)
}

fn workspace(s: &str) -> Result<(), String> {
    match s.parse::<u8>() {
        Ok(1..=9) => Ok(()),
        _ => Err(format!("workspace {s:?} must be a number from 1 to 9")),
    }
}

fn int(s: &str, what: &str) -> Result<(), String> {
    s.parse::<i32>()
        .map(|_| ())
        .map_err(|_| format!("{what} {s:?} must be a whole number"))
}

fn usage(u: &str) -> String {
    format!("usage: {u}")
}

/// The commands that cannot be bound: they never return, or only make sense typed.
const NOT_BINDABLE: &[(&str, &str)] = &[
    ("daemon", "it runs the daemon in the foreground"),
    ("mcp", "it serves MCP on stdio"),
    ("help", "it only prints help"),
    (
        "recovery",
        "the recovery chord is bound by the platform and never from config",
    ),
];

fn check_cli(w: &[String]) -> Result<(), String> {
    let cmd = w[0].as_str();
    let rest = &w[1..];
    if let Some((_, why)) = NOT_BINDABLE.iter().find(|(c, _)| *c == cmd) {
        return Err(format!("{cmd:?} is not a bindable action: {why}"));
    }
    // Flags a command takes, minus its operands.
    let operands = |flags_with_value: &[&str], switches: &[&str]| -> Result<Vec<String>, String> {
        let mut ops = vec![];
        let mut i = 0;
        while i < rest.len() {
            let a = rest[i].as_str();
            if flags_with_value.contains(&a) {
                if i + 1 >= rest.len() {
                    return Err(format!("{a} needs a value"));
                }
                i += 2;
            } else if switches.contains(&a) {
                i += 1;
            } else if a.starts_with("--") {
                return Err(format!("{cmd} has no flag {a:?}"));
            } else {
                ops.push(a.to_string());
                i += 1;
            }
        }
        Ok(ops)
    };
    match cmd {
        "switch" => {
            let ops = operands(&[], &[])?;
            if ops.len() != 1 {
                return Err(usage("switch <n>"));
            }
            workspace(&ops[0])
        }
        "move" => {
            let ops = operands(&["--window"], &["--stay"])?;
            if ops.len() != 1 {
                return Err(usage("move <n> [--stay] [--window W]"));
            }
            workspace(&ops[0])
        }
        "focus-monitor" => {
            if rest.len() != 1 {
                return Err(usage("focus-monitor <name>"));
            }
            Ok(())
        }
        "ls" | "state" | "overview" | "stop" | "doctor" | "launcher" => {
            if rest.is_empty() {
                Ok(())
            } else {
                Err(format!("{cmd} takes no arguments"))
            }
        }
        "keys" => {
            operands(&["--platform"], &["--hypr-lua"]).map(|_| ())
        }
        "agent-workspace" => match rest {
            [a] if matches!(a.as_str(), "show" | "hide" | "toggle") => Ok(()),
            _ => Err(usage("agent-workspace show|hide|toggle")),
        },
        "switcher" => match rest {
            [a] if matches!(a.as_str(), "windows" | "apps") => Ok(()),
            _ => Err(usage("switcher windows|apps")),
        },
        "window" => match rest {
            [a, dx, dy] if a == "resize" => {
                int(dx, "dx")?;
                int(dy, "dy")
            }
            _ => Err(usage("window resize <dx> <dy>")),
        },
        "agent" => {
            let Some(sub) = rest.first() else {
                return Err(usage("agent <status|windows|open|run|move|bring|log|snapshot|find|get|click|set-value|type|toggle|select|scroll|shot|press|key|pointer|lend|return> ..."));
            };
            let need = match sub.as_str() {
                "status" | "windows" | "log" => 0,
                "open" | "move" | "bring" | "click" | "toggle" | "snapshot" | "find" | "shot" => {
                    if matches!(sub.as_str(), "snapshot" | "find" | "shot") { 0 } else { 1 }
                }
                "get" | "set-value" | "type" | "select" | "scroll" => 2,
                "run" => 1,
                "press" | "key" | "pointer" | "lend" | "return" => 0,
                other => return Err(format!("unknown agent command {other:?}; see spec/cli.md")),
            };
            if rest.len() - 1 < need {
                return Err(format!("agent {sub} needs {need} argument(s)"));
            }
            Ok(())
        }
        "config" => match rest.first().map(String::as_str) {
            Some("get") | Some("set") | Some("unset") | Some("apply") | Some("validate") | Some("schema") | Some("diff") | Some("undo") | Some("history") | Some("reset") => Ok(()),
            _ => Err(usage("config get|set|unset|apply|validate|schema|diff|undo|history|reset ...")),
        },
        "theme" => match rest.first().map(String::as_str) {
            Some("list") | Some("show") | Some("create") | Some("set") | Some("delete") => Ok(()),
            _ => Err(usage("theme list|show|create|set|delete ...")),
        },
        other => Err(format!("{other:?} is not a baneyspaces command; see spec/cli.md (exec <command> runs anything else)")),
    }
}

/// Parses an action. The error is the reason, for the envelope.
pub fn parse(text: &str) -> Result<Action, String> {
    if text.len() > MAX_ACTION_LEN {
        return Err(format!("an action is at most {MAX_ACTION_LEN} characters"));
    }
    if text.chars().any(|c| c == '\n' || c == '\r' || c == '\0') {
        return Err("an action is one line".into());
    }
    let t = text.trim();
    if t.is_empty() {
        return Err("an action cannot be empty; use \"none\" to unbind a default".into());
    }
    if t == "none" {
        return Ok(Action::None);
    }
    if t == "exec" || t.starts_with("exec ") || t.starts_with("exec\t") {
        let cmd = t["exec".len()..].trim();
        if cmd.is_empty() {
            return Err("exec needs a command: exec <command>".into());
        }
        return Ok(Action::Exec(cmd.to_string()));
    }
    let w = words(t)?;
    if w[0] == "mode" {
        return match w.as_slice() {
            [_, name] if name == "default" || is_name(name) => Ok(Action::Mode(name.clone())),
            [_, name] => Err(format!("mode name {name:?} must be \"default\" or lowercase letters, digits, - and _ (at most 32)")),
            _ => Err(usage("mode <name>")),
        };
    }
    check_cli(&w)?;
    Ok(Action::Cli(w))
}

/// A name for a mode or a theme: lowercase letters, digits, `-` and `_`, starting with a letter or digit.
pub fn is_name(s: &str) -> bool {
    let mut c = s.chars();
    matches!(c.next(), Some(f) if f.is_ascii_lowercase() || f.is_ascii_digit())
        && s.len() <= 32
        && c.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-' || c == '_')
}

/// The text a person reads for an action, used for binding descriptions.
pub fn describe(a: &Action, text: &str) -> String {
    match a {
        Action::Cli(w) => match w.iter().map(String::as_str).collect::<Vec<_>>().as_slice() {
            ["switch", n] => format!("workspace {n}"),
            ["move", n] => format!("send window to workspace {n}"),
            ["move", n, "--stay"] => format!("send window to workspace {n}, stay here"),
            ["overview"] => "overview".into(),
            ["agent-workspace", "toggle"] => "show or hide the agent workspace".into(),
            _ => text.trim().to_string(),
        },
        Action::Exec(c) => format!("exec {c}"),
        Action::Mode(m) => format!("mode {m}"),
        Action::None => "none".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_spec_examples_parse() {
        for ok in [
            "switch 1",
            "move 1",
            "switcher windows",
            "launcher",
            "overview",
            "exec ghostty",
            "mode resize",
            "none",
            "window resize -40 0",
            "mode default",
            "move 3 --stay",
            "agent-workspace toggle",
            "config reset keys",
            "theme set omarchy",
        ] {
            assert!(parse(ok).is_ok(), "{ok}: {:?}", parse(ok));
        }
    }

    #[test]
    fn kinds() {
        assert_eq!(parse("none").unwrap(), Action::None);
        assert_eq!(parse("mode resize").unwrap(), Action::Mode("resize".into()));
        assert_eq!(
            parse("exec  ghostty --class=x").unwrap(),
            Action::Exec("ghostty --class=x".into())
        );
        assert_eq!(
            parse("switch 3").unwrap(),
            Action::Cli(vec!["switch".into(), "3".into()])
        );
    }

    #[test]
    fn bad_actions_say_why() {
        let e = |s: &str| parse(s).unwrap_err();
        assert!(e("switch 10").contains("1 to 9"));
        assert!(e("switch").contains("usage"));
        assert!(e("move 2 --bogus").contains("no flag"));
        assert!(e("launch").contains("not a baneyspaces command"));
        assert!(e("exec").contains("needs a command"));
        assert!(e("").contains("cannot be empty"));
        assert!(e("mode Bad Name").contains("usage"));
        assert!(e("mode Bad").contains("mode name"));
        assert!(e("daemon").contains("not a bindable"));
        assert!(e("window resize a b").contains("whole number"));
        assert!(e("switch 1\nswitch 2").contains("one line"));
        assert!(e("agent").contains("usage"));
        assert!(e("agent get @s:e1").contains("2 argument"));
        assert!(e("switcher tabs").contains("usage"));
    }

    #[test]
    fn words_quote_like_a_shell() {
        assert_eq!(
            words(r#"agent run -- sh -c "echo 'a b'""#).unwrap(),
            vec!["agent", "run", "--", "sh", "-c", "echo 'a b'"]
        );
        assert_eq!(words("a\\ b c").unwrap(), vec!["a b", "c"]);
        assert!(words("'open").is_err());
        assert_eq!(words("''").unwrap(), vec![""]);
    }

    #[test]
    fn descriptions_match_the_include_that_ships() {
        let d = |t: &str| describe(&parse(t).unwrap(), t);
        assert_eq!(d("switch 3"), "workspace 3");
        assert_eq!(d("move 4 --stay"), "send window to workspace 4, stay here");
        assert_eq!(
            d("agent-workspace toggle"),
            "show or hide the agent workspace"
        );
        assert_eq!(d("launcher"), "launcher");
    }
}
