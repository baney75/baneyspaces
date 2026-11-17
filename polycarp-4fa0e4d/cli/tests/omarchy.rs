//! `polycarp theme follow`: every test gets its own HOME and config folder, so nothing real is
//! touched. The fixtures are the colors.toml of every theme bundled with Omarchy 4.0.4.

use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicUsize, Ordering};

static COUNTER: AtomicUsize = AtomicUsize::new(0);

fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/omarchy")
}

fn fixture_names() -> Vec<String> {
    let mut v: Vec<String> = fs::read_dir(fixtures())
        .unwrap()
        .filter_map(|e| {
            let e = e.unwrap();
            e.path()
                .join("colors.toml")
                .is_file()
                .then(|| e.file_name().to_string_lossy().into_owned())
        })
        .collect();
    v.sort();
    v
}

struct Sandbox {
    root: PathBuf,
}

impl Sandbox {
    fn new() -> Sandbox {
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let root = Path::new(env!("CARGO_TARGET_TMPDIR"))
            .join(format!("omarchy-{}-{n}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        for d in ["home", "cwd", "tmp"] {
            fs::create_dir_all(root.join(d)).unwrap();
        }
        Sandbox { root }
    }
    fn home(&self) -> PathBuf {
        self.root.join("home")
    }
    fn cfg(&self) -> PathBuf {
        self.root.join("cfg")
    }
    fn state(&self) -> PathBuf {
        self.home().join(".local/state/omarchy")
    }
    fn hook(&self) -> PathBuf {
        self.home()
            .join(".config/omarchy/hooks/theme-set.d/polycarp")
    }
    /// Makes this an Omarchy machine whose current theme has these colors.
    fn omarchy(&self, name: &str, colors: &str) {
        let dir = self.state().join("current/theme");
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("colors.toml"), colors).unwrap();
        fs::write(self.state().join("current/theme.name"), format!("{name}\n")).unwrap();
    }
    fn omarchy_fixture(&self, name: &str) {
        let colors = fs::read_to_string(fixtures().join(name).join("colors.toml")).unwrap();
        self.omarchy(name, &colors);
    }
    fn cmd(&self, args: &[&str]) -> Command {
        let mut c = Command::new(env!("CARGO_BIN_EXE_polycarp"));
        c.env_clear()
            .env("HOME", self.home())
            .env("POLYCARP_CONFIG_DIR", self.cfg())
            .env("TMPDIR", self.root.join("tmp"))
            .current_dir(self.root.join("cwd"))
            .args(args);
        c
    }
    fn run(&self, args: &[&str]) -> Output {
        self.cmd(args).output().unwrap()
    }
    fn json(&self, args: &[&str]) -> (bool, Value) {
        let mut a = args.to_vec();
        a.push("--json");
        let out = self.run(&a);
        let v: Value = serde_json::from_slice(&out.stdout)
            .unwrap_or_else(|e| panic!("{e}: {}", String::from_utf8_lossy(&out.stdout)));
        (out.status.success(), v)
    }
    fn theme_file(&self) -> String {
        fs::read_to_string(self.cfg().join("themes/omarchy.toml")).unwrap()
    }
    fn exported(&self) -> Value {
        let (ok, v) = self.json(&["theme", "export", "json"]);
        assert!(ok, "{v}");
        v["data"].clone()
    }
}

fn s(v: &Value) -> String {
    v.as_str().unwrap_or_default().to_string()
}

fn stdout(o: &Output) -> String {
    String::from_utf8_lossy(&o.stdout).into_owned()
}

const TOKYO: &str = r##"mode = "dark"
accent = "#7aa2f7"
selection = "#292e42"
muted = "#414868"
background = "#1a1b26"
dark_background = "#13141c"
darker_background = "#0e0e14"
lighter_background = "#24283b"
foreground = "#a9b1d6"
dark_foreground = "#565f89"
light_foreground = "#b4bee6"
bright_foreground = "#c0caf5"
red = "#f7768e"
yellow = "#e0af68"
green = "#9ece6a"
blue = "#7aa2f7"
"##;

fn first_failure(v: &Value) -> String {
    format!("{}", v["error"])
}

#[test]
fn every_bundled_omarchy_theme_becomes_a_theme_that_passes_the_contrast_rules() {
    let names = fixture_names();
    assert_eq!(names.len(), 22, "{names:?}");
    let mut moved = Vec::new();
    for name in &names {
        let b = Sandbox::new();
        b.omarchy_fixture(name);
        let (ok, v) = b.json(&["theme", "follow", "omarchy"]);
        assert!(ok, "{name} was refused: {}", first_failure(&v));
        let src: toml::Table = fs::read_to_string(fixtures().join(name).join("colors.toml"))
            .unwrap()
            .parse()
            .unwrap();
        let mode = src.get("mode").and_then(|m| m.as_str()).unwrap_or("dark");
        assert_eq!(
            v["data"]["mode"], mode,
            "{name}: the mode is Omarchy's, not auto"
        );
        assert_eq!(v["data"]["theme"], "omarchy-overrides");
        // The engine's own check agrees.
        let theme = b.theme_file();
        let file = b.root.join("omarchy.toml");
        fs::write(&file, &theme).unwrap();
        let (valid, vv) = b.json(&["theme", "validate", file.to_str().unwrap()]);
        assert!(valid, "{name}: {vv}");
        // Background is never moved. The accent is Omarchy's unless the notes say it was moved.
        let out = b.exported();
        let colors = &out["surfaces"]["spaces"][mode];
        assert_eq!(
            s(&colors["background"]),
            src["background"].as_str().unwrap().to_lowercase(),
            "{name}"
        );
        let nudges = v["data"]["nudges"].as_array().unwrap();
        let accent_moved = nudges.iter().any(|n| n["path"] == format!("{mode}.accent"));
        if !accent_moved {
            let want = src
                .get("accent")
                .or_else(|| src.get("blue"))
                .and_then(|a| a.as_str())
                .unwrap()
                .to_lowercase();
            assert_eq!(s(&colors["accent"]), want, "{name}");
        }
        // Every role Omarchy supplies and that passed is exactly Omarchy's.
        for n in nudges
            .iter()
            .filter(|n| s(&n["path"]).starts_with(&format!("{mode}.")))
        {
            assert_eq!(
                s(&colors[s(&n["path"]).split('.').nth(1).unwrap()]),
                s(&n["to"]).as_str().to_string(),
                "{name}: a nudge is what is written"
            );
        }
        // An independent copy of the mapping: every role that was not nudged is exactly the first
        // key Omarchy supplies, and every nudged role was failing before.
        let indep: [(&str, &[&str]); 12] = [
            ("background", &["background"]),
            ("surface", &["lighter_background", "background"]),
            ("sunken", &["dark_background", "background"]),
            ("foreground", &["foreground"]),
            (
                "strong",
                &["bright_foreground", "light_foreground", "foreground"],
            ),
            ("muted", &["dark_foreground", "muted"]),
            ("border", &["muted", "dark_foreground"]),
            ("accent", &["accent", "blue"]),
            ("selection", &["selection", "lighter_background"]),
            ("urgent", &["red"]),
            ("working", &["yellow"]),
            ("done", &["green"]),
        ];
        let want = |role: &str| -> String {
            let keys = indep.iter().find(|(r, _)| *r == role).unwrap().1;
            let k = keys
                .iter()
                .find(|k| src.get(**k).and_then(|v| v.as_str()).is_some())
                .unwrap();
            src[*k].as_str().unwrap().to_lowercase()
        };
        let rules: [(&str, &[&str], f64); 7] = [
            (
                "foreground",
                &["background", "surface", "sunken", "selection"],
                4.5,
            ),
            (
                "strong",
                &["background", "surface", "sunken", "selection"],
                4.5,
            ),
            ("muted", &["background", "surface", "sunken"], 4.5),
            ("urgent", &["background", "surface"], 4.5),
            ("working", &["background", "surface"], 4.5),
            ("done", &["background", "surface"], 4.5),
            ("accent", &["background", "surface"], 4.5),
        ];
        for (role, _) in &indep {
            let moved = nudges.iter().any(|n| n["path"] == format!("{mode}.{role}"));
            let got = s(&colors[*role]);
            if !moved {
                assert_eq!(got, want(role), "{name}: {role} is Omarchy's");
            } else {
                let (_, bgs, min) = rules.iter().find(|(r, _, _)| r == role).unwrap();
                let failing = bgs
                    .iter()
                    .any(|bg| contrast_of(&want(role), &want(bg)) < *min);
                assert!(failing, "{name}: {role} was moved but already read well");
            }
        }
        // Each nudge is in the notes.
        let notes = v["data"]["notes"].as_array().cloned().unwrap_or_default();
        for n in nudges {
            let p = s(&n["path"]);
            assert!(
                notes
                    .iter()
                    .any(|x| x.as_str().unwrap().starts_with(&format!("{p}:"))),
                "{name}: no note for {p}"
            );
            moved.push(format!("{name}: {p} {} -> {}", s(&n["from"]), s(&n["to"])));
        }
    }
    eprintln!("themes tested: {}", names.len());
    for m in &moved {
        eprintln!("nudged: {m}");
    }
}

