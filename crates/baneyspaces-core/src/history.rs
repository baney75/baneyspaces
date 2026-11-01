//! `history/`: the last 50 versions of the configuration, each stamped with who changed it
//! (`spec/config.md`, Who may change what). A version is one JSON file, `NNNNNNNN.json`, holding
//! `config.toml` as it was written and the custom themes with it, so an undo restores both.
//! Every file is written atomically.

use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

/// How many versions are kept.
pub const KEEP: usize = 50;
pub const FORMAT: u64 = 1;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Version {
    pub seq: u64,
    /// RFC 3339, UTC.
    pub time: String,
    /// `user`, `settings`, `agent:<name>`, or `system` for the first version.
    pub caller: String,
    /// One line.
    pub summary: String,
    /// The text of `config.toml`.
    pub config: String,
    /// `themes/<name>.toml` texts by name.
    pub themes: BTreeMap<String, String>,
    /// 0 for a change. For an undo, how many live versions it stepped back over: the state it
    /// holds is that of the version `undo` steps below the top of the live stack.
    pub undo: u64,
}

impl Version {
    pub fn to_json(&self) -> Value {
        let mut v = json!({ "format": FORMAT, "seq": self.seq, "time": self.time, "caller": self.caller, "summary": self.summary, "config": self.config, "themes": self.themes });
        if self.undo > 0 {
            v["undo"] = json!(self.undo);
        }
        v
    }

    pub fn from_json(v: &Value) -> Option<Self> {
        if v["format"].as_u64()? != FORMAT {
            return None;
        }
        Some(Version {
            seq: v["seq"].as_u64()?,
            time: v["time"].as_str()?.to_string(),
            caller: v["caller"].as_str()?.to_string(),
            summary: v["summary"].as_str()?.to_string(),
            config: v["config"].as_str()?.to_string(),
            themes: v["themes"]
                .as_object()?
                .iter()
                .filter_map(|(k, t)| Some((k.clone(), t.as_str()?.to_string())))
                .collect(),
            undo: v["undo"].as_u64().unwrap_or(0),
        })
    }

    /// What `config history` shows.
    pub fn summary_json(&self) -> Value {
        let mut v = json!({ "version": self.seq, "time": self.time, "caller": self.caller, "summary": self.summary });
        if self.undo > 0 {
            v["undo"] = json!(self.undo);
        }
        v
    }
}

/// A caller is `user`, `settings`, `system` or `agent:<name>` with a plain name.
pub fn caller_ok(c: &str) -> bool {
    match c.strip_prefix("agent:") {
        Some(n) => {
            !n.is_empty()
                && n.len() <= 64
                && n.chars()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
        }
        None => matches!(c, "user" | "settings" | "system"),
    }
}

/// `agent:<name>` from whatever a caller called itself, with anything odd replaced.
pub fn agent_caller(name: &str) -> String {
    let clean: String = name
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.') {
                c
            } else {
                '-'
            }
        })
        .take(64)
        .collect();
    format!(
        "agent:{}",
        if clean.is_empty() {
            "agent".to_string()
        } else {
            clean
        }
    )
}

