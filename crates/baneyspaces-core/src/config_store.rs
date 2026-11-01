//! The configuration on disk and every command that reads or changes it (`spec/config.md`,
//! Interface). One [`Service`] per config directory:
//!
//! ```text
//! config.toml        only what differs from the defaults
//! themes/<name>.toml custom themes
//! history/           the last 50 versions, each stamped with who changed it
//! .lock              held while anything is written
//! ```
//!
//! Every change is validated as a whole before a byte is written, written atomically, and
//! recorded in history with its caller. A platform runs [`Service::dispatch`] for each command
//! (the Linux daemon is the single writer) and applies the returned [`Applied`] to the screen.

use crate::approvals::{self, Pending};
use crate::chord::Platform;
use crate::config::{self, Effective, Env, Themes, Validated};
use crate::config_schema::{path_string, Issue};
use crate::envelope::{Envelope, Retry};
use crate::history::{self, History, Version};
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

/// The biggest config or theme file read.
const MAX_FILE: u64 = 1 << 20;

/// One setting that differs between two documents.
#[derive(Clone, Debug, PartialEq)]
pub struct Change {
    pub path: String,
    pub from: Option<Value>,
    pub to: Option<Value>,
}

impl Change {
    pub fn to_json(&self) -> Value {
        json!({ "path": self.path, "from": self.from, "to": self.to })
    }
}

/// What is on disk.
#[derive(Clone, Debug, Default)]
pub struct State {
    pub config_text: String,
    pub user: Value,
    pub theme_texts: BTreeMap<String, String>,
    pub themes: Themes,
    /// Files that are not valid TOML (`config.toml` is `path` empty).
    pub syntax: Vec<Issue>,
    /// Theme files that could not be read (not UTF-8, over 1 MiB, unreadable): never written over or deleted.
    pub unreadable: BTreeSet<String>,
}

impl State {
    fn empty() -> Self {
        State {
            user: json!({}),
            ..Default::default()
        }
    }
}

/// A change that was made.
#[derive(Clone, Debug)]
pub struct Applied {
    pub changed: bool,
    pub version: Option<u64>,
    pub summary: String,
    pub changes: Vec<Change>,
    pub warnings: Vec<Issue>,
    /// The config that runs: executable entries that are not approved are taken out.
    pub effective: Effective,
    pub resolved: Value,
    /// Executable entries waiting for a click in Settings.
    pub pending: Vec<Pending>,
    /// Broken files kept as `*.invalid-<time>` before a reset or undo wrote over them.
    pub kept_aside: Vec<String>,
}

/// A command's answer, and the change to apply to the screen when it changed the config.
pub struct Outcome {
    pub env: Envelope,
    pub applied: Option<Applied>,
}

impl Outcome {
    fn only(env: Envelope) -> Self {
        Outcome { env, applied: None }
    }
}

/// Where the running config came from.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Source {
    File,
    /// The file is invalid; this history version is running instead.
    LastGood(u64),
    Defaults,
}

pub struct Loaded {
    pub state: State,
    /// The state that is running: the file's, or the newest history version that holds.
    pub good: State,
    pub source: Source,
    /// What is wrong with the file, when it is not what is running.
    pub file_issues: Vec<Issue>,
    pub validated: Validated,
}

pub struct Service {
    pub dir: PathBuf,
    pub env: Env,
    /// `approvals.json` in the state directory. With none, nothing executable is approved.
    pub approvals: Option<PathBuf>,
}

// ---- helpers ---------------------------------------------------------------------------------

fn invalid(issues: &[Issue], warnings: &[Issue], what: &str) -> Envelope {
    let first = issues.first();
    let msg = match first {
        Some(i) if issues.len() == 1 => format!(
            "{what}: {}: {}",
            if i.path.is_empty() {
                "the document"
            } else {
                &i.path
            },
            i.reason
        ),
        Some(i) => format!(
            "{what}: {} problems; the first is {}: {}",
            issues.len(),
            if i.path.is_empty() {
                "the document"
            } else {
                &i.path
            },
            i.reason
        ),
        None => what.to_string(),
    };
    Envelope::err("config_invalid", msg, Retry::Never, "Fix the paths in error.data.issues and send the change again. `baneyspaces config schema` lists every setting and its limits. The running config did not change.")
        .with_data(json!({ "issues": issues.iter().map(Issue::to_json).collect::<Vec<_>>(), "warnings": warnings.iter().map(Issue::to_json).collect::<Vec<_>>() }))
}

fn bad_args(msg: impl Into<String>, suggestion: &str) -> Envelope {
    Envelope::err("invalid_args", msg, Retry::Never, suggestion)
}

fn not_found(msg: impl Into<String>, suggestion: &str) -> Envelope {
    Envelope::err("not_found", msg, Retry::Never, suggestion)
}

fn io_err(what: &str, e: impl std::fmt::Display) -> Envelope {
    Envelope::err(
        "internal",
        format!("{what}: {e}"),
        Retry::Never,
        "Check the permissions of the config directory.",
    )
}

/// Every leaf (a scalar, an array or an empty table) with its path.
fn leaves(v: &Value, path: &mut Vec<String>, out: &mut BTreeMap<String, Value>) {
    match v {
        Value::Object(o) if !o.is_empty() => {
            for (k, c) in o {
                path.push(k.clone());
                leaves(c, path, out);
                path.pop();
            }
        }
        Value::Object(_) => {}
        other => {
            out.insert(path_string(path), other.clone());
        }
    }
}

fn flat(v: &Value) -> BTreeMap<String, Value> {
    let mut m = BTreeMap::new();
    leaves(v, &mut vec![], &mut m);
    m
}

/// The settings that differ going from `from` to `to`.
pub fn changes(from: &Value, to: &Value) -> Vec<Change> {
    let (a, b) = (flat(from), flat(to));
    let mut out = vec![];
    for (k, av) in &a {
        match b.get(k) {
            Some(bv) if bv == av => {}
            bv => out.push(Change {
                path: k.clone(),
                from: Some(av.clone()),
                to: bv.cloned(),
            }),
        }
    }
    for (k, bv) in &b {
        if !a.contains_key(k) {
            out.push(Change {
                path: k.clone(),
                from: None,
                to: Some(bv.clone()),
            });
        }
    }
    out
}

fn theme_changes(old: &BTreeMap<String, String>, new: &BTreeMap<String, String>) -> Vec<String> {
    let mut out = vec![];
    for (k, v) in new {
        match old.get(k) {
            None => out.push(format!("theme {k} created")),
            Some(o) if o != v => out.push(format!("theme {k} changed")),
            _ => {}
        }
    }
    for k in old.keys() {
        if !new.contains_key(k) {
            out.push(format!("theme {k} deleted"));
        }
    }
    out
}

fn list(paths: &[String]) -> String {
    let shown: Vec<&str> = paths.iter().take(3).map(String::as_str).collect();
    format!(
        "{}{}",
        shown.join(", "),
        if paths.len() > 3 {
            format!(" and {} more", paths.len() - 3)
        } else {
            String::new()
        }
    )
}

/// Whether the pending entry is the setting at `asked`, or inside it. Chord names under `keys` compare as chords.
fn pending_under(e: &Pending, asked: &[String], modifier: &str) -> bool {
    if asked.len() > e.segments.len() {
        return false;
    }
    e.segments.iter().zip(asked).enumerate().all(|(i, (a, b))| {
        a == b || (i >= 2 && e.segments[0] == "keys" && matches!((crate::chord::parse(a, modifier), crate::chord::parse(b, modifier)), (Ok(x), Ok(y)) if x == y))
    })
}

fn parse_value_text(s: &str) -> Value {
    serde_json::from_str::<Value>(s).unwrap_or_else(|_| Value::String(s.to_string()))
}

fn read_limited(p: &Path) -> Option<String> {
    let meta = fs::metadata(p).ok()?;
    if meta.len() > MAX_FILE {
        return None;
    }
    fs::read_to_string(p).ok()
}

impl Service {
    pub fn new(dir: impl Into<PathBuf>, env: Env) -> Self {
        Service {
            dir: dir.into(),
            env,
            approvals: None,
        }
    }

    pub fn with_approvals(mut self, path: impl Into<PathBuf>) -> Self {
        self.approvals = Some(path.into());
        self
    }

    pub fn config_path(&self) -> PathBuf {
        self.dir.join("config.toml")
    }
    pub fn themes_dir(&self) -> PathBuf {
        self.dir.join("themes")
    }
    pub fn history(&self) -> History {
        History::new(self.dir.join("history"))
    }

    // ---- reading -----------------------------------------------------------------------------

    /// Reads `config.toml` and `themes/`. A file that does not parse is recorded, not fatal.
    pub fn read_state(&self) -> State {
        let mut st = State::empty();
        match fs::metadata(self.config_path()) {
            Ok(m) if m.len() > MAX_FILE => st.syntax.push(Issue {
                path: String::new(),
                code: "syntax",
                reason: "config.toml is over 1 MiB".into(),
            }),
            Ok(_) => match fs::read_to_string(self.config_path()) {
                Ok(t) => {
                    match config::parse_document(&t) {
                        Ok(v) => st.user = v,
                        Err(i) => st.syntax.push(i),
                    }
                    st.config_text = t;
                }
                Err(e) => st.syntax.push(Issue {
                    path: String::new(),
                    code: "syntax",
                    reason: format!("cannot read config.toml: {e}"),
                }),
            },
            Err(_) => {}
        }
        for e in fs::read_dir(self.themes_dir())
            .into_iter()
            .flatten()
            .flatten()
        {
            let p = e.path();
            let (Some(stem), Some("toml")) = (
                p.file_stem().and_then(|s| s.to_str()),
                p.extension().and_then(|s| s.to_str()),
            ) else {
                continue;
            };
            if !crate::action::is_name(stem) {
                continue;
            }
            let Some(text) = read_limited(&p) else {
                st.unreadable.insert(stem.to_string());
                st.themes.insert(stem.to_string(), json!({ "__broken": format!("themes/{stem}.toml cannot be read or is over 1 MiB") }));
                continue;
            };
            match config::parse_document(&text) {
                Ok(v) => {
                    st.themes.insert(stem.to_string(), v);
                }
                Err(i) => {
                    st.themes.insert(
                        stem.to_string(),
                        json!({ "__broken": format!("themes/{stem}.toml: {}", i.reason) }),
                    );
                }
            }
            st.theme_texts.insert(stem.to_string(), text);
        }
        st
    }