#[test]
fn a_passing_palette_is_kept_exactly() {
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    let (ok, v) = b.json(&["theme", "follow", "omarchy"]);
    assert!(ok, "{v}");
    let out = b.exported();
    let d = &out["surfaces"]["spaces"]["dark"];
    assert_eq!(d["background"], "#1a1b26");
    assert_eq!(d["accent"], "#7aa2f7");
    assert_eq!(d["foreground"], "#a9b1d6");
    assert_eq!(d["surface"], "#24283b");
    assert_eq!(d["sunken"], "#13141c");
    assert_eq!(d["selection"], "#292e42");
    // Omarchy's dark_foreground (#565f89) reads under 4.5 on its own background, so it moves; the
    // others stay.
    let nudges = v["data"]["nudges"].as_array().unwrap();
    assert!(
        nudges.iter().any(|n| n["path"] == "dark.muted"),
        "{nudges:?}"
    );
    assert!(!nudges.iter().any(|n| n["path"] == "dark.accent"));
    assert_eq!(out["mode"], "dark");
    // The shape is Omarchy's own look: the blocks theme.
    assert_eq!(out["surfaces"]["spaces"]["shape"]["radius"], 0);
}

#[test]
fn a_nudge_is_the_smallest_lightness_step() {
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    let (_, v) = b.json(&["theme", "follow", "omarchy"]);
    let n = v["data"]["nudges"]
        .as_array()
        .unwrap()
        .iter()
        .find(|n| n["path"] == "dark.muted")
        .unwrap()
        .clone();
    assert_eq!(s(&n["from"]), "#565f89");
    let to = s(&n["to"]);
    // Same hue family, lighter, and it reads 4.5 on the three backgrounds.
    let out = b.exported();
    let d = &out["surfaces"]["spaces"]["dark"];
    assert_eq!(s(&d["muted"]), to);
    let lum = |h: &str| {
        let c = |i: usize| {
            let v = f64::from(u8::from_str_radix(&h[i..i + 2], 16).unwrap()) / 255.0;
            if v <= 0.04045 {
                v / 12.92
            } else {
                ((v + 0.055) / 1.055).powf(2.4)
            }
        };
        0.2126 * c(1) + 0.7152 * c(3) + 0.0722 * c(5)
    };
    let ratio = |a: &str, b: &str| {
        let (x, y) = (lum(a), lum(b));
        (x.max(y) + 0.05) / (x.min(y) + 0.05)
    };
    for bg in ["background", "surface", "sunken"] {
        assert!(ratio(&to, &s(&d[bg])) >= 4.5, "muted on {bg}");
    }
    assert!(n["reason"].as_str().unwrap().contains("needs 4.5"));
}

#[test]
fn older_themes_with_missing_keys_still_follow() {
    let b = Sandbox::new();
    // No mode, no light/dark backgrounds, no status colors, no bright_*: only the basics.
    b.omarchy(
        "old",
        "background = \"#101010\"\nforeground = \"#e0e0e0\"\naccent = \"#ff8800\"\n",
    );
    let (ok, v) = b.json(&["theme", "follow", "omarchy"]);
    assert!(ok, "{v}");
    assert_eq!(v["data"]["mode"], "dark");
    let out = b.exported();
    let d = &out["surfaces"]["spaces"]["dark"];
    assert_eq!(d["background"], "#101010");
    assert_eq!(d["foreground"], "#e0e0e0");
    assert_eq!(d["accent"], "#ff8800");
    let notes = v["data"]["notes"].to_string();
    assert!(
        notes.contains("dark.urgent: this Omarchy theme has none of"),
        "{notes}"
    );
    // Colors may be written in other shapes.
    let b = Sandbox::new();
    b.omarchy(
        "odd",
        "mode = \"light\"\nbackground = \"0xFFFFFF\"\nforeground = \"#000\"\naccent = \"1D4ED8\"\n",
    );
    let (ok, v) = b.json(&["theme", "follow", "omarchy"]);
    assert!(ok, "{v}");
    let l = &b.exported()["surfaces"]["spaces"]["light"];
    assert_eq!(l["background"], "#ffffff");
    assert_eq!(l["foreground"], "#000000");
    assert_eq!(l["accent"], "#1d4ed8");
}

#[test]
fn the_other_mode_is_readable_and_keeps_the_accent_hue() {
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    let (ok, v) = b.json(&["theme", "follow", "omarchy"]);
    assert!(ok, "{v}");
    let out = b.exported();
    let l = &out["surfaces"]["spaces"]["light"];
    assert_ne!(l["background"], "#1a1b26");
    // The file lists only the accent pair for the mode Omarchy is not in.
    let file = b.theme_file();
    let t: toml::Table = file.parse().unwrap();
    let light = t["light"].as_table().unwrap();
    assert_eq!(light.len(), 2, "{light:?}");
    assert_eq!(t["extends"].as_str(), Some("blocks"));
    assert_eq!(t["dark"].as_table().unwrap().len(), 13);
}

#[test]
fn no_omarchy_means_a_clear_error_and_no_change() {
    let b = Sandbox::new();
    let (ok, v) = b.json(&["theme", "follow", "omarchy"]);
    assert!(!ok);
    assert_eq!(v["error"]["code"], "no_omarchy");
    assert!(
        !b.cfg().exists()
            || fs::read_dir(b.cfg()).unwrap().all(|e| {
                let n = e.unwrap().file_name();
                n == ".lock"
            })
    );
    assert!(!b.home().join(".config").exists());
    let out = b.run(&["theme", "follow", "omarchy"]);
    assert_eq!(out.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&out.stderr).contains("Omarchy was not found"));
    // The state is readable and says no.
    let (ok, v) = b.json(&["theme", "follow"]);
    assert!(ok);
    assert_eq!(v["data"]["omarchy_detected"], false);
    assert_eq!(v["data"]["following"], false);
}

#[test]
fn the_hook_is_marked_runs_the_binary_by_absolute_path_and_always_exits_zero() {
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    let (ok, _) = b.json(&["theme", "follow", "omarchy"]);
    assert!(ok);
    let text = fs::read_to_string(b.hook()).unwrap();
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines[0], "#!/bin/bash");
    assert!(
        lines[1].starts_with("# polycarp-managed-hook"),
        "{}",
        lines[1]
    );
    let exe = fs::canonicalize(env!("CARGO_BIN_EXE_polycarp")).unwrap();
    assert!(text.contains(&format!("exe='{}'", exe.display())));
    assert!(text.contains("theme follow omarchy --sync"));
    assert!(lines[1].contains("config="), "{}", lines[1]);
    assert!(text.trim_end().ends_with("exit 0"));
    assert!(
        text.contains("POLYCARP_CONFIG_DIR="),
        "the hook keeps the config folder"
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            fs::metadata(b.hook()).unwrap().permissions().mode() & 0o777,
            0o755
        );
    }
    // Run it the way Omarchy does: `bash <file> <theme name>`, with no terminal and no input.
    #[cfg(unix)]
    {
        let run = |dir: &Sandbox| {
            Command::new("bash")
                .arg(dir.hook())
                .arg("tokyo-night")
                .env_clear()
                .env("HOME", dir.home())
                .stdin(std::process::Stdio::null())
                .output()
                .unwrap()
        };
        // Switch Omarchy to another theme, then run the hook: the Polycarp theme follows.
        b.omarchy_fixture("white");
        let o = run(&b);
        assert_eq!(o.status.code(), Some(0));
        assert!(o.stdout.is_empty() && o.stderr.is_empty());
        let out = b.exported();
        assert_eq!(out["mode"], "light");
        assert_eq!(out["surfaces"]["spaces"]["light"]["background"], "#ffffff");
        let log = fs::read_to_string(b.cfg().join("follow.log")).unwrap();
        assert_eq!(log.lines().count(), 1, "{log}");
        assert!(log.contains("white"));
        // Colors unchanged: the hook changes nothing and logs nothing more.
        let before = fs::read(b.cfg().join("current/theme.json")).unwrap();
        run(&b);
        assert_eq!(
            fs::read(b.cfg().join("current/theme.json")).unwrap(),
            before
        );
        assert_eq!(
            fs::read_to_string(b.cfg().join("follow.log"))
                .unwrap()
                .lines()
                .count(),
            1
        );
        // Even with Omarchy's colors gone and the binary unreachable, the hook exits 0.
        fs::remove_file(b.state().join("current/theme/colors.toml")).unwrap();
        assert_eq!(run(&b).status.code(), Some(0));
        fs::write(
            b.hook(),
            text.replace(&exe.display().to_string(), "/nonexistent/polycarp"),
        )
        .unwrap();
        let o = run(&b);
        assert_eq!(o.status.code(), Some(0));
        assert!(o.stdout.is_empty());
    }
}

