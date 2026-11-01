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
    fn every_rule_in_the_spec_has_a_case() {
        let rules = ["workspaces.md", "devices.md"].iter().map(|f| std::fs::read_to_string(spec_dir().join(f)).unwrap()).collect::<Vec<_>>().join("\n");
        let ids: Vec<String> = rules.lines().filter_map(|l| l.strip_prefix("### ").and_then(|r| r.split_whitespace().next()).filter(|id| id.starts_with("R-")).map(String::from)).collect();
        assert!(ids.len() >= 20, "found {} rules", ids.len());
        let mut cases = String::new();
        let mut dirs = vec![spec_dir().join("conformance")];
        while let Some(dir) = dirs.pop() {
            for e in std::fs::read_dir(dir).unwrap().flatten() {
                if e.path().is_dir() {
                    dirs.push(e.path());
                } else {
                    cases.push_str(&std::fs::read_to_string(e.path()).unwrap());
                }
            }
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
