//! Sets one value in a TOML theme file and keeps the file's comments where it can.
//!
//! It edits the text line by line, then parses the result and compares it with the table it
//! expected. If they differ for any reason (dotted keys, inline tables, multi-line strings), it
//! falls back to writing the table again, which drops comments.

use toml::{Table, Value};

/// Result of an edit: the new text, and whether the original comments and layout were kept.
pub(super) struct Edited {
    pub text: String,
    pub kept_comments: bool,
}

/// Sets `key` inside the table at `section` (empty for the top level) to `value`.
pub(super) fn set(
    text: &str,
    section: &[&str],
    key: &str,
    value: &Value,
) -> Result<Edited, String> {
    let original: Table = text
        .parse()
        .map_err(|e: toml::de::Error| format!("not valid TOML: {}", e.message()))?;
    let mut expected = original;
    {
        let mut t = &mut expected;
        for seg in section {
            let entry = t
                .entry((*seg).to_string())
                .or_insert_with(|| Value::Table(Table::new()));
            t = entry
                .as_table_mut()
                .ok_or_else(|| format!("{seg} is not a table"))?;
        }
        t.insert(key.to_string(), value.clone());
    }
    if let Some(edited) = edit_lines(text, &section.join("."), key, value) {
        if edited.parse::<Table>().ok().as_ref() == Some(&expected) {
            return Ok(Edited {
                text: edited,
                kept_comments: true,
            });
        }
    }
    let body = toml::to_string(&expected).map_err(|e| e.to_string())?;
    Ok(Edited {
        text: format!(
            "# Comments were dropped when this file was last edited by `baneyspaces theme`.\n{body}"
        ),
        kept_comments: false,
    })
}

/// Removes `key` from the table at `section`, keeping every other line and comment. A section
/// left with no keys goes too, with the one blank line before it that `set` adds.
pub(super) fn remove(text: &str, section: &[&str], key: &str) -> Result<Edited, String> {
    let original: Table = text
        .parse()
        .map_err(|e: toml::de::Error| format!("not valid TOML: {}", e.message()))?;
    let mut expected = original;
    fn go(t: &mut Table, section: &[&str], key: &str) {
        match section {
            [] => {
                t.remove(key);
            }
            [first, rest @ ..] => {
                if let Some(Value::Table(sub)) = t.get_mut(*first) {
                    go(sub, rest, key);
                    if sub.is_empty() {
                        t.remove(*first);
                    }
                }
            }
        }
    }
    go(&mut expected, section, key);
    if let Some(edited) = remove_lines(text, &section.join("."), key) {
        if edited.parse::<Table>().ok().as_ref() == Some(&expected) {
            return Ok(Edited {
                text: edited,
                kept_comments: true,
            });
        }
    }
    let body = toml::to_string(&expected).map_err(|e| e.to_string())?;
    Ok(Edited {
        text: format!(
            "# Comments were dropped when this file was last edited by `baneyspaces theme`.\n{body}"
        ),
        kept_comments: false,
    })
}

fn remove_lines(text: &str, target: &str, key: &str) -> Option<String> {
    let eol = if text.contains("\r\n") { "\r\n" } else { "\n" };
    let mut lines: Vec<String> = text.lines().map(str::to_string).collect();
    let mut current = String::new();
    let mut header_at: Option<usize> = None;
    let mut found: Option<usize> = None;
    for (i, line) in lines.iter().enumerate() {
        if let Some(h) = header_of(line) {
            if h == target {
                header_at = Some(i);
            }
            current = h;
            continue;
        }
        if current == target && key_of(line).as_deref() == Some(key) {
            found = Some(i);
            break;
        }
    }
    let at = found?;
    // A one-line plain value only.
    let eq = lines[at].find('=')?;
    let rest = lines[at][eq + 1..].trim_start();
    let end = value_end(rest)?;
    let tail = rest[end..].trim();
    if !(tail.is_empty() || tail.starts_with('#')) {
        return None;
    }
    lines.remove(at);
    if let Some(h) = header_at {
        let body_empty = lines[h + 1..]
            .iter()
            .take_while(|l| header_of(l).is_none())
            .all(|l| l.trim().is_empty());
        if body_empty {
            // Drop the header and the lines up to the next header, and one blank line before it.
            let mut end = h + 1;
            while end < lines.len() && header_of(&lines[end]).is_none() {
                end += 1;
            }
            lines.drain(h..end);
            if h > 0 && lines.get(h - 1).is_some_and(|l| l.trim().is_empty()) {
                lines.remove(h - 1);
            }
        }
    }
    Some(join(&lines, eol))
}

/// A TOML value as one line of text.
pub(super) fn render(v: &Value) -> String {
    v.to_string()
}

fn header_of(line: &str) -> Option<String> {
    let t = line.trim();
    if !t.starts_with('[') || t.starts_with("[[") {
        return None;
    }
    let end = t.find(']')?;
    let after = t[end + 1..].trim();
    if !(after.is_empty() || after.starts_with('#')) {
        return None;
    }
    Some(
        t[1..end]
            .split('.')
            .map(|s| s.trim().trim_matches('"').trim_matches('\''))
            .collect::<Vec<_>>()
            .join("."),
    )
}

/// The key of a `key = value` line, if it is one.
fn key_of(line: &str) -> Option<String> {
    let t = line.trim_start();
    if t.starts_with('#') || t.starts_with('[') {
        return None;
    }
    let (k, _) = t.split_once('=')?;
    let k = k.trim().trim_matches('"').trim_matches('\'');
    if k.is_empty() || k.contains('.') || k.contains(char::is_whitespace) {
        return None;
    }
    Some(k.to_string())
}