#[test]
fn history_gets_nothing_from_a_sync() {
    let b = Sandbox::new();
    b.omarchy_fixture("tokyo-night");
    b.json(&["theme", "follow", "omarchy"]);
    let n = |b: &Sandbox| {
        fs::read_dir(b.cfg().join("history"))
            .map(|d| d.count())
            .unwrap_or(0)
    };
    let before = n(&b);
    for t in ["white", "nord", "white"] {
        b.omarchy_fixture(t);
        let o = b.run(&["theme", "follow", "omarchy", "--sync"]);
        assert!(o.status.success(), "{}", stdout(&o));
    }
    assert_eq!(n(&b), before);
    assert_eq!(
        fs::read_to_string(b.cfg().join("follow.log"))
            .unwrap()
            .lines()
            .count(),
        3
    );
}

#[test]
fn a_hook_that_is_not_ours_is_never_overwritten_or_removed() {
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    fs::create_dir_all(b.hook().parent().unwrap()).unwrap();
    fs::write(b.hook(), "#!/bin/bash\necho mine\n").unwrap();
    let (ok, v) = b.json(&["theme", "follow", "omarchy"]);
    assert!(!ok);
    assert_eq!(v["error"]["code"], "exists");
    assert!(v["error"]["message"].as_str().unwrap().contains("polycarp"));
    assert_eq!(
        fs::read_to_string(b.hook()).unwrap(),
        "#!/bin/bash\necho mine\n"
    );
    assert!(!b.cfg().join("themes").exists(), "nothing was written");
    assert!(!b.cfg().join("config.toml").exists());
    // off leaves it too.
    let (ok, v) = b.json(&["theme", "follow", "off"]);
    assert!(ok, "{v}");
    assert_eq!(
        fs::read_to_string(b.hook()).unwrap(),
        "#!/bin/bash\necho mine\n"
    );
    assert!(v.to_string().contains("not Polycarp's"));
}

#[test]
fn off_removes_only_our_hook_and_goes_back_to_the_theme_from_before() {
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    let sibling = b.hook().parent().unwrap().join("other");
    fs::create_dir_all(sibling.parent().unwrap()).unwrap();
    fs::write(&sibling, "#!/bin/bash\n").unwrap();
    assert!(b
        .run(&["theme", "set", "evening", "--mode", "light"])
        .status
        .success());
    let (ok, v) = b.json(&["theme", "follow", "omarchy"]);
    assert!(ok, "{v}");
    assert_eq!(v["data"]["theme"], "omarchy-overrides");
    let (_, st) = b.json(&["theme", "follow"]);
    assert_eq!(st["data"]["following"], true);
    assert_eq!(st["data"]["previous_theme"], "evening");
    assert_eq!(st["data"]["hook_installed"], true);
    let doctor = b.run(&["doctor"]);
    assert!(
        stdout(&doctor).contains("omarchy: found, and Polycarp is following"),
        "{}",
        stdout(&doctor)
    );

    let (ok, v) = b.json(&["theme", "follow", "off"]);
    assert!(ok, "{v}");
    assert_eq!(v["data"]["theme"], "evening");
    assert_eq!(v["data"]["mode"], "light");
    assert!(!b.hook().exists());
    assert!(sibling.exists());
    let (_, st) = b.json(&["theme", "follow"]);
    assert_eq!(st["data"]["following"], false);
    let cfg = fs::read_to_string(b.cfg().join("config.toml")).unwrap();
    assert!(!cfg.contains("omarchy"), "{cfg}");
    // Off when not following changes no setting.
    let before = fs::read(b.cfg().join("config.toml")).unwrap();
    let (ok, v) = b.json(&["theme", "follow", "off"]);
    assert!(ok);
    assert_eq!(v["data"]["was_following"], false);
    assert_eq!(fs::read(b.cfg().join("config.toml")).unwrap(), before);
    let doctor = b.run(&["doctor"]);
    assert!(
        stdout(&doctor).contains("not following"),
        "{}",
        stdout(&doctor)
    );
}

#[test]
fn choosing_another_theme_stops_following_and_says_so() {
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    b.json(&["theme", "follow", "omarchy"]);
    assert!(b.hook().exists());
    let (ok, v) = b.json(&["theme", "set", "calm"]);
    assert!(ok, "{v}");
    let notes = v["data"]["notes"].to_string();
    assert!(notes.contains("no longer does"), "{notes}");
    assert!(!b.hook().exists());
    let (_, st) = b.json(&["theme", "follow"]);
    assert_eq!(st["data"]["following"], false);
    // A later switch in Omarchy changes nothing.
    b.omarchy_fixture("white");
    let before = fs::read(b.cfg().join("current/theme.json")).unwrap();
    b.run(&["theme", "follow", "omarchy", "--sync"]);
    assert_eq!(
        fs::read(b.cfg().join("current/theme.json")).unwrap(),
        before
    );
    // Setting `omarchy` itself keeps following.
    b.json(&["theme", "follow", "omarchy"]);
    let (_, v) = b.json(&["theme", "set", "omarchy"]);
    assert!(!v["data"]["notes"].to_string().contains("no longer does"));
    assert!(b.hook().exists());
}

#[test]
fn following_twice_keeps_the_theme_from_before_the_first_time() {
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    b.run(&["theme", "set", "parchment"]);
    b.json(&["theme", "follow", "omarchy"]);
    b.omarchy_fixture("nord");
    b.json(&["theme", "follow", "omarchy"]);
    let (ok, v) = b.json(&["theme", "follow", "off"]);
    assert!(ok);
    assert_eq!(v["data"]["theme"], "parchment");
}

#[test]
fn a_user_theme_called_omarchy_that_is_not_ours_is_not_replaced() {
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    fs::create_dir_all(b.cfg().join("themes")).unwrap();
    fs::write(
        b.cfg().join("themes/omarchy.toml"),
        "name = \"omarchy\"\ntitle = \"Mine\"\nextends = \"calm\"\n",
    )
    .unwrap();
    let (ok, v) = b.json(&["theme", "follow", "omarchy"]);
    assert!(!ok);
    assert_eq!(v["error"]["code"], "exists");
    assert!(!b.hook().exists());
}

#[test]
fn undo_steps_back_over_a_follow() {
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    b.run(&["theme", "set", "evening"]);
    b.json(&["theme", "follow", "omarchy"]);
    let (ok, v) = b.json(&["theme", "undo"]);
    assert!(ok, "{v}");
    let (_, cur) = b.json(&["theme", "current"]);
    assert_eq!(cur["data"]["theme"], "evening");
    // State and hook agree: no longer following, so no hook.
    assert!(!b.hook().exists());
    let (_, st) = b.json(&["theme", "follow"]);
    assert_eq!(st["data"]["following"], false);
    assert_eq!(st["data"]["hook_agrees"], true);
    // A first-time follow that is undone leaves nothing behind either.
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    b.json(&["theme", "follow", "omarchy"]);
    assert!(b.hook().exists());
    let (ok, _) = b.json(&["theme", "undo"]);
    assert!(ok);
    assert!(!b.hook().exists());
    let (_, st) = b.json(&["theme", "follow"]);
    assert_eq!(st["data"]["following"], false);
}

#[test]
fn mcp_theme_follow_has_the_same_envelope() {
    use std::io::Write;
    use std::process::Stdio;
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    let mut child = b
        .cmd(&["mcp"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    let msgs = [
        json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}),
        json!({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"theme_follow","arguments":{}}}),
        json!({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"theme_follow","arguments":{"target":"omarchy"}}}),
        json!({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"theme_follow","arguments":{"target":"off"}}}),
        json!({"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"theme_follow","arguments":{"target":"sideways"}}}),
    ];
    for m in msgs {
        writeln!(input, "{m}").unwrap();
    }
    drop(input);
    let out = child.wait_with_output().unwrap();
    let replies: Vec<Value> = String::from_utf8_lossy(&out.stdout)
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    let by = |id: i64| replies.iter().find(|r| r["id"] == id).unwrap()["result"].clone();
    assert_eq!(by(2)["structuredContent"]["data"]["following"], false);
    let on = by(3);
    assert_eq!(on["isError"], false);
    assert_eq!(on["structuredContent"]["ok"], true);
    assert_eq!(
        on["structuredContent"]["data"]["theme"],
        "omarchy-overrides"
    );
    assert!(on["structuredContent"]["data"]["notes"].is_array());
    assert_eq!(by(4)["structuredContent"]["data"]["following"], false);
    assert!(!b.hook().exists());
    assert_eq!(by(5)["isError"], true);
}

#[test]
fn doctor_says_nothing_about_omarchy_where_there_is_none() {
    let b = Sandbox::new();
    let o = b.run(&["doctor"]);
    assert!(!stdout(&o).contains("omarchy"));
}

fn contrast_of(a: &str, b: &str) -> f64 {
    let lum = |h: &str| {
        let c = |i: usize| {
            let v = f64::from(u8::from_str_radix(&h[i..i + 2], 16).unwrap()) / 255.0;
            if v <= 0.04045 {
                v / 12.92
            } else {
                ((v + 0.055) / 1.055).powf(2.4)
            }
        };
        0.2126 * c(1) + 0.7152 * c(3) + 0.0722 * c(5)
    };
    let (x, y) = (lum(a), lum(b));
    (x.max(y) + 0.05) / (x.min(y) + 0.05)
}