/// Writes a file so a reader sees all of it or none: a temp file in the same directory, flushed,
/// renamed over the target, and the directory flushed.
pub fn write_atomic(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let dir = path
        .parent()
        .ok_or_else(|| io::Error::other("no parent directory"))?;
    fs::create_dir_all(dir)?;
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("file");
    let tmp = dir.join(format!(".{name}.{}.tmp", std::process::id()));
    let result = (|| {
        let mut f = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .open(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
        fs::rename(&tmp, path)?;
        if let Ok(d) = fs::File::open(dir) {
            let _ = d.sync_all();
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result
}

/// Seconds since the epoch as `YYYY-MM-DDTHH:MM:SSZ`.
pub fn rfc3339(secs: u64) -> String {
    let days = (secs / 86400) as i64;
    let rem = secs % 86400;
    // Days since 1970-01-01 to a civil date (Howard Hinnant's algorithm).
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z.rem_euclid(146097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        rem % 3600 / 60,
        rem % 60
    )
}

pub fn now_rfc3339() -> String {
    rfc3339(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0),
    )
}

pub struct History {
    dir: PathBuf,
}

impl History {
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        History { dir: dir.into() }
    }

    fn file(&self, seq: u64) -> PathBuf {
        self.dir.join(format!("{seq:08}.json"))
    }

    fn seqs(&self) -> Vec<u64> {
        let mut v: Vec<u64> = fs::read_dir(&self.dir)
            .into_iter()
            .flatten()
            .flatten()
            .filter_map(|e| {
                e.file_name()
                    .to_str()?
                    .strip_suffix(".json")?
                    .parse::<u64>()
                    .ok()
            })
            .collect();
        v.sort_unstable();
        v
    }

    /// Every readable version, oldest first. A file that does not parse is skipped.
    pub fn all(&self) -> Vec<Version> {
        self.seqs()
            .into_iter()
            .filter_map(|s| self.read(s))
            .collect()
    }

    pub fn read(&self, seq: u64) -> Option<Version> {
        let text = fs::read_to_string(self.file(seq)).ok()?;
        Version::from_json(&serde_json::from_str(&text).ok()?)
    }

    pub fn latest(&self) -> Option<Version> {
        self.seqs().into_iter().rev().find_map(|s| self.read(s))
    }

    /// Adds a version after the newest and drops all but the last [`KEEP`]. Returns its number.
    pub fn record(
        &self,
        time: &str,
        caller: &str,
        summary: &str,
        config: &str,
        themes: &BTreeMap<String, String>,
    ) -> io::Result<u64> {
        self.record_with(time, caller, summary, config, themes, 0)
    }

    /// Like [`History::record`]; `undo` is how many live versions this version steps back over.
    pub fn record_with(
        &self,
        time: &str,
        caller: &str,
        summary: &str,
        config: &str,
        themes: &BTreeMap<String, String>,
        undo: u64,
    ) -> io::Result<u64> {
        let seq = self.seqs().last().map_or(1, |s| s + 1);
        let one_line: String = summary
            .replace(['\n', '\r'], " ")
            .chars()
            .take(300)
            .collect();
        let v = Version {
            seq,
            time: time.to_string(),
            caller: caller.to_string(),
            summary: one_line,
            config: config.to_string(),
            themes: themes.clone(),
            undo,
        };
        write_atomic(
            &self.file(seq),
            serde_json::to_string_pretty(&v.to_json())
                .unwrap_or_default()
                .as_bytes(),
        )?;
        let seqs = self.seqs();
        if seqs.len() > KEEP {
            for old in &seqs[..seqs.len() - KEEP] {
                let _ = fs::remove_file(self.file(*old));
            }
        }
        Ok(seq)
    }

    /// The versions an undo can step back over, oldest first: every change, minus the ones later
    /// undos stepped back over. History itself is never shortened by an undo.
    pub fn live_stack(all: &[Version]) -> Vec<usize> {
        let mut stack: Vec<usize> = vec![];
        for (i, v) in all.iter().enumerate() {
            if v.undo > 0 {
                for _ in 0..v.undo {
                    stack.pop();
                }
            } else {
                stack.push(i);
            }
        }
        stack
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("bs-history-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        d
    }

    #[test]
    fn dates() {
        assert_eq!(rfc3339(0), "1970-01-01T00:00:00Z");
        assert_eq!(rfc3339(951782400), "2000-02-29T00:00:00Z");
        assert_eq!(rfc3339(1793491200 + 3661), "2026-11-01T01:01:01Z");
    }

    #[test]
    fn versions_are_numbered_stamped_and_read_back() {
        let d = tmp("rw");
        let h = History::new(&d);
        assert!(h.latest().is_none());
        let mut themes = BTreeMap::new();
        themes.insert("mine".to_string(), "extends = \"omarchy\"\n".to_string());
        let a = h
            .record(
                "2026-11-01T00:00:00Z",
                "user",
                "first",
                "a = 1\n",
                &BTreeMap::new(),
            )
            .unwrap();
        let b = h
            .record(
                "2026-11-01T00:00:01Z",
                "agent:claude",
                "second\nline",
                "a = 2\n",
                &themes,
            )
            .unwrap();
        assert_eq!((a, b), (1, 2));
        let all = h.all();
        assert_eq!(all.len(), 2);
        assert_eq!(all[1].caller, "agent:claude");
        assert_eq!(all[1].summary, "second line", "a summary is one line");
        assert_eq!(all[1].themes["mine"], "extends = \"omarchy\"\n");
        assert_eq!(h.latest().unwrap().seq, 2);
        assert_eq!(
            fs::read_dir(&d).unwrap().count(),
            2,
            "no temp files are left"
        );
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn only_the_last_fifty_are_kept() {
        let d = tmp("keep");
        let h = History::new(&d);
        for i in 0..(KEEP as u64 + 7) {
            h.record(
                "t",
                "user",
                &format!("v{i}"),
                &format!("n = {i}\n"),
                &BTreeMap::new(),
            )
            .unwrap();
        }
        let all = h.all();
        assert_eq!(all.len(), KEEP);
        assert_eq!(all[0].seq, 8);
        assert_eq!(all.last().unwrap().seq, KEEP as u64 + 7);
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn the_live_stack_skips_what_undos_stepped_over_and_nothing_is_deleted() {
        let d = tmp("stack");
        let h = History::new(&d);
        let none = BTreeMap::new();
        for i in 0..4 {
            h.record("t", "user", &format!("v{i}"), "", &none).unwrap();
        }
        h.record_with("t", "user", "undo 2", "", &none, 2).unwrap();
        let all = h.all();
        assert_eq!(all.len(), 5, "an undo adds a version");
        assert_eq!(History::live_stack(&all), vec![0, 1]);
        h.record("t", "user", "again", "", &none).unwrap();
        h.record_with("t", "user", "undo 1", "", &none, 1).unwrap();
        assert_eq!(History::live_stack(&h.all()), vec![0, 1]);
        assert_eq!(h.record("t", "user", "x", "", &none).unwrap(), 8);
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn a_damaged_file_is_skipped_and_never_a_panic() {
        let d = tmp("bad");
        let h = History::new(&d);
        h.record("t", "user", "ok", "", &BTreeMap::new()).unwrap();
        fs::write(d.join("00000002.json"), "{not json").unwrap();
        fs::write(d.join("00000003.json"), "{\"format\":9}").unwrap();
        assert_eq!(h.all().len(), 1);
        assert_eq!(h.latest().unwrap().seq, 1);
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn callers() {
        assert!(
            caller_ok("user")
                && caller_ok("settings")
                && caller_ok("agent:claude-code")
                && caller_ok("system")
        );
        assert!(!caller_ok("agent:") && !caller_ok("agent:a b") && !caller_ok("root"));
        assert_eq!(agent_caller("my agent/x"), "agent:my-agent-x");
        assert_eq!(agent_caller(""), "agent:agent");
        assert!(caller_ok(&agent_caller("../../etc")));
    }

    #[test]
    fn writes_are_atomic_and_replace() {
        let d = tmp("atomic");
        let p = d.join("x.toml");
        write_atomic(&p, b"one").unwrap();
        write_atomic(&p, b"two").unwrap();
        assert_eq!(fs::read_to_string(&p).unwrap(), "two");
        assert_eq!(fs::read_dir(&d).unwrap().count(), 1);
        let _ = fs::remove_dir_all(&d);
    }
}