/// Where the value ends on a line, for a one-line value. None if it is not a plain one.
fn value_end(v: &str) -> Option<usize> {
    if v.starts_with("\"\"\"") || v.starts_with("'''") || v.starts_with('[') || v.starts_with('{') {
        return None;
    }
    if let Some(rest) = v.strip_prefix('"') {
        let mut escaped = false;
        for (i, ch) in rest.char_indices() {
            match ch {
                _ if escaped => escaped = false,
                '\\' => escaped = true,
                '"' => return Some(i + 2),
                _ => {}
            }
        }
        return None;
    }
    if let Some(rest) = v.strip_prefix('\'') {
        return rest.find('\'').map(|i| i + 2);
    }
    Some(v.find('#').unwrap_or(v.len()))
}

fn edit_lines(text: &str, target: &str, key: &str, value: &Value) -> Option<String> {
    let eol = if text.contains("\r\n") { "\r\n" } else { "\n" };
    let mut lines: Vec<String> = text.lines().map(str::to_string).collect();
    let new_value = render(value);
    let mut current = String::new();
    let mut header_at: Option<usize> = None;
    let mut last_key: Option<usize> = None;
    let mut first_header: Option<usize> = None;
    for i in 0..lines.len() {
        if let Some(h) = header_of(&lines[i]) {
            first_header.get_or_insert(i);
            if h == target {
                header_at = Some(i);
            }
            current = h;
            continue;
        }
        if current != target {
            continue;
        }
        if let Some(k) = key_of(&lines[i]) {
            if k == key {
                let line = lines[i].clone();
                let eq = line.find('=')?;
                let rest = line[eq + 1..].trim_start();
                let end = value_end(rest)?;
                let tail = rest[end..].trim();
                let mut new_line = format!("{} = {new_value}", line[..eq].trim_end());
                if tail.starts_with('#') {
                    new_line.push_str(&format!(" {tail}"));
                } else if !tail.is_empty() {
                    return None;
                }
                lines[i] = new_line;
                return Some(join(&lines, eol));
            }
            last_key = Some(i);
        }
    }
    let new_line = format!("{key} = {new_value}");
    if target.is_empty() {
        let mut at = first_header.unwrap_or(lines.len());
        while at > 0 && lines[at - 1].trim().is_empty() {
            at -= 1;
        }
        let at = last_key.map_or(at, |k| k + 1);
        lines.insert(at, new_line);
    } else if let Some(h) = header_at {
        lines.insert(last_key.map_or(h + 1, |k| k + 1), new_line);
    } else {
        if lines.last().is_some_and(|l| !l.trim().is_empty()) {
            lines.push(String::new());
        }
        lines.push(format!("[{target}]"));
        lines.push(new_line);
    }
    Some(join(&lines, eol))
}

fn join(lines: &[String], eol: &str) -> String {
    let mut s = lines.join(eol);
    s.push_str(eol);
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(v: &str) -> Value {
        Value::String(v.into())
    }

    #[test]
    fn replaces_in_place_and_keeps_comments() {
        let src = "# top\nname = \"x\"\n\n[light]\n# the brand color\naccent = \"#111111\" # old\nbackground = \"#ffffff\"\n";
        let e = set(src, &["light"], "accent", &s("#222222")).unwrap();
        assert!(e.kept_comments);
        assert_eq!(
            e.text,
            "# top\nname = \"x\"\n\n[light]\n# the brand color\naccent = \"#222222\" # old\nbackground = \"#ffffff\"\n"
        );
    }

    #[test]
    fn adds_keys_sections_and_top_level_values() {
        let src = "name = \"x\"\n[light]\naccent = \"#111111\"\n";
        let e = set(src, &["light"], "border", &s("#333333")).unwrap();
        assert!(e
            .text
            .contains("accent = \"#111111\"\nborder = \"#333333\"\n"));
        let e = set(src, &["shape"], "radius", &Value::Integer(0)).unwrap();
        assert!(
            e.kept_comments && e.text.ends_with("[shape]\nradius = 0\n"),
            "{}",
            e.text
        );
        let e = set(src, &[], "title", &s("T")).unwrap();
        assert!(
            e.text.starts_with("name = \"x\"\ntitle = \"T\"\n"),
            "{}",
            e.text
        );
        let e = set(src, &["surface", "site", "light"], "accent", &s("#444444")).unwrap();
        assert!(e
            .text
            .ends_with("[surface.site.light]\naccent = \"#444444\"\n"));
    }

    #[test]
    fn remove_undoes_a_set_exactly() {
        let src = "# top\nname = \"x\"\n\n[light]\naccent = \"#111111\"\n";
        for (section, key) in [
            (vec!["light"], "border"),
            (vec!["dark"], "muted"),
            (vec!["surface", "site", "dark"], "accent"),
        ] {
            let set = set(src, &section, key, &s("#333333")).unwrap();
            assert!(set.kept_comments);
            let back = remove(&set.text, &section, key).unwrap();
            assert!(back.kept_comments);
            assert_eq!(back.text, src, "{section:?}");
        }
    }

    #[test]
    fn falls_back_when_the_layout_is_not_plain() {
        let src = "name = \"x\"\nlight = { accent = \"#111111\" }\n";
        let e = set(src, &["light"], "accent", &s("#222222")).unwrap();
        assert!(!e.kept_comments);
        let t: Table = e.text.parse().unwrap();
        assert_eq!(t["light"]["accent"].as_str(), Some("#222222"));
    }
}