fn dark(b: &Sandbox) -> Value {
    b.exported()["surfaces"]["spaces"]["dark"].clone()
}

#[test]
fn changes_on_top_survive_every_theme_switch() {
    let b = Sandbox::new();
    b.omarchy_fixture("tokyo-night");
    assert!(b.json(&["theme", "follow", "omarchy"]).0);
    for args in [
        ["theme", "change", "dark.accent", "#ffcc66"],
        ["theme", "change", "shape.radius", "6"],
        ["theme", "change", "type.ui", "Georgia, serif"],
        [
            "theme",
            "change",
            "surface.browser.dark.selection",
            "#334466",
        ],
    ] {
        let (ok, v) = b.json(&args);
        assert!(ok, "{args:?}: {v}");
        // A change never stops following.
        assert!(b.hook().exists());
    }
    let mut seen = Vec::new();
    for t in ["nord", "gruvbox", "kanagawa"] {
        b.omarchy_fixture(t);
        let o = b.run(&["theme", "follow", "omarchy", "--sync"]);
        assert!(
            o.status.success(),
            "{t}: {}",
            String::from_utf8_lossy(&o.stderr)
        );
        let out = b.exported();
        let d = &out["surfaces"]["spaces"]["dark"];
        assert_eq!(d["accent"], "#ffcc66", "{t}: the accent override wins");
        seen.push(s(&d["background"]));
        assert_eq!(out["surfaces"]["spaces"]["shape"]["radius"], 6, "{t}");
        assert!(
            s(&out["surfaces"]["spaces"]["type"]["ui"]).contains("Georgia"),
            "{t}"
        );
        assert_eq!(
            out["surfaces"]["browser"]["dark"]["selection"], "#334466",
            "{t}"
        );
        let (_, cur) = b.json(&["theme", "current"]);
        assert_eq!(cur["data"]["theme"], "omarchy-overrides");
    }
    seen.sort();
    seen.dedup();
    assert_eq!(seen.len(), 3, "the backgrounds changed: {seen:?}");
    // The status lists what is in force.
    let (_, st) = b.json(&["theme", "follow"]);
    let paths: Vec<String> = st["data"]["overrides"]
        .as_array()
        .unwrap()
        .iter()
        .map(|o| s(&o["path"]))
        .collect();
    assert!(paths.contains(&"dark.accent".to_string()), "{paths:?}");
    assert!(paths.contains(&"shape.radius".to_string()), "{paths:?}");
    let human = stdout(&b.run(&["theme", "follow"]));
    assert!(human.contains("dark.accent = #ffcc66"), "{human}");
}

#[test]
fn accent_command_is_an_override_too() {
    let b = Sandbox::new();
    b.omarchy_fixture("tokyo-night");
    b.json(&["theme", "follow", "omarchy"]);
    let (ok, v) = b.json(&["theme", "accent", "#ffcc66", "--mode", "dark"]);
    assert!(ok, "{v}");
    assert!(b.hook().exists());
    for t in ["nord", "kanagawa", "gruvbox"] {
        b.omarchy_fixture(t);
        assert!(b
            .run(&["theme", "follow", "omarchy", "--sync"])
            .status
            .success());
        assert_eq!(dark(&b)["accent"], "#ffcc66", "{t}");
    }
    // Reset clears it, and undo brings it back.
    let (ok, v) = b.json(&["theme", "follow", "reset"]);
    assert!(ok, "{v}");
    assert_ne!(dark(&b)["accent"], "#ffcc66");
    assert!(b.hook().exists());
    let (_, st) = b.json(&["theme", "follow"]);
    assert_eq!(st["data"]["following"], true);
    assert!(st["data"]["overrides"].as_array().unwrap().is_empty());
    let (ok, v) = b.json(&["theme", "undo"]);
    assert!(ok, "{v}");
    assert_eq!(dark(&b)["accent"], "#ffcc66");
}

#[test]
fn reset_returns_to_pure_omarchy_and_undo_reverses_a_change() {
    let b = Sandbox::new();
    b.omarchy_fixture("tokyo-night");
    b.json(&["theme", "follow", "omarchy"]);
    let pure = b.exported();
    b.json(&["theme", "change", "dark.accent", "#ffcc66"]);
    b.json(&["theme", "change", "shape.radius", "9"]);
    assert_ne!(b.exported(), pure);
    // undo reverses one change as usual.
    assert!(b.json(&["theme", "undo"]).0);
    assert_eq!(b.exported()["surfaces"]["spaces"]["shape"]["radius"], 0);
    assert_eq!(dark(&b)["accent"], "#ffcc66");
    let (ok, v) = b.json(&["theme", "follow", "reset"]);
    assert!(ok, "{v}");
    assert_eq!(b.exported(), pure);
    // Not following: reset says so and changes nothing.
    b.json(&["theme", "follow", "off"]);
    let (ok, v) = b.json(&["theme", "follow", "reset"]);
    assert!(!ok);
    assert_eq!(v["error"]["code"], "not_following");
}

#[test]
fn an_override_that_fails_on_a_later_theme_is_nudged_noted_and_restored() {
    let b = Sandbox::new();
    b.omarchy("dim", "mode = \"dark\"\nbackground = \"#101010\"\nforeground = \"#e0e0e0\"\naccent = \"#4488ff\"\n");
    b.json(&["theme", "follow", "omarchy"]);
    let (ok, v) = b.json(&["theme", "change", "dark.accent", "#e8b44a"]);
    assert!(ok, "{v}");
    // A pale "dark" theme: the yellow no longer reads on it.
    b.omarchy("pale", "mode = \"dark\"\nbackground = \"#f0f0f0\"\nforeground = \"#101010\"\naccent = \"#4488ff\"\n");
    let (ok, v) = b.json(&["theme", "follow", "omarchy", "--sync"]);
    assert!(ok, "the switch is never failed: {v}");
    let d = dark(&b);
    assert_ne!(d["accent"], "#e8b44a");
    assert!(contrast_of(&s(&d["accent"]), &s(&d["background"])) >= 4.5);
    assert!(contrast_of(&s(&d["accent"]), &s(&d["surface"])) >= 4.5);
    let notes = v["data"]["notes"].to_string();
    assert!(
        notes.contains("dark.accent: #e8b44a with your changes"),
        "{notes}"
    );
    let (_, st) = b.json(&["theme", "follow"]);
    let o = st["data"]["overrides"]
        .as_array()
        .unwrap()
        .iter()
        .find(|o| o["path"] == "dark.accent")
        .unwrap()
        .clone();
    assert_eq!(o["adjusted"], true);
    assert_eq!(o["yours"], "#e8b44a");
    // Back on a theme where it reads: the exact color is back.
    b.omarchy("dim", "mode = \"dark\"\nbackground = \"#101010\"\nforeground = \"#e0e0e0\"\naccent = \"#4488ff\"\n");
    assert!(b
        .run(&["theme", "follow", "omarchy", "--sync"])
        .status
        .success());
    assert_eq!(dark(&b)["accent"], "#e8b44a");
    // The same through the accent command.
    b.json(&["theme", "follow", "reset"]);
    let (ok, v) = b.json(&["theme", "accent", "#e8b44a", "--mode", "dark"]);
    assert!(ok, "{v}");
    b.omarchy("pale", "mode = \"dark\"\nbackground = \"#f0f0f0\"\nforeground = \"#101010\"\naccent = \"#4488ff\"\n");
    let (ok, v) = b.json(&["theme", "follow", "omarchy", "--sync"]);
    assert!(ok, "{v}");
    assert!(contrast_of(&s(&dark(&b)["accent"]), "#f0f0f0") >= 4.5);
    b.omarchy("dim", "mode = \"dark\"\nbackground = \"#101010\"\nforeground = \"#e0e0e0\"\naccent = \"#4488ff\"\n");
    assert!(b
        .run(&["theme", "follow", "omarchy", "--sync"])
        .status
        .success());
    assert_eq!(dark(&b)["accent"], "#e8b44a");
}

#[test]
fn choosing_something_else_then_following_again_keeps_the_changes() {
    let b = Sandbox::new();
    b.omarchy_fixture("tokyo-night");
    b.json(&["theme", "follow", "omarchy"]);
    b.json(&["theme", "change", "dark.accent", "#ffcc66"]);
    let (ok, _) = b.json(&["theme", "set", "calm"]);
    assert!(ok);
    assert!(!b.hook().exists());
    b.omarchy_fixture("nord");
    let (ok, v) = b.json(&["theme", "follow", "omarchy"]);
    assert!(ok, "{v}");
    assert!(v["data"]["notes"].to_string().contains("earlier changes"));
    assert_eq!(dark(&b)["accent"], "#ffcc66");
    assert_eq!(dark(&b)["background"], "#2e3440");
    let (_, v) = b.json(&["theme", "follow", "off"]);
    assert_eq!(v["data"]["theme"], "calm");
}