    fn state_of(&self, v: &Version) -> State {
        let mut st = State {
            config_text: v.config.clone(),
            user: config::parse_document(&v.config).unwrap_or_else(|_| json!({})),
            theme_texts: v.themes.clone(),
            ..State::empty()
        };
        for (n, t) in &v.themes {
            st.themes.insert(
                n.clone(),
                config::parse_document(t)
                    .unwrap_or_else(|_| json!({ "__broken": "not valid TOML" })),
            );
        }
        st
    }

    fn validate_state(&self, st: &State) -> Validated {
        let mut v = config::validate(&st.user, &self.env, &st.themes);
        if !st.syntax.is_empty() {
            v.issues.splice(0..0, st.syntax.iter().cloned());
            v.effective = None;
        }
        v
    }

    /// The running config: the file if it holds, else the newest history version that does, else
    /// the defaults.
    pub fn load(&self) -> Loaded {
        let state = self.read_state();
        let validated = self.validate_state(&state);
        if validated.issues.is_empty() {
            return Loaded {
                good: state.clone(),
                state,
                source: Source::File,
                file_issues: vec![],
                validated,
            };
        }
        let file_issues = validated.issues.clone();
        for v in self.history().all().into_iter().rev() {
            let st = self.state_of(&v);
            let val = self.validate_state(&st);
            if val.issues.is_empty() {
                return Loaded {
                    state,
                    good: st,
                    source: Source::LastGood(v.seq),
                    file_issues,
                    validated: val,
                };
            }
        }
        let good = State::empty();
        let val = self.validate_state(&good);
        Loaded {
            state,
            good,
            source: Source::Defaults,
            file_issues,
            validated: val,
        }
    }

    fn approved(&self) -> BTreeSet<String> {
        self.approvals.as_deref().map(approvals::load).unwrap_or_default()
    }

    /// The config that runs and the executable entries still waiting for a click.
    pub fn activate(&self, eff: &Effective) -> (Effective, Vec<Pending>) {
        approvals::activate(eff, &self.approved())
    }

    /// Records an approval. This is the Settings UI's write: the control socket, the CLI and MCP never
    /// call it (the daemon only does, in a test-only operation).
    pub fn approve(&self, path: &str, value: &str) -> Result<String, String> {
        let Some(f) = &self.approvals else { return Err("no approvals file".into()) };
        approvals::approve(f, path, value, &history::now_rfc3339()).map_err(|e| e.to_string())
    }

    /// The effective config now (the part that runs), with what was resolved from it.
    pub fn current(&self) -> (Effective, Value, Loaded) {
        let l = self.load();
        let configured = l.validated.effective.clone().expect("the running state is valid");
        let (eff, _) = self.activate(&configured);
        let resolved = config::resolved_json(&eff, &self.env, &l.good.themes);
        (eff, resolved, l)
    }

    /// Who wrote an executable entry, as far as the kept history says. A hint and nothing more: a
    /// hand edit reads as `user`, and an entry older than the kept versions has no writer at all.
    fn written_by(&self, p: &Pending, all: &[Version]) -> Option<String> {
        let at = |v: &Version| config::get_path(&self.state_of(v).user, &p.segments).and_then(Value::as_str).map(String::from);
        let mut start = all.len();
        while start > 0 && at(&all[start - 1]).as_deref() == Some(p.value.as_str()) {
            start -= 1;
        }
        (start > 0 && start < all.len()).then(|| all[start].caller.clone())
    }

    pub fn pending_json(&self, pending: &[Pending]) -> Vec<Value> {
        let all = self.history().all();
        pending.iter().map(|p| p.to_json(self.written_by(p, &all).as_deref())).collect()
    }

    /// What every UI reads: the resolved config plus whether the file on disk is the one running.
    pub fn runtime_json(&self) -> Value {
        let (_, mut r, l) = self.current();
        let configured = l.validated.effective.clone().expect("the running state is valid");
        r["pending"] = Value::Array(self.pending_json(&self.activate(&configured).1));
        // Everything approved, with the ones not made by the Settings handler marked for Settings to show.
        r["approved"] = Value::Array(self.approvals.as_deref().map(approvals::list).unwrap_or_default());
        r["status"] = json!({
            "valid": l.file_issues.is_empty(),
            "source": match l.source { Source::File => json!("file"), Source::LastGood(v) => json!({ "history": v }), Source::Defaults => json!("defaults") },
            "issues": l.file_issues.iter().map(Issue::to_json).collect::<Vec<_>>(),
        });
        r
    }

    // ---- writing -----------------------------------------------------------------------------

    fn lock(&self) -> Result<fs::File, Envelope> {
        fs::create_dir_all(&self.dir)
            .map_err(|e| io_err("cannot create the config directory", e))?;
        let f = fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(self.dir.join(".lock"))
            .map_err(|e| io_err("cannot open the lock", e))?;
        f.lock().map_err(|e| io_err("cannot take the lock", e))?;
        Ok(f)
    }

    /// Writes the files of `new`. Only the themes named in `removed` are deleted: a file the service
    /// could not read is never touched.
    fn write_files(&self, new: &State, removed: &[String]) -> Result<(), Envelope> {
        let tdir = self.themes_dir();
        for (n, t) in &new.theme_texts {
            if new.unreadable.contains(n) {
                continue; // a file we could not read is the person's: never written over
            }
            history::write_atomic(&tdir.join(format!("{n}.toml")), t.as_bytes())
                .map_err(|e| io_err("cannot write a theme", e))?;
        }
        for n in removed {
            if crate::action::is_name(n) && !new.theme_texts.contains_key(n) && !new.unreadable.contains(n) {
                let _ = fs::remove_file(tdir.join(format!("{n}.toml")));
            }
        }
        history::write_atomic(&self.config_path(), new.config_text.as_bytes())
            .map_err(|e| io_err("cannot write config.toml", e))
    }

    /// When the files on disk are not the running config, keeps what is about to be written over as
    /// `*.invalid-<time>`: `config.toml` and every theme file whose text differs.
    fn keep_aside(&self, l: &Loaded, new: &State) -> Vec<String> {
        if l.file_issues.is_empty() {
            return vec![];
        }
        let ts = history::now_rfc3339().replace(':', "");
        let mut out = vec![];
        let themes_broken = |n: &str| l.file_issues.iter().any(|i| i.path == format!("themes.{n}") || i.path.starts_with(&format!("themes.{n}.")));
        let config_broken = l.file_issues.iter().any(|i| !i.path.starts_with("themes.")) || !l.state.syntax.is_empty();
        if config_broken && !l.state.config_text.is_empty() && l.state.config_text != new.config_text {
            let p = self.dir.join(format!("config.toml.invalid-{ts}"));
            if history::write_atomic(&p, l.state.config_text.as_bytes()).is_ok() {
                out.push(p.display().to_string());
            }
        }
        for (n, t) in &l.state.theme_texts {
            if themes_broken(n) && new.theme_texts.get(n) != Some(t) {
                let p = self.themes_dir().join(format!("{n}.toml.invalid-{ts}"));
                if history::write_atomic(&p, t.as_bytes()).is_ok() {
                    out.push(p.display().to_string());
                }
            }
        }
        out
    }

    fn applied(
        &self,
        new: &State,
        base: &State,
        version: Option<u64>,
        summary: String,
        changed: bool,
    ) -> Applied {
        let v = self.validate_state(new);
        let configured = v.effective.expect("a written state is valid");
        let (eff, pending) = self.activate(&configured);
        let resolved = config::resolved_json(&eff, &self.env, &new.themes);
        let mut ch = changes(&base.user, &new.user);
        for t in theme_changes(&base.theme_texts, &new.theme_texts) {
            ch.push(Change {
                path: format!("themes.{}", t.split(' ').nth(1).unwrap_or("")),
                from: None,
                to: Some(json!(t)),
            });
        }
        Applied {
            changed,
            version,
            summary,
            changes: ch,
            warnings: v.warnings,
            effective: eff,
            resolved,
            pending,
            kept_aside: vec![],
        }
    }

    /// Runs one change under the lock: `f` turns the running state into the new one (and a
    /// summary); the new state is validated as a whole, written, and recorded.
    fn mutate(
        &self,
        caller: &str,
        strict: bool,
        f: impl FnOnce(&State) -> Result<(State, String), Envelope>,
    ) -> Result<Applied, Envelope> {
        let _lock = self.lock()?;
        // Record a hand edit the watcher has not noticed yet, before building on the files: it must
        // not be folded into this caller's version.
        let _ = self.observe_locked();
        let l = self.load();
        if strict && !l.file_issues.is_empty() {
            return Err(invalid(&l.file_issues, &[], "config.toml has errors and was not changed; the last good config is running").with_data(json!({
                "issues": l.file_issues.iter().map(Issue::to_json).collect::<Vec<_>>(),
                "hint": "Fix the file, or run `baneyspaces config reset` (or `config undo`) to go back to a good one."
            })));
        }
        let (mut new, summary) = f(&l.good)?;
        new.unreadable = l.state.unreadable.clone();
        // A theme file that exists but cannot be read is never overwritten, whatever asks to write one.
        if let Some(n) = new.theme_texts.iter().find(|(n, t)| new.unreadable.contains(*n) && l.good.theme_texts.get(*n) != Some(*t)).map(|(n, _)| n.clone()) {
            return Err(bad_args(
                format!("themes/{n}.toml exists but cannot be read (not UTF-8, over 1 MiB, or unreadable), so it was not overwritten"),
                "Move it aside or fix it, then try again.",
            ));
        }
        // Check the document as it was asked for, before anything is rendered or pruned, so a
        // setting that does not exist is refused whatever it holds (an empty table included).
        config::normalize_nulls(&mut new.user);
        new.themes = new
            .theme_texts
            .iter()
            .map(|(n, t)| {
                (
                    n.clone(),
                    config::parse_document(t).unwrap_or_else(|_| json!({ "__broken": "not valid TOML" })),
                )
            })
            .collect();
        let asked = self.validate_state(&new);
        if !asked.issues.is_empty() {
            return Err(invalid(&asked.issues, &asked.warnings, "refused"));
        }
        // Edit the text on disk (re-read under the lock) so a person's comments and layout stay.
        let plain = config::to_toml_checked(&new.user).map_err(|e| io_err("cannot write the document as TOML", e))?;
        new.config_text = if l.file_issues.is_empty() {
            config::edit_toml(&l.good.config_text, &l.good.user, &new.user).unwrap_or(plain)
        } else {
            plain
        };
        // What would be on disk must be what was checked.
        let parsed = config::parse_document(&new.config_text).map_err(|i| io_err("the rendered document does not read back", i.reason))?;
        if config::pruned(&parsed) != config::pruned(&new.user) {
            return Err(io_err("the rendered document differs from the one checked", "nothing was written"));
        }
        new.user = config::pruned(&parsed);
        let val = self.validate_state(&new);
        if !val.issues.is_empty() {
            return Err(invalid(&val.issues, &val.warnings, "refused"));
        }
        let same = new.user == l.good.user
            && new.theme_texts.keys().eq(l.good.theme_texts.keys())
            && new.themes == l.good.themes
            && l.file_issues.is_empty();
        if same {
            return Ok(self.applied(&new, &l.good, None, summary, false));
        }
        let h = self.history();
        let now = history::now_rfc3339();
        if h.latest().is_none() {
            // The first recorded change: keep what was there so an undo can go back to it.
            h.record(
                &now,
                "system",
                "the configuration before the first recorded change",
                &l.good.config_text,
                &l.good.theme_texts,
            )
            .map_err(|e| io_err("cannot write history", e))?;
        }
        let aside = if strict { vec![] } else { self.keep_aside(&l, &new) };
        let removed: Vec<String> = l.good.theme_texts.keys().filter(|k| !new.theme_texts.contains_key(*k)).cloned().collect();
        self.write_files(&new, &removed)?;
        let version = h
            .record(&now, caller, &summary, &new.config_text, &new.theme_texts)
            .map_err(|e| io_err("cannot write history", e))?;
        let mut a = self.applied(&new, &l.good, Some(version), summary, true);
        a.kept_aside = aside;
        Ok(a)
    }

