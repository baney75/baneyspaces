//! Replays `spec/conformance/*.json` against the model. Every platform's test suite runs the same
//! files; a platform test may also drive its compositor from the same steps.
//!
//! A case is `{ "name", "rules": [...], "steps": [...] }`. A step is an [`Event`] (`"do": ...`)
//! optionally with `"effects"` (the exact effects it must return, in order), `"error"` (the code
//! it must fail with) and `"expect"` (state it must leave, matched as a subset of `Model::view`).
//! A step with only `"expect"` checks state.

use crate::model::{Effect, Event, Model};
use serde_json::{json, Value};
use std::path::Path;

/// `expected` must appear inside `actual`: objects by key, arrays and scalars exactly. An expected
/// empty array also matches a missing key, so "this workspace is empty" can be written down.
pub fn subset(expected: &Value, actual: &Value, path: &str) -> Result<(), String> {
    match (expected, actual) {
        (Value::Object(e), Value::Object(a)) => {
            for (k, ev) in e {
                match a.get(k) {
                    Some(av) => subset(ev, av, &format!("{path}.{k}"))?,
                    None if ev == &json!([]) => {}
                    None => return Err(format!("{path}.{k}: missing (expected {ev})")),
                }
            }
            Ok(())
        }
        (e, a) if e == a => Ok(()),
        (e, a) => Err(format!("{path}: expected {e}, got {a}")),
    }
}

pub fn run_case(case: &Value) -> Result<(), String> {
    let name = case["name"].as_str().unwrap_or("?");
    let steps = case["steps"].as_array().ok_or_else(|| format!("{name}: no steps"))?;
    let mut model = Model::new();
    for (i, step) in steps.iter().enumerate() {
        let at = |m: String| format!("{name}, step {} ({}): {m}", i + 1, step["do"].as_str().unwrap_or("expect"));
        if let Some(m) = step.get("match_window") {
            let title = m["title"].as_str().unwrap_or("");
            let cands: Vec<(String, String)> = m["candidates"].as_array().into_iter().flatten().map(|c| (c["id"].as_str().unwrap_or("").into(), c["title"].as_str().unwrap_or("").into())).collect();
            match (step.get("error"), crate::agent::match_window(title, &cands)) {
                (Some(code), Err(e)) if code == &json!(e.code) => {}
                (Some(code), Err(e)) => return Err(at(format!("expected error {code}, got {}", e.code))),
                (Some(code), Ok(_)) => return Err(at(format!("expected error {code}, but it matched"))),
                (None, Err(e)) => return Err(at(format!("unexpected error {}", e.code))),
                (None, Ok(id)) => {
                    if let Some(want) = step.get("id") {
                        if want != &json!(id) {
                            return Err(at(format!("expected window {want}, got {id}")));
                        }
                    }
                }
            }
            continue;
        }
        if step.get("do").is_some() {
            let event: Event = serde_json::from_value(step.clone()).map_err(|e| at(format!("bad step: {e}")))?;
            let result = model.apply(event);
            match (step.get("error"), result) {
                (Some(code), Err(e)) if code == &json!(e.code) => {}
                (Some(code), Err(e)) => return Err(at(format!("expected error {code}, got {}", e.code))),
                (Some(code), Ok(_)) => return Err(at(format!("expected error {code}, but it succeeded"))),
                (None, Err(e)) => return Err(at(format!("unexpected error {e}"))),
                (None, Ok(effects)) => {
                    if let Some(want) = step.get("effects") {
                        let want: Vec<Effect> = serde_json::from_value(want.clone()).map_err(|e| at(format!("bad effects: {e}")))?;
                        if want != effects {
                            return Err(at(format!("effects differ\n  want {}\n  got  {}", serde_json::to_string(&want).unwrap(), serde_json::to_string(&effects).unwrap())));
                        }
                    }
                }
            }
        }
        if let Some(expect) = step.get("expect") {
            subset(expect, &model.view(), "state").map_err(&at)?;
        }
    }
    Ok(())
}

/// Runs every `*.json` file under `dir` (each is one case or an array of cases). Returns the
/// number of cases, or every failure.
pub fn run_dir(dir: &Path) -> Result<usize, Vec<String>> {
    let mut files: Vec<_> = std::fs::read_dir(dir).map_err(|e| vec![format!("{}: {e}", dir.display())])?.filter_map(|e| e.ok()).map(|e| e.path()).filter(|p| p.extension().is_some_and(|x| x == "json")).collect();
    files.sort();
    let (mut count, mut failures) = (0, vec![]);
    for f in files {
        let text = std::fs::read_to_string(&f).map_err(|e| vec![format!("{}: {e}", f.display())])?;
        let v: Value = match serde_json::from_str(&text) {
            Ok(v) => v,
            Err(e) => {
                failures.push(format!("{}: {e}", f.display()));
                continue;
            }
        };
        let cases = if v.is_array() { v.as_array().cloned().unwrap_or_default() } else { vec![v] };
        for c in cases {
            count += 1;
            if let Err(e) = run_case(&c) {
                failures.push(format!("{}: {e}", f.file_name().unwrap_or_default().to_string_lossy()));
            }
        }
    }
    if failures.is_empty() { Ok(count) } else { Err(failures) }
}