#[test]
fn first_use_on_omarchy_follows_by_default_and_says_so() {
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    assert!(!b.cfg().join("config.toml").exists());
    let (_, st) = b.json(&["theme", "follow"]);
    assert_eq!(st["data"]["following"], false);
    let (ok, v) = b.json(&["theme", "accent", "#ffcc66"]);
    assert!(ok, "{v}");
    let notes = v["data"]["notes"].to_string();
    assert!(
        notes.contains("follows Omarchy's theme by default"),
        "{notes}"
    );
    assert!(notes.contains("follow off"), "{notes}");
    assert!(b.hook().exists());
    let (_, cur) = b.json(&["theme", "current"]);
    assert_eq!(cur["data"]["theme"], "omarchy-overrides");
    let d = dark(&b);
    assert_eq!(d["background"], "#1a1b26");
    assert_eq!(d["accent"], "#ffcc66");
    // `change` starts it the same way.
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    let (ok, v) = b.json(&["theme", "change", "shape.radius", "4"]);
    assert!(ok, "{v}");
    assert!(v["data"]["notes"].to_string().contains("by default"));
    assert!(b.hook().exists());
}

#[test]
fn an_existing_choice_is_never_overridden_and_no_omarchy_means_no_change() {
    // A choice already made.
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    assert!(b.run(&["theme", "set", "evening"]).status.success());
    let (ok, v) = b.json(&["theme", "change", "shape.radius", "4"]);
    assert!(ok, "{v}");
    assert!(!v["data"]["notes"].to_string().contains("by default"));
    assert!(!b.hook().exists());
    let (_, cur) = b.json(&["theme", "current"]);
    assert_eq!(cur["data"]["theme"], "evening-custom");
    // Choosing a theme is a choice too.
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    assert!(b.run(&["theme", "set", "calm"]).status.success());
    assert!(!b.hook().exists());
    // No Omarchy: nothing changes.
    let b = Sandbox::new();
    let (ok, v) = b.json(&["theme", "accent", "#ffcc66"]);
    assert!(ok, "{v}");
    assert!(!v.to_string().contains("Omarchy"));
    assert!(!b.home().join(".config").exists());
    let (_, cur) = b.json(&["theme", "current"]);
    assert_eq!(cur["data"]["theme"], "polycarp");
}

#[test]
fn status_and_doctor_report_a_hook_that_disagrees_with_the_settings() {
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    b.json(&["theme", "follow", "omarchy"]);
    // Settings changed behind our back; the hook stays.
    fs::write(
        b.cfg().join("config.toml"),
        "[appearance]\ntheme = \"calm\"\nmode = \"auto\"\n",
    )
    .unwrap();
    let (_, st) = b.json(&["theme", "follow"]);
    assert_eq!(st["data"]["hook_agrees"], false);
    assert!(stdout(&b.run(&["theme", "follow"]))
        .contains("hook is installed but Polycarp is not following"));
    assert!(stdout(&b.run(&["doctor"])).contains("a Polycarp hook is installed"));
    // And the other way: following, hook gone.
    b.json(&["theme", "follow", "omarchy"]);
    fs::remove_file(b.hook()).unwrap();
    let (_, st) = b.json(&["theme", "follow"]);
    assert_eq!(st["data"]["hook_agrees"], false);
    assert!(stdout(&b.run(&["doctor"])).contains("hook is missing"));
}

fn in_dir(b: &Sandbox, dir: &Path, args: &[&str]) -> Output {
    let mut c = b.cmd(args);
    c.env("POLYCARP_CONFIG_DIR", dir);
    c.output().unwrap()
}

fn light_dark(b: &Sandbox) -> (String, String) {
    let out = b.exported();
    (
        s(&out["mode"]),
        s(&out["surfaces"]["spaces"][s(&out["mode"])]["background"]),
    )
}

#[test]
fn every_state_writing_command_follows_first_on_a_fresh_omarchy_except_the_choices() {
    // reset and on follow.
    for args in [["theme", "reset"], ["theme", "on"]] {
        let b = Sandbox::new();
        b.omarchy("tokyo-night", TOKYO);
        let (ok, v) = b.json(&args);
        assert!(ok, "{args:?}: {v}");
        assert!(b.hook().exists(), "{args:?}");
        let (_, cur) = b.json(&["theme", "current"]);
        assert_eq!(cur["data"]["theme"], "omarchy-overrides", "{args:?}");
        assert!(
            v["data"]["notes"].to_string().contains("by default"),
            "{args:?}"
        );
    }
    // set, apply and off are choices.
    for args in [["theme", "set", "calm"], ["theme", "off", ""]] {
        let b = Sandbox::new();
        b.omarchy("tokyo-night", TOKYO);
        let a: Vec<&str> = args.iter().copied().filter(|x| !x.is_empty()).collect();
        assert!(b.run(&a).status.success());
        assert!(!b.hook().exists(), "{args:?}");
    }
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    let file = b.root.join("mine.toml");
    fs::write(
        &file,
        "name = \"mine\"\ntitle = \"Mine\"\nextends = \"calm\"\n",
    )
    .unwrap();
    assert!(b
        .run(&["theme", "apply", file.to_str().unwrap()])
        .status
        .success());
    assert!(!b.hook().exists());
}

#[test]
fn if_fresh_is_for_installers() {
    // Fresh with Omarchy: starts.
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    let (ok, v) = b.json(&["theme", "follow", "omarchy", "--if-fresh"]);
    assert!(ok, "{v}");
    assert_eq!(v["data"]["started"], true);
    assert!(b.hook().exists());
    // Again: settings exist, nothing happens, exit 0.
    let before = fs::read(b.cfg().join("config.toml")).unwrap();
    let (ok, v) = b.json(&["theme", "follow", "omarchy", "--if-fresh"]);
    assert!(ok);
    assert_eq!(v["data"]["started"], false);
    assert_eq!(fs::read(b.cfg().join("config.toml")).unwrap(), before);
    // A choice already made.
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    b.run(&["theme", "set", "calm"]);
    let o = b.run(&["theme", "follow", "omarchy", "--if-fresh"]);
    assert_eq!(o.status.code(), Some(0));
    assert!(!b.hook().exists());
    // No Omarchy: exit 0, nothing written.
    let b = Sandbox::new();
    let o = b.run(&["theme", "follow", "omarchy", "--if-fresh"]);
    assert_eq!(o.status.code(), Some(0));
    assert!(!b.cfg().join("config.toml").exists());
    assert!(!b.home().join(".config").exists());
}

#[test]
fn a_refused_first_command_starts_nothing_and_a_late_refusal_carries_the_note() {
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    for args in [
        ["theme", "change", "dark.accent", "notacolor"],
        ["theme", "change", "no.such.path", "x"],
        ["theme", "accent", "notacolor", ""],
    ] {
        let a: Vec<&str> = args.iter().copied().filter(|x| !x.is_empty()).collect();
        let (ok, _) = b.json(&a);
        assert!(!ok, "{args:?}");
        assert!(!b.hook().exists(), "{args:?}");
        assert!(!b.cfg().join("config.toml").exists(), "{args:?}");
    }
    // A refusal that only the engine can make comes after following began: the error says so.
    let (ok, v) = b.json(&["theme", "change", "dark.accent", "#222233"]);
    assert!(!ok);
    assert!(
        v["error"]["suggestion"]
            .as_str()
            .unwrap()
            .contains("had just started following"),
        "{v}"
    );
}

#[test]
fn first_use_reports_the_moves_and_warnings_of_the_follow() {
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    let (ok, v) = b.json(&["theme", "accent", "#ffcc66"]);
    assert!(ok, "{v}");
    let notes = v["data"]["notes"].to_string();
    assert!(
        notes.contains("dark.muted:"),
        "the move is reported: {notes}"
    );
    assert!(v["data"]["nudges"].to_string().contains("dark.muted"));
}

#[test]
fn undo_keeps_hook_and_colors_in_line_after_a_sync() {
    // change, then Omarchy goes light and a sync runs, then undo.
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    b.json(&["theme", "follow", "omarchy"]);
    assert!(b.json(&["theme", "change", "shape.radius", "6"]).0);
    b.omarchy_fixture("white");
    assert!(b
        .run(&["theme", "follow", "omarchy", "--sync"])
        .status
        .success());
    assert_eq!(light_dark(&b).0, "light");
    let (ok, v) = b.json(&["theme", "undo"]);
    assert!(ok, "no changed_since: {v}");
    assert_eq!(b.exported()["surfaces"]["spaces"]["shape"]["radius"], 0);
    assert_eq!(
        light_dark(&b),
        ("light".into(), "#ffffff".into()),
        "the colors are Omarchy's current ones"
    );
    assert!(b.hook().exists());

    // follow off, then undo: following again, hook back.
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    b.json(&["theme", "follow", "omarchy"]);
    b.json(&["theme", "follow", "off"]);
    assert!(!b.hook().exists());
    let (ok, v) = b.json(&["theme", "undo"]);
    assert!(ok, "{v}");
    assert!(b.hook().exists());
    let (_, st) = b.json(&["theme", "follow"]);
    assert_eq!(st["data"]["following"], true, "{st}");
    assert_eq!(st["data"]["hook_agrees"], true);

    // set, then undo.
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    b.json(&["theme", "follow", "omarchy"]);
    b.json(&["theme", "set", "calm"]);
    assert!(!b.hook().exists());
    let (ok, v) = b.json(&["theme", "undo"]);
    assert!(ok, "{v}");
    assert!(b.hook().exists());
    assert_eq!(b.json(&["theme", "follow"]).1["data"]["following"], true);

    // reset, then undo.
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    b.json(&["theme", "follow", "omarchy"]);
    b.json(&["theme", "reset"]);
    assert!(!b.hook().exists());
    let (ok, v) = b.json(&["theme", "undo"]);
    assert!(ok, "{v}");
    assert!(b.hook().exists());
    assert_eq!(b.json(&["theme", "follow"]).1["data"]["following"], true);
}