    /// Notices a hand edit: if the files differ from the newest history version and hold, records
    /// the edit as `user` and returns it to apply. `Err` carries what is wrong with the file; the
    /// last good config keeps running.
    pub fn observe(&self) -> Result<Option<Applied>, Vec<Issue>> {
        let _lock = match self.lock() {
            Ok(l) => l,
            Err(_) => return Ok(None),
        };
        self.observe_locked()
    }

    /// [`Service::observe`] with the lock already held.
    fn observe_locked(&self) -> Result<Option<Applied>, Vec<Issue>> {
        let st = self.read_state();
        let h = self.history();
        let latest = h.latest();
        if let Some(v) = &latest {
            let prev = self.state_of(v);
            if prev.user == st.user && prev.themes == st.themes && st.syntax.is_empty() {
                return Ok(None);
            }
        } else if st.config_text.is_empty() && st.theme_texts.is_empty() {
            return Ok(None);
        }
        let val = self.validate_state(&st);
        if !val.issues.is_empty() {
            return Err(val.issues);
        }
        let base = latest
            .as_ref()
            .map(|v| self.state_of(v))
            .unwrap_or_else(State::empty);
        let mut ch: Vec<String> = changes(&base.user, &st.user)
            .into_iter()
            .map(|c| c.path)
            .collect();
        ch.extend(theme_changes(&base.theme_texts, &st.theme_texts));
        let summary = if latest.is_none() {
            "config.toml as found".to_string()
        } else {
            format!("edited by hand: {}", list(&ch))
        };
        let version = h
            .record(
                &history::now_rfc3339(),
                "user",
                &summary,
                &st.config_text,
                &st.theme_texts,
            )
            .ok();
        Ok(Some(self.applied(&st, &base, version, summary, true)))
    }

    // ---- commands ----------------------------------------------------------------------------

    /// Runs one command (`config_get`, `config_set`, ... `theme_delete`). `caller` is `user`,
    /// `settings` or `agent:<name>`.
    pub fn dispatch(&self, op: &str, args: &Value, caller: &str) -> Outcome {
        let caller = if history::caller_ok(caller) {
            caller
        } else {
            "user"
        };
        let text_arg = |k: &str| args.get(k).and_then(Value::as_str);
        let path_arg = |k: &str| -> Result<Vec<String>, Envelope> {
            let Some(p) = text_arg(k) else {
                return Err(bad_args(
                    format!("{k} is required"),
                    "Paths use dots: animation.dock.in.duration_ms, keys.bindings.\"mod+1\".",
                ));
            };
            config::parse_path(p).map_err(|e| bad_args(format!("bad path {p:?}: {e}"), "Paths use dots, quotes around a name with punctuation: keys.bindings.\"mod+1\"."))
        };
        match op {
            "config_schema" => Outcome::only(Envelope::ok(config::schema_json())),
            "config_get" => {
                let (_, _, l) = self.current();
                let eff = l.validated.effective.clone().expect("the running state is valid");
                let all_pending = self.activate(&eff).1;
                let pending = self.pending_json(&all_pending);
                let note = if l.file_issues.is_empty() {
                    Value::Null
                } else {
                    json!("config.toml has errors; this is the last good config")
                };
                match text_arg("path").filter(|p| !p.is_empty()) {
                    None => Outcome::only(Envelope::ok(
                        json!({ "value": eff.doc, "source": l.source_name(), "note": note, "pending": pending }),
                    )),
                    Some(p) => {
                        let path = match config::parse_path(p) {
                            Ok(x) => x,
                            Err(e) => {
                                return Outcome::only(bad_args(
                                    format!("bad path {p:?}: {e}"),
                                    "Paths use dots: animation.speed, keys.bindings.\"mod+1\".",
                                ))
                            }
                        };
                        match config::get_path(&eff.doc, &path) {
                            Some(v) => {
                                // By segments, not text: `keys.bindings.mod+e` and `keys.bindings."mod+e"` (and a
                                // chord spelled another way) are the same entry.
                                let mine: Vec<&Value> = all_pending.iter().zip(&pending).filter(|(e, _)| pending_under(e, &path, &eff.modifier)).map(|(_, j)| j).collect();
                                Outcome::only(Envelope::ok(json!({ "path": p, "value": v, "note": note, "pending": mine })))
                            }
                            None => Outcome::only(not_found(format!("{p} has no value"), "`baneyspaces config get` lists every setting; `baneyspaces config schema` says what each may be.")),
                        }
                    }
                }
            }
            "config_validate" => {
                let Some(t) = text_arg("text") else {
                    return Outcome::only(bad_args(
                        "a document is required",
                        "Pass a TOML or JSON document (a file, or - for stdin).",
                    ));
                };
                Outcome::only(self.validate_text(t))
            }
            "config_history" => {
                let h = self.history().all();
                let cur = h.last().map(|v| v.seq);
                let versions: Vec<Value> = h.iter().rev().map(Version::summary_json).collect();
                Outcome::only(Envelope::ok(
                    json!({ "current": cur, "keep": history::KEEP, "versions": versions }),
                ))
            }
            "config_diff" => match args.get("version") {
                None | Some(Value::Null) => Outcome::only(self.diff(None)),
                Some(v) => match v.as_u64() {
                    Some(n) => Outcome::only(self.diff(Some(n))),
                    None => Outcome::only(bad_args(format!("version must be a whole number, not {v}"), "baneyspaces config diff [version]; `config history` lists the versions.")),
                },
            },
            "theme_list" => Outcome::only(self.theme_list()),
            "theme_show" => Outcome::only(match text_arg("name") {
                Some(n) => self.theme_show(n),
                None => bad_args(
                    "name is required",
                    "`baneyspaces theme list` shows the names.",
                ),
            }),
            "config_set" => {
                let path = match path_arg("path") {
                    Ok(p) => p,
                    Err(e) => return Outcome::only(e),
                };
                let value = match (args.get("value_text").and_then(Value::as_str), args.get("value")) {
                    (Some(t), _) => parse_value_text(t),
                    (None, Some(v)) => v.clone(),
                    _ => return Outcome::only(bad_args("a value is required", "baneyspaces config set <path> <value>; JSON for numbers, booleans, arrays and tables.")),
                };
                let shown = path_string(&path);
                let v2 = value.clone();
                self.finish(
                    self.mutate(caller, true, |base| {
                        let mut st = base.clone();
                        config::set_path(&mut st.user, &path, v2.clone()).map_err(|e| {
                            bad_args(
                                format!("cannot set {shown}: {e}"),
                                "Check the path with `baneyspaces config schema`.",
                            )
                        })?;
                        Ok((st, format!("set {shown} = {}", short(&v2))))
                    }),
                    Some(&path),
                )
            }
            "config_unset" => {
                let path = match path_arg("path") {
                    Ok(p) => p,
                    Err(e) => return Outcome::only(e),
                };
                let shown = path_string(&path);
                self.finish(
                    self.mutate(caller, true, |base| {
                        let mut st = base.clone();
                        config::unset_path(&mut st.user, &path);
                        Ok((st, format!("unset {shown}")))
                    }),
                    Some(&path),
                )
            }
            "config_apply" => {
                let Some(t) = text_arg("text") else {
                    return Outcome::only(bad_args(
                        "a document is required",
                        "Pass a TOML or JSON document (a file, or - for stdin).",
                    ));
                };
                let doc = match config::parse_document(t) {
                    Ok(d) => d,
                    Err(i) => return Outcome::only(invalid(&[i], &[], "cannot read the document")),
                };
                self.finish(
                    self.mutate(caller, true, |base| {
                        let mut st = base.clone();
                        st.user = doc.clone();
                        let ch: Vec<String> = changes(&base.user, &doc)
                            .into_iter()
                            .map(|c| c.path)
                            .collect();
                        Ok((
                            st,
                            format!(
                                "applied a whole document ({})",
                                if ch.is_empty() {
                                    "no change".to_string()
                                } else {
                                    list(&ch)
                                }
                            ),
                        ))
                    }),
                    None,
                )
            }
            "config_reset" => {
                let section = text_arg("section").filter(|s| !s.is_empty() && *s != "all");
                if let Some(s) = section {
                    if !["keys", "theme", "animation", "behavior", "rules", "hooks"].contains(&s) {
                        return Outcome::only(bad_args(format!("{s:?} is not a section"), "Sections: keys, theme, animation, behavior, rules, hooks. No section resets everything."));
                    }
                }
                let out = self.finish(
                    self.mutate(caller, false, |base| {
                        let mut st = base.clone();
                        match section {
                            Some(s) => {
                                if let Some(o) = st.user.as_object_mut() {
                                    o.remove(s);
                                }
                            }
                            None => st.user = json!({}),
                        }
                        Ok((st, format!("reset {}", section.unwrap_or("everything"))))
                    }),
                    None,
                );
                out
            }
            "config_undo" => {
                let n = match args.get("n") {
                    None | Some(Value::Null) => 1,
                    Some(v) => match v.as_u64() {
                        Some(n) if n >= 1 => n,
                        _ => return Outcome::only(bad_args(format!("n must be a whole number, 1 or more, not {v}"), "baneyspaces config undo [n]")),
                    },
                };
                self.undo(n, caller)
            }
            "config_approve" | "config_approve_all" => Outcome::only(Envelope::err(
                "not_in_scope",
                "Approving an executable setting (a hook, or a key binding that runs a command or changes the configuration) is done by a click in Settings, never by a command",
                Retry::Never,
                "Open BaneySpaces Settings and Approve the entry in the pending list. `baneyspaces config get` shows what is waiting.",
            )),
            "theme_set" => {
                let Some(n) = text_arg("name") else {
                    return Outcome::only(bad_args(
                        "name is required",
                        "`baneyspaces theme list` shows the names.",
                    ));
                };
                self.dispatch(
                    "config_set",
                    &json!({ "path": "theme.name", "value": n }),
                    caller,
                )
            }
            "theme_create" => self.theme_create(args, caller),
            "theme_delete" => {
                let Some(n) = text_arg("name") else {
                    return Outcome::only(bad_args(
                        "name is required",
                        "`baneyspaces theme list` shows the names.",
                    ));
                };
                if config::builtin_theme_names().iter().any(|b| b == n) {
                    return Outcome::only(bad_args(
                        format!("{n} is a built-in theme and cannot be deleted"),
                        "Custom themes are the files in themes/.",
                    ));
                }
                let exists = self.read_state().theme_texts.contains_key(n);
                if !exists {
                    return Outcome::only(not_found(
                        format!("no custom theme named {n}"),
                        "`baneyspaces theme list` shows the names.",
                    ));
                }
                let n = n.to_string();
                self.finish(
                    self.mutate(caller, true, |base| {
                        let mut st = base.clone();
                        st.theme_texts.remove(&n);
                        Ok((st, format!("deleted theme {n}")))
                    }),
                    None,
                )
            }
            other => Outcome::only(bad_args(
                format!("unknown operation {other:?}"),
                "Run `baneyspaces help`.",
            )),
        }
    }