/// The directory holding the spec, found from this crate.
pub fn spec_dir() -> std::path::PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../spec")
}


// ---- configuration cases (spec/conformance/config/*.json) ---------------------------------------

/// A config case is `{ "name", "platform"?, "omarchy"?, "themes"?, "steps": [...] }`. A step has
/// `do`: `set`, `unset`, `apply` (`doc` or `toml`), `validate`, `reset`, `undo`, `edit_file`
/// (a hand edit, `toml`), `theme_create`, `theme_set`, `theme_delete`, `recovery`, or `check`.
/// Optional on any step: `caller`; `expect`: `"ok"` or `{ "error": code, "issues": [{path, code}] }`;
/// `effective`: dotted path to value in the effective config; `resolved`: JSON pointer to value in
/// what the UIs read; `history`: `{ "len", "callers" }` (newest first); `file`: the exact text of
/// `config.toml`.
pub fn run_config_case(case: &Value) -> Result<(), String> {
    use crate::chord::Platform;
    use crate::config::Env;
    use crate::config_store::Service;
    let name = case["name"].as_str().unwrap_or("?");
    let platform = Platform::parse(case["platform"].as_str().unwrap_or("linux")).ok_or_else(|| format!("{name}: bad platform"))?;
    let mut env = Env::new(platform);
    env.omarchy = case["omarchy"].as_bool().unwrap_or(false);
    env.reduce_motion = case["reduce_motion"].as_bool().unwrap_or(false);
    static N: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let dir = std::env::temp_dir().join(format!("bs-conf-{}-{}", std::process::id(), N.fetch_add(1, std::sync::atomic::Ordering::Relaxed)));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("themes")).map_err(|e| e.to_string())?;
    for (n, t) in case["themes"].as_object().into_iter().flatten() {
        std::fs::write(dir.join("themes").join(format!("{n}.toml")), crate::config::to_toml(t)).map_err(|e| e.to_string())?;
    }
    let svc = Service::new(&dir, env).with_approvals(dir.join("state/approvals.json"));
    let result = (|| {
        for (i, step) in case["steps"].as_array().ok_or("no steps")?.iter().enumerate() {
            let kind = step["do"].as_str().unwrap_or("check");
            let at = |m: String| format!("{name}, step {} ({kind}): {m}", i + 1);
            let caller = step["caller"].as_str().unwrap_or("user");
            let doc_text = || step["toml"].as_str().map(String::from).unwrap_or_else(|| step["doc"].to_string());
            let env = match kind {
                "set" => svc.dispatch("config_set", &json!({ "path": step["path"], "value": step["value"] }), caller).env,
                "unset" => svc.dispatch("config_unset", &json!({ "path": step["path"] }), caller).env,
                "apply" => svc.dispatch("config_apply", &json!({ "text": doc_text() }), caller).env,
                "validate" => svc.dispatch("config_validate", &json!({ "text": doc_text() }), caller).env,
                "reset" => svc.dispatch("config_reset", &json!({ "section": step.get("section") }), caller).env,
                "undo" => svc.dispatch("config_undo", &json!({ "n": step.get("n") }), caller).env,
                "theme_create" => svc.dispatch("theme_create", step, caller).env,
                "theme_set" => svc.dispatch("theme_set", step, caller).env,
                "theme_delete" => svc.dispatch("theme_delete", step, caller).env,
                "edit_file" => {
                    std::fs::write(svc.config_path(), step["toml"].as_str().unwrap_or("")).map_err(|e| e.to_string())?;
                    match svc.observe() {
                        Ok(a) => crate::envelope::Envelope::ok(json!({ "applied": a.is_some() })),
                        Err(issues) => {
                            let mut e = crate::envelope::Envelope::err("config_invalid", "the file is invalid", crate::envelope::Retry::Never, "");
                            e = e.with_data(json!({ "issues": issues.iter().map(|i| i.to_json()).collect::<Vec<_>>() }));
                            e
                        }
                    }
                }
                // The Settings UI's click: the one write that approves an executable entry.
                "approve" => match svc.approve(step["path"].as_str().unwrap_or(""), step["value"].as_str().unwrap_or("")) {
                    Ok(id) => crate::envelope::Envelope::ok(json!({ "approved": id })),
                    Err(e) => return Err(at(format!("approve failed: {e}"))),
                },
                // Everything that asks for an approval by command is refused.
                "approve_by_command" => svc.dispatch("config_approve", &json!({ "path": step["path"], "value": step["value"] }), caller).env,
                "recovery" => {
                    let c = crate::chord::Chord::recovery();
                    crate::envelope::Envelope::ok(json!({ "chord": c.canonical(platform), "hold_ms": crate::chord::recovery_hold_ms() }))
                }
                "check" => crate::envelope::Envelope::ok(json!({})),
                other => return Err(at(format!("unknown step {other}"))),
            };
            match step.get("expect") {
                None => {
                    if !env.ok {
                        return Err(at(format!("unexpected failure {}", env.to_json())));
                    }
                }
                Some(Value::String(s)) if s == "ok" => {
                    if !env.ok {
                        return Err(at(format!("expected ok, got {}", env.to_json())));
                    }
                }
                Some(want) => {
                    let Some(e) = env.error.as_ref() else { return Err(at(format!("expected an error, but it succeeded: {}", env.to_json()))) };
                    if let Some(code) = want["error"].as_str() {
                        if e.code != code {
                            return Err(at(format!("expected error {code}, got {}", e.code)));
                        }
                    }
                    for wi in want["issues"].as_array().into_iter().flatten() {
                        let got = e.data.as_ref().and_then(|d| d["issues"].as_array()).cloned().unwrap_or_default();
                        let hit = got.iter().any(|g| g["path"] == wi["path"] && wi["code"].as_str().is_none_or(|c| g["code"] == c));
                        if !hit {
                            return Err(at(format!("no issue {wi} in {}", Value::Array(got))));
                        }
                    }
                }
            }
            if let (Some(data), Some(want)) = (env.data.as_ref(), step.get("data")) {
                subset(want, data, "data").map_err(&at)?;
            }
            let (eff, _, _) = svc.current();
            let resolved = svc.runtime_json();
            for (p, want) in step["effective"].as_object().into_iter().flatten() {
                let path = crate::config::parse_path(p).map_err(|e| at(e))?;
                let got = crate::config::get_path(&eff.doc, &path);
                if got != Some(want) {
                    return Err(at(format!("effective {p}: expected {want}, got {}", got.map(|v| v.to_string()).unwrap_or("nothing".into()))));
                }
            }
            // What is configured, whether or not it runs (pending entries are in it).
            for (p, want) in step["configured"].as_object().into_iter().flatten() {
                let path = crate::config::parse_path(p).map_err(|e| at(e))?;
                let l = svc.load();
                let doc = l.validated.effective.as_ref().map(|e| e.doc.clone()).unwrap_or_default();
                let got = crate::config::get_path(&doc, &path);
                if got != Some(want) {
                    return Err(at(format!("configured {p}: expected {want}, got {}", got.map(|v| v.to_string()).unwrap_or("nothing".into()))));
                }
            }
            // Settings that must not be in what runs.
            for p in step["absent"].as_array().into_iter().flatten().filter_map(Value::as_str) {
                let path = crate::config::parse_path(p).map_err(|e| at(e))?;
                if let Some(v) = crate::config::get_path(&eff.doc, &path) {
                    return Err(at(format!("effective {p} should not be there, but is {v}")));
                }
            }
            // The executable entries still waiting for a click, by path.
            if let Some(want) = step["pending"].as_array() {
                let mut got: Vec<String> = resolved["pending"].as_array().into_iter().flatten().filter_map(|e| e["path"].as_str().map(String::from)).collect();
                let mut want: Vec<String> = want.iter().filter_map(|v| v.as_str().map(String::from)).collect();
                got.sort();
                want.sort();
                if got != want {
                    return Err(at(format!("pending {got:?}, expected {want:?}")));
                }
            }
            for (p, want) in step["resolved"].as_object().into_iter().flatten() {
                let got = resolved.pointer(p);
                if got != Some(want) {
                    return Err(at(format!("resolved {p}: expected {want}, got {}", got.map(|v| v.to_string()).unwrap_or("nothing".into()))));
                }
            }
            if let Some(h) = step.get("history") {
                let all = svc.history().all();
                if let Some(n) = h["len"].as_u64() {
                    if all.len() as u64 != n {
                        return Err(at(format!("history has {} versions, expected {n}", all.len())));
                    }
                }
                if let Some(want) = h["callers"].as_array() {
                    let got: Vec<Value> = all.iter().rev().map(|v| json!(v.caller)).collect();
                    if &got != want {
                        return Err(at(format!("history callers {}, expected {}", Value::Array(got), Value::Array(want.clone()))));
                    }
                }
            }
            if let Some(f) = step["file"].as_str() {
                let got = std::fs::read_to_string(svc.config_path()).unwrap_or_default();
                if got != f {
                    return Err(at(format!("config.toml is {got:?}, expected {f:?}")));
                }
            }
        }
        Ok(())
    })();
    let _ = std::fs::remove_dir_all(&dir);
    result
}