#[test]
fn a_sync_that_moved_a_color_does_not_block_undo() {
    let b = Sandbox::new();
    b.omarchy("dim", "mode = \"dark\"\nbackground = \"#101010\"\nforeground = \"#e0e0e0\"\naccent = \"#4488ff\"\n");
    b.json(&["theme", "follow", "omarchy"]);
    assert!(b.json(&["theme", "change", "dark.accent", "#e8b44a"]).0);
    b.omarchy("pale", "mode = \"dark\"\nbackground = \"#f0f0f0\"\nforeground = \"#101010\"\naccent = \"#4488ff\"\n");
    assert!(b
        .run(&["theme", "follow", "omarchy", "--sync"])
        .status
        .success());
    assert_ne!(dark(&b)["accent"], "#e8b44a");
    let (ok, v) = b.json(&["theme", "undo"]);
    assert!(ok, "the sync's move must not look like an edit: {v}");
    assert_eq!(
        b.exported()["surfaces"]["spaces"]["dark"]["background"],
        "#f0f0f0"
    );
}

#[test]
fn off_then_a_switch_then_on_brings_the_new_colors() {
    let b = Sandbox::new();
    b.omarchy_fixture("tokyo-night");
    b.json(&["theme", "follow", "omarchy"]);
    assert!(b.run(&["theme", "off"]).status.success());
    b.omarchy_fixture("white");
    let o = b.run(&["theme", "follow", "omarchy", "--sync"]);
    assert!(o.status.success());
    assert!(
        !b.cfg().join("current/theme.json").exists(),
        "off stays off"
    );
    let (ok, v) = b.json(&["theme", "on"]);
    assert!(ok, "{v}");
    assert_eq!(light_dark(&b), ("light".into(), "#ffffff".into()));
}

#[test]
fn a_moved_color_is_put_back_before_following_stops() {
    let b = Sandbox::new();
    b.omarchy("dim", "mode = \"dark\"\nbackground = \"#101010\"\nforeground = \"#e0e0e0\"\naccent = \"#4488ff\"\n");
    b.json(&["theme", "follow", "omarchy"]);
    b.json(&["theme", "change", "dark.accent", "#e8b44a"]);
    b.json(&["theme", "accent", "#e8b44a", "--mode", "light"]);
    b.omarchy("pale", "mode = \"dark\"\nbackground = \"#f0f0f0\"\nforeground = \"#101010\"\naccent = \"#4488ff\"\n");
    assert!(b
        .run(&["theme", "follow", "omarchy", "--sync"])
        .status
        .success());
    assert_ne!(dark(&b)["accent"], "#e8b44a");
    for stop in [vec!["theme", "set", "calm"], vec!["theme", "follow", "off"]] {
        let t = fs::read_to_string(b.cfg().join("themes/omarchy-overrides.toml")).unwrap();
        let (ok, v) = b.json(&stop);
        assert!(ok, "{v}");
        let after = fs::read_to_string(b.cfg().join("themes/omarchy-overrides.toml")).unwrap();
        assert!(
            after.contains("#e8b44a"),
            "yours is back in the file: {after}\n(was {t})"
        );
        b.omarchy("dim", "mode = \"dark\"\nbackground = \"#101010\"\nforeground = \"#e0e0e0\"\naccent = \"#4488ff\"\n");
        assert!(b.json(&["theme", "follow", "omarchy"]).0);
        assert_eq!(dark(&b)["accent"], "#e8b44a");
        b.omarchy("pale", "mode = \"dark\"\nbackground = \"#f0f0f0\"\nforeground = \"#101010\"\naccent = \"#4488ff\"\n");
        assert!(b
            .run(&["theme", "follow", "omarchy", "--sync"])
            .status
            .success());
    }
}

#[test]
fn accents_from_before_come_back_and_following_starts_from_omarchys_accent() {
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    b.run(&["theme", "set", "evening"]);
    assert!(b
        .run(&["theme", "accent", "#8fb3ff", "--mode", "dark"])
        .status
        .success());
    let (ok, v) = b.json(&["theme", "follow", "omarchy"]);
    assert!(ok, "{v}");
    assert_eq!(
        dark(&b)["accent"],
        "#7aa2f7",
        "starts from Omarchy's own accent"
    );
    assert!(v["data"]["notes"].to_string().contains("put aside"));
    assert!(b
        .run(&["theme", "accent", "#ffcc66", "--mode", "dark"])
        .status
        .success());
    let (_, v) = b.json(&["theme", "follow", "off"]);
    assert_eq!(v["data"]["theme"], "evening");
    assert_eq!(v["data"]["accent_dark"], "#8fb3ff", "{v}");
    // The accent set while following is kept as a change on top.
    let t = fs::read_to_string(b.cfg().join("themes/omarchy-overrides.toml")).unwrap();
    assert!(t.contains("#ffcc66"), "{t}");
}

#[cfg(unix)]
#[test]
fn the_hook_logs_a_missing_program_and_a_failed_sync_and_status_says_so() {
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    b.json(&["theme", "follow", "omarchy"]);
    let text = fs::read_to_string(b.hook()).unwrap();
    let exe = fs::canonicalize(env!("CARGO_BIN_EXE_polycarp")).unwrap();
    fs::write(
        b.hook(),
        text.replace(&exe.display().to_string(), "/nonexistent/polycarp"),
    )
    .unwrap();
    let run = || {
        Command::new("bash")
            .arg(b.hook())
            .arg("x")
            .env_clear()
            .env("HOME", b.home())
            .output()
            .unwrap()
    };
    let o = run();
    assert_eq!(o.status.code(), Some(0));
    assert!(o.stdout.is_empty() && o.stderr.is_empty());
    let log = fs::read_to_string(b.cfg().join("follow.log")).unwrap();
    assert!(
        log.contains("FAILED") && log.contains("is missing"),
        "{log}"
    );
    let (_, st) = b.json(&["theme", "follow"]);
    assert_eq!(st["data"]["hook_exe_exists"], false);
    assert!(st["data"]["last_failure"]
        .as_str()
        .unwrap()
        .contains("missing"));
    let d = stdout(&b.run(&["doctor"]));
    assert!(
        d.contains("which does not exist") && d.contains("last sync problem"),
        "{d}"
    );
    // A failed sync inside the program is logged too.
    fs::write(b.hook(), text).unwrap();
    fs::remove_file(b.state().join("current/theme/colors.toml")).unwrap();
    assert_eq!(run().status.code(), Some(0));
    let log = fs::read_to_string(b.cfg().join("follow.log")).unwrap();
    assert!(log.lines().last().unwrap().contains("FAILED"), "{log}");
}

#[test]
fn the_hook_cannot_stall_a_switch() {
    // Only where `timeout` exists.
    let has = Command::new("bash")
        .args(["-c", "command -v timeout"])
        .output()
        .unwrap()
        .status
        .success();
    if !has {
        eprintln!("no timeout command here; skipped");
        return;
    }
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    b.json(&["theme", "follow", "omarchy"]);
    let slow = b.root.join("slow");
    fs::write(&slow, "#!/bin/bash\nsleep 30\n").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&slow, fs::Permissions::from_mode(0o755)).unwrap();
    }
    let text = fs::read_to_string(b.hook()).unwrap();
    let exe = fs::canonicalize(env!("CARGO_BIN_EXE_polycarp")).unwrap();
    fs::write(
        b.hook(),
        text.replace(&exe.display().to_string(), &slow.display().to_string()),
    )
    .unwrap();
    let t = std::time::Instant::now();
    let o = Command::new("bash")
        .arg(b.hook())
        .env_clear()
        .env("HOME", b.home())
        .output()
        .unwrap();
    assert_eq!(o.status.code(), Some(0));
    assert!(t.elapsed().as_secs() < 15, "{:?}", t.elapsed());
}