    fn finish(&self, r: Result<Applied, Envelope>, path: Option<&[String]>) -> Outcome {
        match r {
            Err(e) => Outcome::only(e),
            Ok(a) => {
                let value = path.and_then(|p| config::get_path(&a.effective.doc, p).cloned());
                let data = json!({
                    "changed": a.changed,
                    "version": a.version,
                    "summary": a.summary,
                    "value": value,
                    "changes": a.changes.iter().map(Change::to_json).collect::<Vec<_>>(),
                    "warnings": a.warnings.iter().map(Issue::to_json).collect::<Vec<_>>(),
                    "pending": self.pending_json(&a.pending),
                    "kept_invalid_files": a.kept_aside,
                });
                Outcome {
                    env: Envelope::ok(data),
                    applied: a.changed.then_some(a),
                }
            }
        }
    }

    /// Checks a document without applying it.
    pub fn validate_text(&self, text: &str) -> Envelope {
        let doc = match config::parse_document(text) {
            Ok(d) => d,
            Err(i) => return invalid(&[i], &[], "cannot read the document"),
        };
        let st = self.read_state();
        let v = config::validate(&doc, &self.env, &st.themes);
        if !v.issues.is_empty() {
            return invalid(&v.issues, &v.warnings, "invalid");
        }
        let base = self.load().good;
        let ch: Vec<Value> = changes(&base.user, &doc)
            .iter()
            .map(Change::to_json)
            .collect();
        Envelope::ok(
            json!({ "valid": true, "warnings": v.warnings.iter().map(Issue::to_json).collect::<Vec<_>>(), "would_change": ch }),
        )
    }

    fn diff(&self, version: Option<u64>) -> Envelope {
        let l = self.load();
        let cur = &l.good.user;
        match version {
            None => {
                let defaults = config::defaults(&self.env);
                let mut m = vec![];
                let d = flat(&defaults);
                for (path, to) in flat(cur) {
                    m.push(
                        Change {
                            from: d.get(&path).cloned(),
                            path,
                            to: Some(to),
                        }
                        .to_json(),
                    );
                }
                Envelope::ok(json!({ "against": "defaults", "changes": m }))
            }
            Some(n) => match self.history().read(n) {
                None => not_found(
                    format!("no version {n} in history"),
                    "`baneyspaces config history` lists the versions kept.",
                ),
                Some(v) => {
                    let old = self.state_of(&v);
                    let mut ch: Vec<Value> = changes(&old.user, cur)
                        .iter()
                        .map(Change::to_json)
                        .collect();
                    ch.extend(
                        theme_changes(&old.theme_texts, &l.good.theme_texts)
                            .into_iter()
                            .map(|t| json!({ "path": "themes", "from": null, "to": t })),
                    );
                    Envelope::ok(json!({ "against": format!("version {n}"), "changes": ch }))
                }
            },
        }
    }

    /// An undo is a change like any other: it is recorded as a new version holding the older state,
    /// and nothing in history is deleted. Repeating it goes further back. An agent may undo only
    /// versions it made itself; `user` and `settings` may undo anything.
    fn undo(&self, n: u64, caller: &str) -> Outcome {
        let _lock = match self.lock() {
            Ok(l) => l,
            Err(e) => return Outcome::only(e),
        };
        // A hand edit not yet noticed by the watcher is recorded first, as the user's, so an undo can never
        // write over it unrecorded (and an agent's undo then sees it on top and is refused).
        let _ = self.observe_locked();
        let h = self.history();
        let all = h.all();
        // The live versions that are still in history, oldest first.
        let stack: Vec<&Version> = History::live_seqs(&all).into_iter().filter_map(|q| all.iter().find(|v| v.seq == q)).collect();
        let n_us = n.min(usize::MAX as u64) as usize;
        if stack.len() < 2 {
            return Outcome::only(not_found("there is nothing to undo", "`baneyspaces config history` lists the versions."));
        }
        if n_us >= stack.len() {
            return Outcome::only(bad_args(format!("only {} version(s) can be undone", stack.len() - 1), "baneyspaces config undo [n]"));
        }
        let popped: Vec<&Version> = stack[stack.len() - n_us..].to_vec();
        let target = stack[stack.len() - 1 - n_us];
        if caller.starts_with("agent:") {
            if let Some(other) = popped.iter().find(|v| v.caller != caller) {
                return Outcome::only(Envelope::err(
                    "not_in_scope",
                    format!("{caller} may undo only its own changes; version {} was made by {}", other.seq, other.caller),
                    Retry::Never,
                    "Undo fewer versions, or ask the user to undo the rest.",
                ));
            }
        }
        let new = self.state_of(target);
        let val = self.validate_state(&new);
        if !val.issues.is_empty() {
            return Outcome::only(invalid(&val.issues, &val.warnings, &format!("version {} no longer holds under the current rules", target.seq)));
        }
        let l = self.load();
        let aside = self.keep_aside(&l, &new);
        let on_disk = self.read_state();
        let removed: Vec<String> = on_disk.theme_texts.keys().filter(|k| !new.theme_texts.contains_key(*k)).cloned().collect();
        let mut new = new;
        new.unreadable = on_disk.unreadable.clone();
        if let Err(e) = self.write_files(&new, &removed) {
            return Outcome::only(e);
        }
        let summary = format!("undo {n}: back to version {} (stepped over {})", target.seq, popped.iter().rev().map(|v| v.seq.to_string()).collect::<Vec<_>>().join(", "));
        let version = match h.record_with(&history::now_rfc3339(), caller, &summary, &new.config_text, &new.theme_texts, n) {
            Ok(v) => v,
            Err(e) => return Outcome::only(io_err("cannot write history", e)),
        };
        let mut a = self.applied(&new, &l.good, Some(version), summary, true);
        a.kept_aside = aside;
        a.changed = !a.changes.is_empty() || l.good.theme_texts != new.theme_texts;
        let data = json!({
            "undone": popped.iter().map(|v| v.summary_json()).collect::<Vec<_>>(),
            "restored_version": target.seq,
            "version": version,
            "summary": a.summary,
            "caller": caller,
            "changes": a.changes.iter().map(Change::to_json).collect::<Vec<_>>(),
            "pending": self.pending_json(&a.pending),
            "kept_invalid_files": a.kept_aside,
        });
        Outcome { env: Envelope::ok(data), applied: Some(a) }
    }

    fn theme_list(&self) -> Envelope {
        let (eff, _, l) = self.current();
        let cur = eff.doc["theme"]["name"].as_str().unwrap_or("").to_string();
        let mut items: Vec<Value> = config::builtin_theme_names()
            .into_iter()
            .map(|n| json!({ "name": n, "kind": "built-in", "extends": null, "current": n == cur }))
            .collect();
        for (n, t) in &l.good.themes {
            items.push(json!({ "name": n, "kind": "custom", "extends": t.get("extends"), "has_palette": t.get("palette").is_some(), "current": *n == cur }));
        }
        Envelope::ok(
            json!({ "themes": items, "current": cur, "palettes": config::builtin_palette_names() }),
        )
    }

    fn theme_show(&self, name: &str) -> Envelope {
        let (_, _, l) = self.current();
        match config::theme_chain(name, &l.good.themes) {
            Err(why) => not_found(why, "`baneyspaces theme list` shows the names."),
            Ok(c) => Envelope::ok(json!({
                "name": name,
                "kind": if l.good.themes.contains_key(name) { "custom" } else { "built-in" },
                "chain": c.chain,
                "tokens": c.tokens,
                "palette": c.palette.map(|(n, p)| json!({ "from": n, "roles": p })),
            })),
        }
    }