/// Runs every case under `dir` (the config conformance cases). Returns the count, or every failure.
pub fn run_config_dir(dir: &Path) -> Result<usize, Vec<String>> {
    let mut files: Vec<_> = std::fs::read_dir(dir).map_err(|e| vec![format!("{}: {e}", dir.display())])?.filter_map(|e| e.ok()).map(|e| e.path()).filter(|p| p.extension().is_some_and(|x| x == "json")).collect();
    files.sort();
    let (mut count, mut failures) = (0, vec![]);
    for f in files {
        let text = std::fs::read_to_string(&f).map_err(|e| vec![format!("{}: {e}", f.display())])?;
        let v: Value = match serde_json::from_str(&text) {
            Ok(v) => v,
            Err(e) => {
                failures.push(format!("{}: {e}", f.display()));
                continue;
            }
        };
        for c in if v.is_array() { v.as_array().cloned().unwrap_or_default() } else { vec![v] } {
            count += 1;
            if let Err(e) = run_config_case(&c) {
                failures.push(format!("{}: {e}", f.file_name().unwrap_or_default().to_string_lossy()));
            }
        }
    }
    if failures.is_empty() { Ok(count) } else { Err(failures) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spec_conformance_cases_all_pass() {
        match run_dir(&spec_dir().join("conformance")) {
            Ok(n) => {
                assert!(n >= 60, "only {n} conformance cases");
                println!("conformance: {n} cases passed");
            }
            Err(f) => panic!("{} conformance failure(s):\n{}", f.len(), f.join("\n")),
        }
    }

    #[test]
    fn spec_config_conformance_cases_all_pass() {
        match run_config_dir(&spec_dir().join("conformance/config")) {
            Ok(n) => {
                assert!(n >= 30, "only {n} config conformance cases");
                println!("config conformance: {n} cases passed");
            }
            Err(f) => panic!("{} config conformance failure(s):\n{}", f.len(), f.join("\n")),
        }
    }

    #[test]
    fn the_config_runner_fails_on_a_wrong_expectation() {
        let case = json!({"name":"bad","steps":[{"do":"set","path":"animation.speed","value":0.5,"effective":{"animation.speed":2}}]});
        assert!(run_config_case(&case).is_err());
        let case = json!({"name":"bad2","steps":[{"do":"set","path":"animation.speed","value":99,"expect":"ok"}]});
        assert!(run_config_case(&case).is_err());
        let case = json!({"name":"good","steps":[{"do":"set","path":"animation.speed","value":99,"expect":{"error":"config_invalid","issues":[{"path":"animation.speed","code":"range"}]}}]});
        assert!(run_config_case(&case).is_ok());
    }

    #[test]
    fn every_rule_in_the_spec_has_a_case() {
        let rules = std::fs::read_to_string(spec_dir().join("workspaces.md")).unwrap();
        let ids: Vec<String> = rules.lines().filter_map(|l| l.strip_prefix("### ").and_then(|r| r.split_whitespace().next()).filter(|id| id.starts_with("R-")).map(String::from)).collect();
        assert!(ids.len() >= 20, "found {} rules", ids.len());
        let mut cases = String::new();
        for e in std::fs::read_dir(spec_dir().join("conformance")).unwrap().flatten().filter(|e| e.path().is_file()) {
            cases.push_str(&std::fs::read_to_string(e.path()).unwrap());
        }
        for id in ids {
            assert!(cases.contains(&format!("\"{id}\"")), "no conformance case names rule {id}");
        }
    }

    #[test]
    fn the_runner_fails_on_a_wrong_expectation() {
        let case = json!({"name":"bad","steps":[{"do":"monitor_added","monitor":"A"},{"do":"switch","n":2,"expect":{"monitors":{"A":{"current":3}}}}]});
        assert!(run_case(&case).is_err());
        let case = json!({"name":"bad2","steps":[{"do":"monitor_added","monitor":"A"},{"do":"switch","n":2,"effects":[]}]});
        assert!(run_case(&case).is_err());
        let case = json!({"name":"bad3","steps":[{"do":"monitor_added","monitor":"A"},{"do":"switch","n":2,"error":"invalid_args"}]});
        assert!(run_case(&case).is_err());
    }

    #[test]
    fn empty_array_matches_a_missing_workspace() {
        assert!(subset(&json!({"w":{"A:3":[]}}), &json!({"w":{}}), "s").is_ok());
        assert!(subset(&json!({"w":{"A:3":["x"]}}), &json!({"w":{}}), "s").is_err());
    }
}