#[test]
fn a_palette_no_single_text_color_can_serve_moves_a_surface_never_the_background() {
    let b = Sandbox::new();
    b.omarchy(
        "gray",
        "mode = \"dark\"\nbackground = \"#777777\"\nlighter_background = \"#a0a0a0\"\ndark_background = \"#404040\"\nforeground = \"#eeeeee\"\naccent = \"#4488ff\"\nred = \"#ff0000\"\nyellow = \"#ffff00\"\ngreen = \"#00ff00\"\nselection = \"#555555\"\n",
    );
    let (ok, v) = b.json(&["theme", "follow", "omarchy"]);
    assert!(ok, "never refused: {v}");
    let d = dark(&b);
    assert_eq!(d["background"], "#777777");
    let moved: Vec<String> = v["data"]["nudges"]
        .as_array()
        .unwrap()
        .iter()
        .map(|n| s(&n["path"]))
        .collect();
    assert!(
        moved
            .iter()
            .any(|p| p == "dark.surface" || p == "dark.sunken"),
        "{moved:?}"
    );
    assert!(!moved.iter().any(|p| p == "dark.background"));
    for bg in ["background", "surface", "sunken", "selection"] {
        assert!(contrast_of(&s(&d["foreground"]), &s(&d[bg])) >= 4.5, "{bg}");
    }
}

#[test]
fn status_shows_what_is_in_force_not_what_was_moved() {
    let b = Sandbox::new();
    b.omarchy("dim", "mode = \"dark\"\nbackground = \"#101010\"\nforeground = \"#e0e0e0\"\naccent = \"#4488ff\"\n");
    b.json(&["theme", "follow", "omarchy"]);
    b.json(&["theme", "change", "dark.accent", "#e8b44a"]);
    b.omarchy("pale", "mode = \"dark\"\nbackground = \"#f0f0f0\"\nforeground = \"#101010\"\naccent = \"#4488ff\"\n");
    b.run(&["theme", "follow", "omarchy", "--sync"]);
    // The person sets a new value before the next sync.
    b.json(&["theme", "change", "dark.accent", "#0a3d62"]);
    let (_, st) = b.json(&["theme", "follow"]);
    let o = st["data"]["overrides"]
        .as_array()
        .unwrap()
        .iter()
        .find(|o| o["path"] == "dark.accent")
        .unwrap()
        .clone();
    assert_eq!(o["value"], "#0a3d62", "{o}");
    assert_eq!(o["adjusted"], false);
}

#[test]
fn comments_in_the_overrides_file_survive_a_fit_and_its_reversal() {
    let b = Sandbox::new();
    b.omarchy("dim", "mode = \"dark\"\nbackground = \"#101010\"\nforeground = \"#e0e0e0\"\naccent = \"#4488ff\"\n");
    b.json(&["theme", "follow", "omarchy"]);
    b.json(&["theme", "change", "shape.radius", "5"]);
    let path = b.cfg().join("themes/omarchy-overrides.toml");
    let mut t = fs::read_to_string(&path).unwrap();
    t.push_str("\n# my note about the corners\n");
    fs::write(&path, &t).unwrap();
    b.json(&["theme", "change", "dark.accent", "#e8b44a"]);
    let before = fs::read_to_string(&path).unwrap();
    b.omarchy("pale", "mode = \"dark\"\nbackground = \"#f0f0f0\"\nforeground = \"#101010\"\naccent = \"#4488ff\"\nred = \"#aa0000\"\n");
    assert!(b
        .run(&["theme", "follow", "omarchy", "--sync"])
        .status
        .success());
    assert!(fs::read_to_string(&path)
        .unwrap()
        .contains("# my note about the corners"));
    b.omarchy("dim", "mode = \"dark\"\nbackground = \"#101010\"\nforeground = \"#e0e0e0\"\naccent = \"#4488ff\"\n");
    assert!(b
        .run(&["theme", "follow", "omarchy", "--sync"])
        .status
        .success());
    assert_eq!(
        fs::read_to_string(&path).unwrap(),
        before,
        "back to exactly what the person wrote"
    );
}

#[test]
fn a_hook_for_another_config_folder_is_never_replaced_or_removed() {
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    b.json(&["theme", "follow", "omarchy"]);
    let before = fs::read_to_string(b.hook()).unwrap();
    let other = b.root.join("other-cfg");
    // A first command in another config folder warns and does not take the hook.
    let o = in_dir(&b, &other, &["theme", "accent", "#ffcc66", "--json"]);
    assert!(o.status.success(), "{}", stdout(&o));
    let v: Value = serde_json::from_slice(&o.stdout).unwrap();
    assert!(
        v["data"]["warnings"]
            .to_string()
            .contains("another config folder"),
        "{v}"
    );
    assert_eq!(fs::read_to_string(b.hook()).unwrap(), before);
    // off, set and undo there leave it too.
    for args in [
        vec!["theme", "follow", "off"],
        vec!["theme", "set", "calm"],
        vec!["theme", "reset"],
        vec!["theme", "undo"],
    ] {
        in_dir(&b, &other, &args);
        assert_eq!(fs::read_to_string(b.hook()).unwrap(), before, "{args:?}");
    }
    // The real config still follows.
    assert_eq!(b.json(&["theme", "follow"]).1["data"]["following"], true);
}

#[test]
fn modes_are_inferred_and_matched_in_any_case() {
    let b = Sandbox::new();
    b.omarchy(
        "pale",
        "background = \"#fafafa\"\nforeground = \"#222222\"\naccent = \"#1d4ed8\"\n",
    );
    let (ok, v) = b.json(&["theme", "follow", "omarchy"]);
    assert!(ok, "{v}");
    assert_eq!(v["data"]["mode"], "light");
    assert_eq!(
        b.exported()["surfaces"]["spaces"]["light"]["background"],
        "#fafafa"
    );
    let b = Sandbox::new();
    b.omarchy("pale", "mode = \"Light\"\nbackground = \"#fafafa\"\nforeground = \"#222222\"\naccent = \"#1d4ed8\"\n");
    assert_eq!(
        b.json(&["theme", "follow", "omarchy"]).1["data"]["mode"],
        "light"
    );
    let b = Sandbox::new();
    b.omarchy("odd", "mode = \"???\"\nbackground = \"#101010\"\nforeground = \"#e0e0e0\"\naccent = \"#4488ff\"\n");
    assert_eq!(
        b.json(&["theme", "follow", "omarchy"]).1["data"]["mode"],
        "dark"
    );
}

#[test]
fn reset_works_on_a_broken_overrides_file_and_undo_brings_it_back() {
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    b.json(&["theme", "follow", "omarchy"]);
    b.json(&["theme", "change", "shape.radius", "5"]);
    let path = b.cfg().join("themes/omarchy-overrides.toml");
    fs::write(&path, "this is [[ not toml").unwrap();
    // A sync says what is wrong, in its own words, and logs it.
    let o = b.run(&["theme", "follow", "omarchy", "--sync"]);
    assert_eq!(o.status.code(), Some(1));
    assert!(
        String::from_utf8_lossy(&o.stderr).contains("not valid TOML"),
        "{}",
        String::from_utf8_lossy(&o.stderr)
    );
    assert!(fs::read_to_string(b.cfg().join("follow.log"))
        .unwrap()
        .contains("FAILED"));
    let (ok, v) = b.json(&["theme", "follow", "reset"]);
    assert!(ok, "{v}");
    assert!(fs::read_to_string(&path)
        .unwrap()
        .contains("extends = \"omarchy\""));
    // A file with no extends is replaced too.
    fs::write(&path, "name = \"omarchy-overrides\"\ntitle = \"x\"\n").unwrap();
    let (ok, v) = b.json(&["theme", "follow", "reset"]);
    assert!(ok, "{v}");
}

#[test]
fn set_omarchy_while_following_means_the_overrides_layer_and_keeps_following() {
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    b.json(&["theme", "follow", "omarchy"]);
    let (ok, v) = b.json(&["theme", "set", "omarchy"]);
    assert!(ok, "{v}");
    assert!(
        v["data"]["notes"].to_string().contains("generated base"),
        "{v}"
    );
    assert!(b.hook().exists());
    assert_eq!(b.json(&["theme", "follow"]).1["data"]["following"], true);
}

#[test]
fn a_mode_chosen_while_following_survives_every_switch_until_reset() {
    let b = Sandbox::new();
    b.omarchy_fixture("tokyo-night");
    b.json(&["theme", "follow", "omarchy"]);
    let (ok, v) = b.json(&["theme", "set", "omarchy-overrides", "--mode", "light"]);
    assert!(ok, "{v}");
    assert_eq!(b.exported()["mode"], "light");
    b.omarchy_fixture("nord");
    assert!(b
        .run(&["theme", "follow", "omarchy", "--sync"])
        .status
        .success());
    assert_eq!(
        b.exported()["mode"],
        "light",
        "dark Omarchy theme, light kept"
    );
    let (_, st) = b.json(&["theme", "follow"]);
    assert!(st["data"]["overrides"].to_string().contains("\"mode\""));
    assert!(b.json(&["theme", "follow", "reset"]).0);
    assert_eq!(b.exported()["mode"], "dark");
}

#[test]
fn bad_colors_in_the_overrides_file_are_a_clean_error_not_a_panic() {
    for bad in ["red", "#abc", "#12345g"] {
        let b = Sandbox::new();
        b.omarchy("tokyo-night", TOKYO);
        b.json(&["theme", "follow", "omarchy"]);
        let path = b.cfg().join("themes/omarchy-overrides.toml");
        let mut t = fs::read_to_string(&path).unwrap();
        t.push_str(&format!("\n[dark]\naccent = \"{bad}\"\n"));
        fs::write(&path, t).unwrap();
        for args in [
            vec!["theme", "follow", "omarchy", "--sync"],
            vec!["theme", "follow", "omarchy"],
        ] {
            let o = b.run(&args);
            assert_ne!(
                o.status.code(),
                Some(101),
                "{bad}: panic: {}",
                String::from_utf8_lossy(&o.stderr)
            );
            assert!(
                !String::from_utf8_lossy(&o.stderr).contains("panicked"),
                "{bad}"
            );
        }
    }
}