    fn theme_create(&self, args: &Value, caller: &str) -> Outcome {
        let (Some(name), Some(base)) = (
            args.get("name").and_then(Value::as_str),
            args.get("extends").and_then(Value::as_str),
        ) else {
            return Outcome::only(bad_args(
                "a name and a theme to extend are required",
                "baneyspaces theme create <name> --extends <base>",
            ));
        };
        if !crate::action::is_name(name) || name == "auto" {
            return Outcome::only(bad_args(
                format!("{name:?} is not a theme name"),
                "A name is lowercase letters, digits, - and _ (at most 32).",
            ));
        }
        if config::builtin_theme_names().iter().any(|b| b == name) {
            return Outcome::only(bad_args(
                format!("{name} is a built-in theme"),
                "Pick another name, or set tokens with `config set theme.override...`.",
            ));
        }
        let mut doc = Map::new();
        doc.insert("extends".into(), json!(base));
        if let Some(t) = args.get("tokens") {
            let Some(o) = t.as_object() else {
                return Outcome::only(bad_args(
                    "tokens must be a table of theme tokens",
                    "See `baneyspaces config schema`, $defs.custom_theme.",
                ));
            };
            for (k, v) in o {
                doc.insert(k.clone(), v.clone());
            }
        }
        if let Some(p) = args.get("palette") {
            doc.insert("palette".into(), p.clone());
        }
        if let Some(l) = args.get("label") {
            doc.insert("label".into(), l.clone());
        }
        let doc = Value::Object(doc);
        let mut doc = doc;
        config::normalize_token_nulls(&mut doc);
        let rendered = match config::to_toml_checked(&doc) {
            Ok(r) => r,
            Err(e) => return Outcome::only(io_err("cannot write the theme as TOML", e)),
        };
        let text = format!("# Custom theme {name}. Any token in spec/themes.json can be set here; `baneyspaces theme show {base}` lists them.\n{rendered}");
        let name = name.to_string();
        self.finish(
            self.mutate(caller, true, |b| {
                if b.theme_texts.contains_key(&name) {
                    return Err(bad_args(
                        format!("a theme named {name} already exists"),
                        "Delete it first (`baneyspaces theme delete`), or pick another name.",
                    ));
                }
                let mut st = b.clone();
                st.theme_texts.insert(name.clone(), text.clone());
                let mut themes = st.themes.clone();
                themes.insert(name.clone(), doc.clone());
                let issues = config::validate_theme_file(&name, &doc, &themes);
                if !issues.is_empty() {
                    return Err(invalid(&issues, &[], "refused"));
                }
                Ok((
                    st,
                    format!(
                        "created theme {name} extending {}",
                        doc["extends"].as_str().unwrap_or("")
                    ),
                ))
            }),
            None,
        )
    }
}

impl Loaded {
    pub fn source_name(&self) -> &'static str {
        match self.source {
            Source::File => "file",
            Source::LastGood(_) => "last_good",
            Source::Defaults => "defaults",
        }
    }
}

fn short(v: &Value) -> String {
    let s = v.to_string();
    if s.chars().count() > 60 {
        format!("{}...", s.chars().take(57).collect::<String>())
    } else {
        s
    }
}

/// The platform's environment for a config directory.
pub fn env_for(platform: Platform) -> Env {
    Env::new(platform)
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Dir(PathBuf);
    impl Dir {
        fn new(tag: &str) -> Self {
            let d = std::env::temp_dir().join(format!("bs-store-{tag}-{}", std::process::id()));
            let _ = fs::remove_dir_all(&d);
            fs::create_dir_all(&d).unwrap();
            Dir(d)
        }
    }
    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn svc(d: &Dir) -> Service {
        Service::new(&d.0, Env::new(Platform::Linux)).with_approvals(d.0.join("state/approvals.json"))
    }

    fn run(s: &Service, op: &str, args: Value, caller: &str) -> Outcome {
        s.dispatch(op, &args, caller)
    }

    fn code(o: &Outcome) -> String {
        o.env
            .error
            .as_ref()
            .map(|e| e.code.clone())
            .unwrap_or_else(|| "ok".into())
    }

    #[test]
    fn set_get_unset_with_history_and_callers() {
        let d = Dir::new("sgu");
        let s = svc(&d);
        let o = run(
            &s,
            "config_set",
            json!({ "path": "animation.dock.in.duration_ms", "value_text": "90" }),
            "agent:claude",
        );
        assert!(o.env.ok, "{:?}", o.env);
        assert!(o.applied.as_ref().unwrap().changed);
        assert_eq!(
            fs::read_to_string(d.0.join("config.toml")).unwrap().trim(),
            "[animation.dock.in]\nduration_ms = 90"
        );
        let g = run(
            &s,
            "config_get",
            json!({ "path": "animation.dock.in" }),
            "user",
        );
        assert_eq!(g.env.data.unwrap()["value"]["duration_ms"], 90);
        let h = run(&s, "config_history", json!({}), "user")
            .env
            .data
            .unwrap();
        let v = h["versions"].as_array().unwrap();
        assert_eq!(v.len(), 2, "the baseline and the change: {h}");
        assert_eq!(v[0]["caller"], "agent:claude");
        assert_eq!(v[1]["caller"], "system");
        assert!(v[0]["summary"]
            .as_str()
            .unwrap()
            .starts_with("set animation.dock.in.duration_ms = 90"));
        // Setting it again changes nothing and records nothing.
        let again = run(
            &s,
            "config_set",
            json!({ "path": "animation.dock.in.duration_ms", "value_text": "90" }),
            "user",
        );
        assert!(again.applied.is_none());
        assert_eq!(again.env.data.as_ref().unwrap()["changed"], false);
        let u = run(
            &s,
            "config_unset",
            json!({ "path": "animation.dock.in.duration_ms" }),
            "user",
        );
        assert!(u.applied.is_some());
        assert_eq!(fs::read_to_string(d.0.join("config.toml")).unwrap(), "");
        assert_eq!(
            run(&s, "config_history", json!({}), "user")
                .env
                .data
                .unwrap()["versions"]
                .as_array()
                .unwrap()
                .len(),
            3
        );
    }

    #[test]
    fn executable_settings_wait_for_a_click_and_the_click_is_not_a_command() {
        let d = Dir::new("pending");
        let s = svc(&d);
        // Free for an agent: plain actions, themes, animation, behavior.
        for (p, v) in [("keys.bindings.mod+j", "move 2"), ("theme.name", "minimal"), ("animation.speed", "0.5"), ("behavior.follow_focus", "false")] {
            let o = run(&s, "config_set", json!({ "path": p, "value_text": v }), "agent:tester");
            assert!(o.env.ok, "{p}: {:?}", o.env);
            assert!(o.env.data.as_ref().unwrap()["pending"].as_array().unwrap().is_empty(), "{p} is not executable");
        }
        // Pending: a hook, an exec binding, a binding that changes the configuration.
        for (p, v) in [("hooks.on_switch", "echo hi"), ("keys.bindings.mod+h", "exec foot"), ("keys.bindings.mod+k", "config set theme.name omarchy"), ("keys.bindings.mod+l", "theme set omarchy")] {
            let o = run(&s, "config_set", json!({ "path": p, "value_text": v }), "agent:tester");
            assert!(o.env.ok, "{p}: {:?}", o.env);
            let pend = o.env.data.as_ref().unwrap()["pending"].as_array().unwrap().clone();
            assert!(pend.iter().any(|e| e["value"] == v), "{p} should be pending: {pend:?}");
        }
        // They are inert: what runs has none of them.
        let (active, _, _) = s.current();
        assert_eq!(active.doc["hooks"]["on_switch"], "");
        assert!(active.bindings.iter().all(|b| !["mod+h", "mod+k", "mod+l"].contains(&b.spelling.as_str())));
        assert!(active.bindings.iter().any(|b| b.spelling == "mod+j"));
        // `config get` shows them, with who wrote them as a hint.
        let g = run(&s, "config_get", json!({}), "user").env.data.unwrap();
        assert_eq!(g["value"]["keys"]["bindings"]["mod+h"], "exec foot");
        let e = g["pending"].as_array().unwrap().iter().find(|e| e["path"] == "hooks.on_switch").unwrap();
        assert_eq!(e["written_by_hint"], "agent:tester");
        assert_eq!(s.runtime_json()["pending"].as_array().unwrap().len(), 4);
        // No operation approves.
        for op in ["config_approve", "config_approve_all"] {
            let o = run(&s, op, json!({ "path": "hooks.on_switch", "value": "echo hi" }), "user");
            assert_eq!(code(&o), "not_in_scope", "{op}");
            assert!(o.env.error.unwrap().message.contains("click in Settings"));
        }
        assert_eq!(s.current().0.doc["hooks"]["on_switch"], "");
        // The Settings UI's write approves that one entry.
        s.approve("hooks.on_switch", "echo hi").unwrap();
        assert_eq!(s.current().0.doc["hooks"]["on_switch"], "echo hi");
        assert_eq!(s.runtime_json()["pending"].as_array().unwrap().len(), 3);
        // A change to the value makes it pending again.
        run(&s, "config_set", json!({ "path": "hooks.on_switch", "value_text": "echo hi; evil" }), "agent:tester");
        assert_eq!(s.current().0.doc["hooks"]["on_switch"], "");
        // Setting it back to the approved text is approved again (the approval is per (path, value)).
        run(&s, "config_set", json!({ "path": "hooks.on_switch", "value_text": "echo hi" }), "agent:tester");
        assert_eq!(s.current().0.doc["hooks"]["on_switch"], "echo hi");
        // A hand edit of an executable setting waits just the same.
        fs::write(d.0.join("config.toml"), "[hooks]\non_window_open = \"touch /tmp/x\"\n").unwrap();
        s.observe().unwrap();
        assert_eq!(s.current().0.doc["hooks"]["on_window_open"], "");
        assert_eq!(s.runtime_json()["pending"][0]["written_by_hint"], "user");
    }

    #[test]
    fn the_writer_hint_survives_fifty_changes_but_is_only_a_hint_and_approval_does_not_depend_on_it() {
        let d = Dir::new("hint");
        let s = svc(&d);
        run(&s, "config_set", json!({ "path": "hooks.on_switch", "value_text": "echo hi" }), "agent:x");
        for i in 0..60 {
            run(&s, "config_set", json!({ "path": "animation.speed", "value_text": format!("0.{}", 1 + i % 2) }), "user");
        }
        // The version that set it was pruned: the hint is gone, and the hook is still pending.
        let p = &s.runtime_json()["pending"][0];
        assert_eq!(p["path"], "hooks.on_switch");
        assert!(p["written_by_hint"].is_null(), "{p}");
        assert_eq!(s.current().0.doc["hooks"]["on_switch"], "");
    }

    #[test]
    fn a_commented_file_keeps_its_comments_through_set_and_unset() {
        let d = Dir::new("comments");
        let s = svc(&d);
        let original = "# my BaneySpaces settings\n\n[animation]\n# slower, I like to see it\nspeed = 1.5   # was 1.0\n\n[keys.bindings]\n# a terminal on mod+return\n\"mod+return\" = \"exec foot\"\n\n# behavior below\n[behavior]\nfollow_focus = true\n";
        fs::write(d.0.join("config.toml"), original).unwrap();
        let o = run(&s, "config_set", json!({ "path": "keys.bindings.mod+h", "value_text": "exec kitty" }), "agent:x");
        assert!(o.env.ok, "{:?}", o.env);
        let t = fs::read_to_string(d.0.join("config.toml")).unwrap();
        for keep in ["# my BaneySpaces settings", "# slower, I like to see it", "speed = 1.5   # was 1.0", "# a terminal on mod+return", "# behavior below", "\"mod+return\" = \"exec foot\""] {
            assert!(t.contains(keep), "lost {keep:?} in:\n{t}");
        }
        assert!(t.contains("\"mod+h\" = \"exec kitty\""), "{t}");
        // A change inside an existing table.
        assert!(run(&s, "config_set", json!({ "path": "animation.speed", "value_text": "0.8" }), "user").env.ok);
        let t = fs::read_to_string(d.0.join("config.toml")).unwrap();
        assert!(t.contains("speed = 0.8") && t.contains("# slower, I like to see it") && t.contains("# my BaneySpaces settings"), "{t}");
        // A new section arrives without disturbing the rest.
        assert!(run(&s, "config_set", json!({ "path": "behavior.dock.edge", "value_text": "left" }), "user").env.ok);
        // Unset takes out its own line and keeps the others' comments.
        assert!(run(&s, "config_unset", json!({ "path": "keys.bindings.mod+h" }), "user").env.ok);
        assert!(run(&s, "config_unset", json!({ "path": "behavior.dock.edge" }), "user").env.ok);
        let t = fs::read_to_string(d.0.join("config.toml")).unwrap();
        assert!(!t.contains("mod+h") && !t.contains("edge"), "{t}");
        for keep in ["# my BaneySpaces settings", "# slower, I like to see it", "# a terminal on mod+return", "# behavior below", "\"mod+return\" = \"exec foot\"", "follow_focus = true"] {
            assert!(t.contains(keep), "lost {keep:?} in:\n{t}");
        }
        // History has the text as it was written, comments and all, and undo brings it back.
        assert!(run(&s, "config_undo", json!({ "n": 2 }), "user").env.ok);
        let t = fs::read_to_string(d.0.join("config.toml")).unwrap();
        assert!(t.contains("speed = 0.8") && t.contains("# slower, I like to see it") && t.contains("mod+h"), "{t}");
        // A reset of one section keeps the other sections' comments.
        assert!(run(&s, "config_reset", json!({ "section": "keys" }), "user").env.ok);
        let t = fs::read_to_string(d.0.join("config.toml")).unwrap();
        assert!(t.contains("# slower, I like to see it") && !t.contains("mod+return"), "{t}");
    }

    #[test]
    fn a_refused_change_writes_nothing_and_says_where() {
        let d = Dir::new("refuse");
        let s = svc(&d);
        run(
            &s,
            "config_set",
            json!({ "path": "animation.speed", "value_text": "1.5" }),
            "user",
        );
        let before = fs::read_to_string(d.0.join("config.toml")).unwrap();
        let h0 = fs::read_dir(d.0.join("history")).unwrap().count();
        for (path, val, want) in [
            (
                "animation.dock.in.duration_ms",
                "1500",
                "animation.dock.in.duration_ms",
            ),
            (
                "keys.bindings.\"super+shift+escape\"",
                "exec true",
                "keys.bindings.\"super+shift+escape\"",
            ),
            (
                "keys.bindings.mod+x",
                "launch it",
                "keys.bindings.\"mod+x\"",
            ),
            ("behavior.dock.edge", "top", "behavior.dock.edge"),
            ("keyz", "1", "keyz"),
        ] {
            let o = run(
                &s,
                "config_set",
                json!({ "path": path, "value_text": val }),
                "agent:x",
            );
            assert_eq!(code(&o), "config_invalid", "{path}");
            let e = o.env.error.unwrap();
            let issues = e.data.unwrap()["issues"].clone();
            assert!(
                issues.as_array().unwrap().iter().any(|i| i["path"] == want),
                "{path}: {issues}"
            );
            assert_eq!(e.retry, Retry::Never);
        }
        assert_eq!(fs::read_to_string(d.0.join("config.toml")).unwrap(), before);
        assert_eq!(fs::read_dir(d.0.join("history")).unwrap().count(), h0);
    }

    #[test]
    fn undo_is_recorded_history_is_never_deleted_and_repeating_goes_further_back() {
        let d = Dir::new("undo");
        let s = svc(&d);
        for (p, v) in [("animation.speed", "0.5"), ("behavior.follow_focus", "false"), ("behavior.dock.edge", "left")] {
            assert!(run(&s, "config_set", json!({ "path": p, "value_text": v }), "user").env.ok);
        }
        let hist = |s: &Service| run(s, "config_history", json!({}), "u").env.data.unwrap()["versions"].as_array().unwrap().clone();
        assert_eq!(hist(&s).len(), 4);
        let o = run(&s, "config_undo", json!({}), "agent:claude");
        assert_eq!(code(&o), "not_in_scope", "an agent may undo only its own changes: {:?}", o.env);
        let o = run(&s, "config_undo", json!({}), "user");
        assert!(o.env.ok, "{:?}", o.env);
        assert_eq!(s.current().0.doc["behavior"]["dock"]["edge"], "bottom");
        let h = hist(&s);
        assert_eq!(h.len(), 5, "the undo is a new version, nothing was deleted");
        assert_eq!(h[0]["caller"], "user");
        assert!(h[0]["summary"].as_str().unwrap().starts_with("undo 1: back to version 3"), "{}", h[0]["summary"]);
        assert!(h.iter().any(|v| v["summary"].as_str().unwrap().contains("behavior.dock.edge")), "the undone change is still in history");
        // Repeating goes further back, it does not redo.
        assert!(run(&s, "config_undo", json!({ "n": 1 }), "settings").env.ok);
        assert_eq!(fs::read_to_string(d.0.join("config.toml")).unwrap().trim(), "[animation]\nspeed = 0.5");
        assert_eq!(hist(&s).len(), 6);
        assert_eq!(hist(&s)[0]["caller"], "settings");
        assert!(run(&s, "config_undo", json!({}), "user").env.ok);
        assert_eq!(fs::read_to_string(d.0.join("config.toml")).unwrap(), "");
        assert_eq!(code(&run(&s, "config_undo", json!({}), "user")), "not_found", "only the baseline is left");
        assert_eq!(code(&run(&s, "config_undo", json!({ "n": 0 }), "user")), "invalid_args");
        assert_eq!(code(&run(&s, "config_undo", json!({ "n": "3x" }), "user")), "invalid_args");
        assert_eq!(code(&run(&s, "config_diff", json!({ "version": "v5" }), "user")), "invalid_args");
    }

    #[test]
    fn an_agent_may_undo_its_own_last_changes_only() {
        let d = Dir::new("undo-agent");
        let s = svc(&d);
        run(&s, "config_set", json!({ "path": "animation.speed", "value_text": "0.5" }), "user");
        run(&s, "config_set", json!({ "path": "behavior.follow_focus", "value_text": "false" }), "agent:a");
        run(&s, "config_set", json!({ "path": "behavior.dock.edge", "value_text": "left" }), "agent:a");
        assert_eq!(code(&run(&s, "config_undo", json!({}), "agent:b")), "not_in_scope");
        assert_eq!(code(&run(&s, "config_undo", json!({ "n": 3 }), "agent:a")), "not_in_scope", "the third is the user's");
        assert!(run(&s, "config_undo", json!({ "n": 2 }), "agent:a").env.ok);
        assert_eq!(s.current().0.doc["animation"]["speed"], 0.5);
        assert_eq!(s.current().0.doc["behavior"]["follow_focus"], true);
    }

    #[test]
    fn reset_one_section_or_everything_even_when_the_file_is_broken() {
        let d = Dir::new("reset");
        let s = svc(&d);
        run(
            &s,
            "config_set",
            json!({ "path": "keys.bindings.mod+h", "value_text": "exec foot" }),
            "user",
        );
        run(
            &s,
            "config_set",
            json!({ "path": "theme.name", "value_text": "minimal" }),
            "user",
        );
        run(
            &s,
            "config_set",
            json!({ "path": "animation.speed", "value_text": "0.5" }),
            "user",
        );
        let o = run(
            &s,
            "config_reset",
            json!({ "section": "keys" }),
            "agent:recovery",
        );
        assert!(o.env.ok);
        let t = fs::read_to_string(d.0.join("config.toml")).unwrap();
        assert!(
            !t.contains("mod+h") && t.contains("minimal") && t.contains("speed"),
            "{t}"
        );
        // Break the file by hand: set refuses, reset works from the last good config.
        fs::write(d.0.join("config.toml"), "[keys\nnot toml").unwrap();
        let o = run(
            &s,
            "config_set",
            json!({ "path": "animation.speed", "value_text": "2" }),
            "user",
        );
        assert_eq!(code(&o), "config_invalid");
        let o = run(&s, "config_reset", json!({ "section": "theme" }), "user");
        assert!(o.env.ok, "{:?}", o.env);
        assert!(o.env.data.as_ref().unwrap()["kept_invalid_files"][0].is_string());
        let t = fs::read_to_string(d.0.join("config.toml")).unwrap();
        assert!(!t.contains("minimal") && t.contains("speed"), "{t}");
        assert!(fs::read_dir(&d.0).unwrap().flatten().any(|e| e
            .file_name()
            .to_string_lossy()
            .starts_with("config.toml.invalid-")));
        assert!(run(&s, "config_reset", json!({}), "user").env.ok);
        assert_eq!(fs::read_to_string(d.0.join("config.toml")).unwrap(), "");
        assert_eq!(
            code(&run(
                &s,
                "config_reset",
                json!({ "section": "bogus" }),
                "user"
            )),
            "invalid_args"
        );
    }

    #[test]
    fn a_hand_edit_is_recorded_as_the_user_and_a_broken_one_keeps_the_last_good_running() {
        let d = Dir::new("hand");
        let s = svc(&d);
        run(
            &s,
            "config_set",
            json!({ "path": "animation.speed", "value_text": "0.5" }),
            "agent:a",
        );
        assert!(
            s.observe().unwrap().is_none(),
            "our own write is not an edit"
        );
        fs::write(
            d.0.join("config.toml"),
            "# mine\n[animation]\nspeed = 0.8\n",
        )
        .unwrap();
        let a = s.observe().unwrap().expect("an edit");
        assert!(
            a.summary.starts_with("edited by hand: animation.speed"),
            "{}",
            a.summary
        );
        let h = run(&s, "config_history", json!({}), "user")
            .env
            .data
            .unwrap();
        assert_eq!(h["versions"][0]["caller"], "user");
        assert_eq!(
            s.history().latest().unwrap().config,
            "# mine\n[animation]\nspeed = 0.8\n",
            "the text is kept as written"
        );
        fs::write(d.0.join("config.toml"), "[animation]\nspeed = \"fast\"\n").unwrap();
        let issues = s.observe().unwrap_err();
        assert_eq!(issues[0].path, "animation.speed");
        let rt = s.runtime_json();
        assert_eq!(
            rt["effective"]["animation"]["speed"], 0.8,
            "the last good config runs"
        );
        assert_eq!(rt["status"]["valid"], false);
        assert_eq!(rt["status"]["issues"][0]["path"], "animation.speed");
        // Fixing it applies it.
        fs::write(d.0.join("config.toml"), "[animation]\nspeed = 0.9\n").unwrap();
        assert!(s.observe().unwrap().is_some());
        assert_eq!(s.runtime_json()["status"]["valid"], true);
    }

    #[test]
    fn apply_replaces_the_whole_document_as_one_change() {
        let d = Dir::new("apply");
        let s = svc(&d);
        let o = run(
            &s,
            "config_apply",
            json!({ "text": "[keys.bindings]\n\"mod+h\" = \"exec foot\"\n[behavior]\nfollow_focus = false\n" }),
            "agent:a",
        );
        assert!(o.env.ok, "{:?}", o.env);
        let o = run(
            &s,
            "config_apply",
            json!({ "text": "{\"animation\":{\"speed\":0.7}}" }),
            "agent:a",
        );
        assert!(o.env.ok);
        let t = fs::read_to_string(d.0.join("config.toml")).unwrap();
        assert!(t.contains("speed") && !t.contains("follow_focus"), "{t}");
        let o = run(
            &s,
            "config_apply",
            json!({ "text": "[animation]\nspeed = 99\n[keys.bindings]\n\"mod+q\" = \"nope\"\n" }),
            "agent:a",
        );
        assert_eq!(code(&o), "config_invalid");
        let n = o.env.error.unwrap().data.unwrap()["issues"]
            .as_array()
            .unwrap()
            .len();
        assert_eq!(n, 2, "every problem comes back at once");
        assert_eq!(
            code(&run(&s, "config_apply", json!({ "text": "[x" }), "u")),
            "config_invalid"
        );
    }

    #[test]
    fn validate_checks_without_writing_and_says_what_would_change() {
        let d = Dir::new("validate");
        let s = svc(&d);
        let o = run(
            &s,
            "config_validate",
            json!({ "text": "[behavior]\nfollow_focus = false\n[hooks]\non_switch = \"echo hi\"\n" }),
            "user",
        );
        let data = o.env.data.unwrap();
        assert_eq!(data["valid"], true);
        assert_eq!(data["would_change"][0]["path"], "behavior.follow_focus");
        assert_eq!(data["warnings"][0]["path"], "hooks.on_switch");
        assert!(!d.0.join("config.toml").exists());
        assert_eq!(
            code(&run(
                &s,
                "config_validate",
                json!({ "text": "[behavior.dock]\nedge = \"top\"\n" }),
                "user"
            )),
            "config_invalid"
        );
    }

    #[test]
    fn diff_against_the_defaults_and_a_version() {
        let d = Dir::new("diff");
        let s = svc(&d);
        run(
            &s,
            "config_set",
            json!({ "path": "animation.speed", "value_text": "0.5" }),
            "user",
        );
        run(
            &s,
            "config_set",
            json!({ "path": "behavior.dock.edge", "value": "left" }),
            "user",
        );
        let data = run(&s, "config_diff", json!({}), "user").env.data.unwrap();
        let ch = data["changes"].as_array().unwrap();
        assert!(
            ch.iter()
                .any(|c| c["path"] == "animation.speed" && c["from"] == 1.0 && c["to"] == 0.5),
            "{data}"
        );
        let data = run(&s, "config_diff", json!({ "version": 2 }), "user")
            .env
            .data
            .unwrap();
        assert_eq!(data["changes"][0]["path"], "behavior.dock.edge");
        assert_eq!(
            code(&run(&s, "config_diff", json!({ "version": 99 }), "user")),
            "not_found"
        );
    }

    #[test]
    fn themes_create_set_show_delete() {
        let d = Dir::new("themes");
        let s = svc(&d);
        let o = run(
            &s,
            "theme_create",
            json!({ "name": "mine", "extends": "omarchy", "tokens": { "radius": { "tile": 3 } } }),
            "agent:t",
        );
        assert!(o.env.ok, "{:?}", o.env);
        assert!(d.0.join("themes/mine.toml").exists());
        assert_eq!(
            code(&run(
                &s,
                "theme_create",
                json!({ "name": "mine", "extends": "omarchy" }),
                "u"
            )),
            "invalid_args"
        );
        assert_eq!(
            code(&run(
                &s,
                "theme_create",
                json!({ "name": "omarchy", "extends": "minimal" }),
                "u"
            )),
            "invalid_args"
        );
        assert_eq!(
            code(&run(
                &s,
                "theme_create",
                json!({ "name": "../x", "extends": "minimal" }),
                "u"
            )),
            "invalid_args"
        );
        assert_eq!(
            code(&run(
                &s,
                "theme_create",
                json!({ "name": "bad", "extends": "ghost" }),
                "u"
            )),
            "config_invalid"
        );
        assert_eq!(
            code(&run(
                &s,
                "theme_create",
                json!({ "name": "bad2", "extends": "omarchy", "tokens": { "radius": { "tile": -1 } } }),
                "u"
            )),
            "config_invalid"
        );
        let l = run(&s, "theme_list", json!({}), "u").env.data.unwrap();
        assert!(l["themes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|t| t["name"] == "mine" && t["kind"] == "custom" && t["extends"] == "omarchy"));
        assert!(
            run(&s, "theme_set", json!({ "name": "mine" }), "agent:t")
                .env
                .ok
        );
        let show = run(&s, "theme_show", json!({ "name": "mine" }), "u")
            .env
            .data
            .unwrap();
        assert_eq!(show["tokens"]["radius"]["tile"], 3);
        assert_eq!(show["chain"], json!(["omarchy", "mine"]));
        // The active theme can't be deleted from under the config.
        let o = run(&s, "theme_delete", json!({ "name": "mine" }), "u");
        assert_eq!(code(&o), "config_invalid");
        assert!(d.0.join("themes/mine.toml").exists());
        assert_eq!(
            code(&run(&s, "theme_delete", json!({ "name": "omarchy" }), "u")),
            "invalid_args"
        );
        assert_eq!(
            code(&run(&s, "theme_set", json!({ "name": "ghost" }), "u")),
            "config_invalid"
        );
        run(&s, "theme_set", json!({ "name": "minimal" }), "u");
        assert!(
            run(&s, "theme_delete", json!({ "name": "mine" }), "u")
                .env
                .ok
        );
        assert!(!d.0.join("themes/mine.toml").exists());
        // Undo brings the theme file back with the config.
        assert!(run(&s, "config_undo", json!({}), "u").env.ok);
        let o = run(&s, "config_undo", json!({}), "u");
        assert!(o.env.ok, "{:?}", o.env);
        assert!(d.0.join("themes/mine.toml").exists());
    }

    #[test]
    fn a_theme_file_that_cannot_be_read_is_reported_and_never_deleted_or_written_over() {
        let d = Dir::new("unreadable");
        let s = svc(&d);
        fs::create_dir_all(d.0.join("themes")).unwrap();
        fs::write(d.0.join("themes/old.toml"), b"# caf\xe9 (Latin-1)\nextends = \"omarchy\"\n").unwrap();
        fs::write(d.0.join("themes/big.toml"), vec![b'#'; (1 << 20) + 10]).unwrap();
        assert!(run(&s, "config_set", json!({ "path": "animation.speed", "value_text": "0.5" }), "user").env.ok);
        assert!(d.0.join("themes/old.toml").exists() && d.0.join("themes/big.toml").exists(), "unreadable files stay");
        assert_eq!(fs::read(d.0.join("themes/old.toml")).unwrap(), b"# caf\xe9 (Latin-1)\nextends = \"omarchy\"\n");
        let v = run(&s, "config_validate", json!({ "text": "" }), "user").env.data.unwrap();
        let w: Vec<&str> = v["warnings"].as_array().unwrap().iter().filter_map(|w| w["path"].as_str()).collect();
        assert!(w.contains(&"themes.old") && w.contains(&"themes.big"), "{w:?}");
        // A theme created and deleted through the service still goes.
        assert!(run(&s, "theme_create", json!({ "name": "mine", "extends": "omarchy" }), "u").env.ok);
        assert!(run(&s, "theme_delete", json!({ "name": "mine" }), "u").env.ok);
        assert!(!d.0.join("themes/mine.toml").exists() && d.0.join("themes/old.toml").exists());
        // Undo and reset leave them too.
        assert!(run(&s, "config_undo", json!({ "n": 3 }), "u").env.ok);
        assert!(run(&s, "config_reset", json!({}), "u").env.ok);
        assert!(d.0.join("themes/old.toml").exists() && d.0.join("themes/big.toml").exists());
    }

    #[test]
    fn a_number_outside_the_range_is_refused_and_the_file_is_untouched() {
        let d = Dir::new("bignum");
        let s = svc(&d);
        fs::write(d.0.join("config.toml"), "# mine\n[animation]\nspeed = 0.5\n").unwrap();
        s.observe().unwrap();
        let before = fs::read_to_string(d.0.join("config.toml")).unwrap();
        for v in ["18446744073709551615", "9223372036854775808", "-1e999", "1e400"] {
            let o = run(&s, "config_set", json!({ "path": "animation.speed", "value_text": v }), "agent:x");
            assert_eq!(code(&o), "config_invalid", "{v}: {:?}", o.env);
        }
        let o = run(&s, "config_apply", json!({ "text": "{\"animation\":{\"speed\":18446744073709551615}}" }), "agent:x");
        assert_eq!(code(&o), "config_invalid");
        let o = run(&s, "config_set", json!({ "path": "behavior.switcher.hold_ms", "value_text": "18446744073709551615" }), "agent:x");
        assert_eq!(code(&o), "config_invalid");
        assert_eq!(fs::read_to_string(d.0.join("config.toml")).unwrap(), before);
    }

    #[test]
    fn apply_and_validate_refuse_the_same_documents() {
        let d = Dir::new("same");
        let s = svc(&d);
        for doc in ["{\"keyz\":{}}", "{\"behavior\":{\"nope\":{}}}", "{\"theme\":{\"override\":{\"radius\":{\"huge\":1}}}}", "{\"keys\":{\"bindings\":{\"mod+q\":null}}}"] {
            let v = run(&s, "config_validate", json!({ "text": doc }), "u");
            let a = run(&s, "config_apply", json!({ "text": doc }), "u");
            assert_eq!((code(&v), code(&a)), ("config_invalid".to_string(), "config_invalid".to_string()), "{doc}");
        }
        assert!(!d.0.join("config.toml").exists());
        // A JSON null shadow means "no shadow", and is written that way.
        let o = run(&s, "config_apply", json!({ "text": "{\"theme\":{\"override\":{\"shadow\":null,\"fill\":{\"material\":null}}}}" }), "u");
        assert!(o.env.ok, "{:?}", o.env);
        let t = fs::read_to_string(d.0.join("config.toml")).unwrap();
        assert!(t.contains("shadow = false") && t.contains("material = \"none\""), "{t}");
        let rt = s.runtime_json();
        assert!(rt["resolved"]["theme"]["tokens"]["shadow"].is_null());
        assert!(rt["resolved"]["theme"]["tokens"]["fill"]["material"].is_null());
    }

    #[test]
    fn reset_and_undo_keep_aside_every_broken_file_they_write_over() {
        let d = Dir::new("aside");
        let s = svc(&d);
        assert!(run(&s, "theme_create", json!({ "name": "mine", "extends": "omarchy" }), "u").env.ok);
        assert!(run(&s, "config_set", json!({ "path": "theme.name", "value_text": "mine" }), "u").env.ok);
        assert!(run(&s, "config_set", json!({ "path": "animation.speed", "value_text": "0.5" }), "u").env.ok);
        // A mistake in the theme in use (the last good config keeps running).
        fs::write(d.0.join("themes/mine.toml"), "extends = \"omarchy\"\n[radius]\ntile = -5\n").unwrap();
        assert!(s.observe().is_err());
        let o = run(&s, "config_undo", json!({}), "u");
        assert!(o.env.ok, "{:?}", o.env);
        let kept = o.env.data.as_ref().unwrap()["kept_invalid_files"].as_array().unwrap().clone();
        assert_eq!(kept.len(), 1, "{kept:?}");
        assert!(kept[0].as_str().unwrap().contains("mine.toml.invalid-"));
        assert!(fs::read_to_string(kept[0].as_str().unwrap()).unwrap().contains("tile = -5"));
        assert!(!fs::read_to_string(d.0.join("themes/mine.toml")).unwrap().contains("-5"));
        // The same through config.toml and undo.
        fs::write(d.0.join("config.toml"), "[animation\nbroken").unwrap();
        let o = run(&s, "config_undo", json!({}), "u");
        assert!(o.env.ok, "{:?}", o.env);
        assert!(fs::read_dir(&d.0).unwrap().flatten().any(|e| e.file_name().to_string_lossy().starts_with("config.toml.invalid-")));
    }

    #[test]
    fn config_get_shows_a_pending_entry_however_its_path_is_spelled() {
        let d = Dir::new("getpend");
        let s = svc(&d);
        run(&s, "config_set", json!({ "path": "keys.bindings.\"mod+e\"", "value_text": "exec foot" }), "agent:x");
        for p in ["keys.bindings.mod+e", "keys.bindings.\"mod+e\"", "keys.bindings", "keys"] {
            let g = run(&s, "config_get", json!({ "path": p }), "u");
            let data = g.env.data.unwrap_or_default();
            assert_eq!(data["pending"].as_array().map_or(0, Vec::len), 1, "{p}: {data}");
        }
        let g = run(&s, "config_get", json!({ "path": "keys.bindings.mod+1" }), "u").env.data.unwrap();
        assert!(g["pending"].as_array().unwrap().is_empty());
    }

    #[test]
    fn a_custom_palette_in_use_must_be_complete() {
        let d = Dir::new("palette");
        let s = svc(&d);
        fs::create_dir_all(d.0.join("themes")).unwrap();
        fs::write(d.0.join("themes/bad.toml"), "extends = \"omarchy\"\n[palette]\nbackground = \"#111111\"\n").unwrap();
        // Not in use: only a warning.
        assert!(run(&s, "config_set", json!({ "path": "animation.speed", "value_text": "0.5" }), "u").env.ok);
        // Selected as the palette: refused, and nothing reaches config.json.
        let o = run(&s, "config_set", json!({ "path": "theme.palette", "value_text": "bad" }), "agent:x");
        assert_eq!(code(&o), "config_invalid", "{:?}", o.env);
        let issues = o.env.error.unwrap().data.unwrap()["issues"].clone();
        assert!(issues.as_array().unwrap().iter().any(|i| i["path"].as_str().is_some_and(|p| p.starts_with("themes.bad.palette"))), "{issues}");
        assert_eq!(s.runtime_json()["resolved"]["theme"]["palette"]["name"].as_str().unwrap_or(""), "catppuccin", "the palette did not change");
    }

    #[test]
    fn theme_create_never_overwrites_a_file_it_cannot_read() {
        let d = Dir::new("create-unreadable");
        let s = svc(&d);
        fs::create_dir_all(d.0.join("themes")).unwrap();
        fs::write(d.0.join("themes/mine.toml"), b"# caf\xe9\nextends = \"omarchy\"\n").unwrap();
        let o = run(&s, "theme_create", json!({ "name": "mine", "extends": "minimal" }), "agent:x");
        assert_eq!(code(&o), "invalid_args", "{:?}", o.env);
        assert_eq!(fs::read(d.0.join("themes/mine.toml")).unwrap(), b"# caf\xe9\nextends = \"omarchy\"\n");
        // Nor does an undo write a historical copy over it.
        assert!(run(&s, "theme_create", json!({ "name": "other", "extends": "minimal" }), "u").env.ok);
        assert!(run(&s, "config_set", json!({ "path": "animation.speed", "value_text": "0.5" }), "u").env.ok);
        // Pretend "mine" had been created and recorded earlier, then the person edited it badly (Latin-1).
        let h = s.history();
        let latest = h.latest().unwrap();
        let mut themes = latest.themes.clone();
        themes.insert("mine".into(), "extends = \"omarchy\"\n".into());
        h.record(&history::now_rfc3339(), "u", "set mine", &latest.config, &themes).unwrap();
        assert!(run(&s, "config_undo", json!({}), "u").env.ok);
        assert_eq!(fs::read(d.0.join("themes/mine.toml")).unwrap(), b"# caf\xe9\nextends = \"omarchy\"\n", "undo left it alone");
    }

    #[test]
    fn undoing_back_to_the_baseline_keeps_it_and_a_later_edit_can_be_undone() {
        let d = Dir::new("baseline");
        let s = svc(&d);
        for i in 0..(history::KEEP - 1) {
            assert!(run(&s, "config_set", json!({ "path": "behavior.dock.hide_ms", "value_text": (100 + i).to_string() }), "user").env.ok);
        }
        assert_eq!(s.history().all().len(), history::KEEP);
        let o = run(&s, "config_undo", json!({ "n": history::KEEP - 2 }), "user");
        assert!(o.env.ok, "{:?}", o.env);
        assert!(s.history().all().iter().any(|v| v.seq == 1), "the baseline is still in history");
        assert!(run(&s, "config_set", json!({ "path": "behavior.dock.edge", "value_text": "left" }), "user").env.ok);
        let o = run(&s, "config_undo", json!({}), "user");
        assert!(o.env.ok, "the new edit can be undone: {:?}", o.env);
        assert_eq!(s.current().0.doc["behavior"]["dock"]["edge"], "bottom");
    }

    #[test]
    fn an_undo_does_not_write_over_a_hand_edit_the_watcher_has_not_seen() {
        let d = Dir::new("race");
        let s = svc(&d);
        run(&s, "config_set", json!({ "path": "animation.speed", "value_text": "0.5" }), "agent:x");
        // The person saves a valid edit; no observe() has run.
        fs::write(d.0.join("config.toml"), "[animation]\nspeed = 0.5\n[[rules]]\napp = \"foot\"\nworkspace = 3\n").unwrap();
        // The agent undoes its own last change: refused, because the person's edit is on top now.
        let o = run(&s, "config_undo", json!({}), "agent:x");
        assert_eq!(code(&o), "not_in_scope", "{:?}", o.env);
        assert!(fs::read_to_string(d.0.join("config.toml")).unwrap().contains("workspace = 3"));
        let top = run(&s, "config_history", json!({}), "u").env.data.unwrap()["versions"][0].clone();
        assert_eq!(top["caller"], "user", "the edit was recorded as the user's");
        // And a set from an agent no longer folds the person's edit into its own version.
        fs::write(d.0.join("config.toml"), "[animation]\nspeed = 0.5\n[[rules]]\napp = \"foot\"\nworkspace = 4\n").unwrap();
        run(&s, "config_set", json!({ "path": "behavior.follow_focus", "value_text": "false" }), "agent:y");
        let h = run(&s, "config_history", json!({}), "u").env.data.unwrap()["versions"].clone();
        assert_eq!(h[0]["caller"], "agent:y");
        assert_eq!(h[1]["caller"], "user");
        assert!(h[1]["summary"].as_str().unwrap().contains("rules"));
        // The person's edit survives the undo of the agent's own change.
        assert!(run(&s, "config_undo", json!({}), "agent:y").env.ok);
        assert!(fs::read_to_string(d.0.join("config.toml")).unwrap().contains("workspace = 4"));
    }

    #[test]
    fn the_schema_command_returns_the_committed_schema() {
        let d = Dir::new("schema");
        let s = svc(&d);
        let v = run(&s, "config_schema", json!({}), "u").env.data.unwrap();
        assert_eq!(
            v,
            serde_json::from_str::<Value>(include_str!("../../../spec/config.schema.json"))
                .unwrap()
        );
    }

    #[test]
    fn a_name_that_is_not_a_plain_caller_is_recorded_as_the_user() {
        let d = Dir::new("caller");
        let s = svc(&d);
        run(
            &s,
            "config_set",
            json!({ "path": "animation.speed", "value_text": "0.5" }),
            "root; rm -rf",
        );
        assert_eq!(s.history().latest().unwrap().caller, "user");
    }
}