#[test]
fn a_foreign_file_at_the_hook_place_while_following_is_a_disagreement() {
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    b.json(&["theme", "follow", "omarchy"]);
    fs::write(b.hook(), "#!/bin/bash\necho mine\n").unwrap();
    let (_, st) = b.json(&["theme", "follow"]);
    assert_eq!(st["data"]["hook_agrees"], false);
    assert_eq!(st["data"]["hook_foreign"], true);
    assert!(stdout(&b.run(&["theme", "follow"])).contains("not this config's hook"));
    let d = stdout(&b.run(&["doctor"]));
    assert!(d.contains("not this config's hook"), "{d}");
}

#[test]
fn reset_and_set_remove_our_hook_even_when_the_settings_file_is_broken() {
    for args in [vec!["theme", "reset"], vec!["theme", "set", "calm"]] {
        let b = Sandbox::new();
        b.omarchy("tokyo-night", TOKYO);
        b.json(&["theme", "follow", "omarchy"]);
        fs::write(b.cfg().join("config.toml"), "this is [[ broken").unwrap();
        let o = b.run(&args);
        assert!(
            o.status.success(),
            "{args:?}: {}",
            String::from_utf8_lossy(&o.stderr)
        );
        assert!(!b.hook().exists(), "{args:?}");
    }
}

// Follow-ups from PR 21 (#25).

const DIM: &str =
    "mode = \"dark\"\nbackground = \"#101010\"\nforeground = \"#e0e0e0\"\naccent = \"#4488ff\"\n";
const PALE: &str =
    "mode = \"dark\"\nbackground = \"#f0f0f0\"\nforeground = \"#101010\"\naccent = \"#4488ff\"\n";

fn mode(b: &Sandbox) -> String {
    let (ok, v) = b.json(&["theme", "current"]);
    assert!(ok, "{v}");
    s(&v["data"]["mode"])
}

#[test]
fn another_theme_without_a_mode_gets_the_mode_from_before_following() {
    let b = Sandbox::new();
    assert!(b.json(&["theme", "set", "calm", "--mode", "auto"]).0);
    b.omarchy("tokyo-night", TOKYO);
    b.json(&["theme", "follow", "omarchy"]);
    assert_eq!(mode(&b), "dark");
    assert!(b.json(&["theme", "set", "calm"]).0);
    assert_eq!(
        mode(&b),
        "auto",
        "Omarchy's dark is not a choice of the person's"
    );
    b.json(&["theme", "follow", "omarchy"]);
    assert!(b.json(&["theme", "set", "calm", "--mode", "light"]).0);
    assert_eq!(mode(&b), "light", "a mode given with the theme wins");
}

#[test]
fn a_fitted_color_accepted_with_change_stays() {
    let b = Sandbox::new();
    b.omarchy("dim", DIM);
    b.json(&["theme", "follow", "omarchy"]);
    assert!(b.json(&["theme", "change", "dark.accent", "#e8b44a"]).0);
    b.omarchy("pale", PALE);
    assert!(b
        .run(&["theme", "follow", "omarchy", "--sync"])
        .status
        .success());
    let fitted = s(&dark(&b)["accent"]);
    assert_ne!(fitted, "#e8b44a");
    assert!(b.json(&["theme", "change", "dark.accent", &fitted]).0);
    b.omarchy("dim", DIM);
    assert!(b
        .run(&["theme", "follow", "omarchy", "--sync"])
        .status
        .success());
    let (_, st) = b.json(&["theme", "follow"]);
    let o = st["data"]["overrides"]
        .as_array()
        .unwrap()
        .iter()
        .find(|o| o["path"] == "dark.accent")
        .unwrap()
        .clone();
    assert_eq!(
        o["yours"],
        fitted.as_str(),
        "the person chose it, so no sync takes it back: {o}"
    );
}

#[test]
fn a_sync_whose_refresh_failed_is_finished_by_the_next_one() {
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    b.json(&["theme", "follow", "omarchy"]);
    let current = b.cfg().join("current/theme.json");
    b.omarchy_fixture("white");
    fs::remove_file(&current).unwrap();
    fs::create_dir(&current).unwrap();
    assert!(b
        .run(&["theme", "follow", "omarchy", "--sync"])
        .status
        .success());
    fs::remove_dir(&current).unwrap();
    assert!(b
        .run(&["theme", "follow", "omarchy", "--sync"])
        .status
        .success());
    let json = fs::read_to_string(&current).expect("the second sync writes current/ again");
    assert!(json.contains("light") || json.contains("white"), "{json}");
}

#[test]
fn undo_after_a_sync_and_another_change_takes_back_only_that_change() {
    let b = Sandbox::new();
    b.omarchy("dim", DIM);
    b.json(&["theme", "follow", "omarchy"]);
    assert!(b.json(&["theme", "change", "dark.accent", "#e8b44a"]).0);
    b.omarchy("pale", PALE);
    assert!(b
        .run(&["theme", "follow", "omarchy", "--sync"])
        .status
        .success());
    let fitted = s(&dark(&b)["accent"]);
    assert!(b.json(&["theme", "change", "shape.radius", "9"]).0);
    let (ok, v) = b.json(&["theme", "undo"]);
    assert!(ok, "the change saved the fitted color itself: {v}");
    assert_eq!(b.exported()["surfaces"]["spaces"]["shape"]["radius"], 0);
    assert_eq!(s(&dark(&b)["accent"]), fitted);
}

// Omarchy runs the hook only on Linux, and Git Bash on Windows runs this script differently (the
// sibling hook test above is unix-only for the same reason), so this is checked where Omarchy exists.
#[cfg(unix)]
#[test]
fn a_hook_logging_into_a_deleted_config_folder_prints_nothing() {
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    b.json(&["theme", "follow", "omarchy"]);
    let exe = fs::canonicalize(env!("CARGO_BIN_EXE_polycarp")).unwrap();
    let text = fs::read_to_string(b.hook()).unwrap();
    fs::write(
        b.hook(),
        text.replace(&exe.display().to_string(), "/nonexistent/polycarp"),
    )
    .unwrap();
    fs::remove_dir_all(b.cfg()).unwrap();
    let o = Command::new("bash")
        .arg(b.hook())
        .arg("x")
        .env_clear()
        .env("HOME", b.home())
        .output()
        .unwrap();
    assert_eq!(o.status.code(), Some(0));
    assert!(
        o.stdout.is_empty() && o.stderr.is_empty(),
        "{}",
        String::from_utf8_lossy(&o.stderr)
    );
}

#[test]
fn reset_repairs_the_hook_and_keeps_a_hand_made_omarchy_toml() {
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    b.json(&["theme", "follow", "omarchy"]);
    fs::remove_file(b.hook()).unwrap();
    let (ok, v) = b.json(&["theme", "follow", "reset"]);
    assert!(ok, "{v}");
    assert!(b.hook().exists(), "reset puts a deleted hook back");
    let mine = "name = \"omarchy\"\ntitle = \"Mine\"\n";
    fs::write(b.cfg().join("themes/omarchy.toml"), mine).unwrap();
    let (ok, v) = b.json(&["theme", "follow", "reset"]);
    assert!(!ok);
    assert_eq!(v["error"]["code"], "exists", "{v}");
    assert_eq!(b.theme_file(), mine);
}

#[test]
fn following_again_clears_an_old_failure_from_status() {
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    b.json(&["theme", "follow", "omarchy"]);
    let log = b.cfg().join("follow.log");
    let old = fs::read_to_string(&log).unwrap_or_default();
    fs::write(
        &log,
        format!("{old}2026-01-01T00:00:00Z FAILED: the hook's sync exited 1\n"),
    )
    .unwrap();
    let (_, st) = b.json(&["theme", "follow"]);
    assert!(st["data"]["last_failure"].is_string(), "{st}");
    b.json(&["theme", "follow", "omarchy"]);
    let (_, st) = b.json(&["theme", "follow"]);
    assert!(st["data"]["last_failure"].is_null(), "{st}");
}

#[test]
fn a_bad_overrides_file_while_not_following_does_not_point_at_reset() {
    let b = Sandbox::new();
    b.omarchy("tokyo-night", TOKYO);
    fs::create_dir_all(b.cfg().join("themes")).unwrap();
    fs::write(b.cfg().join("themes/omarchy-overrides.toml"), "not toml [").unwrap();
    let (ok, v) = b.json(&["theme", "follow", "omarchy"]);
    assert!(!ok);
    let hint = v["error"].to_string();
    assert!(hint.contains("move it aside"), "{hint}");
    let (ok, v) = b.json(&["theme", "follow", "reset"]);
    assert!(!ok, "{v}");
}
