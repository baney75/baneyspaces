//! The launcher's brains (spec/ui.md, "Launcher"): desktop entries, the query language (menus,
//! bangs, `?` to ask an agent), ranking, and the actions a result runs. Pure: the daemon fetches the
//! few things that need a process (files with `fd`, packages with `pacman`) and passes them in.

use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

// ---------------------------------------------------------------------------------------------
// Desktop entries

#[derive(Clone, Debug, PartialEq)]
pub struct App {
    pub id: String,
    pub name: String,
    pub generic: String,
    pub comment: String,
    pub keywords: Vec<String>,
    pub exec: String,
    pub icon: String,
    pub terminal: bool,
    pub wm_class: String,
}

/// Splits an Exec line into words, dropping the field codes (%f, %U, ...).
pub fn exec_argv(exec: &str) -> Vec<String> {
    let mut out = vec![];
    let mut cur = String::new();
    let mut in_word = false;
    let mut quote = false;
    let mut it = exec.chars().peekable();
    while let Some(c) = it.next() {
        match c {
            '"' => {
                quote = !quote;
                in_word = true;
            }
            '\\' if quote => {
                if let Some(n) = it.next() {
                    cur.push(n);
                }
            }
            ' ' | '\t' if !quote => {
                if in_word {
                    out.push(std::mem::take(&mut cur));
                    in_word = false;
                }
            }
            '%' => match it.next() {
                Some('%') => {
                    cur.push('%');
                    in_word = true;
                }
                Some(_) => {} // a field code: we pass no files or urls
                None => {}
            },
            c => {
                cur.push(c);
                in_word = true;
            }
        }
    }
    if in_word {
        out.push(cur);
    }
    // `%i` and friends leave a stray `--icon`-less word; drop empty words.
    out.into_iter().filter(|w| !w.is_empty()).collect()
}

pub fn parse_desktop(id: &str, text: &str) -> Option<App> {
    let mut in_entry = false;
    let mut m: HashMap<&str, &str> = HashMap::new();
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_entry = line == "[Desktop Entry]";
            continue;
        }
        if !in_entry || line.starts_with('#') {
            continue;
        }
        if let Some((k, v)) = line.split_once('=') {
            m.entry(k.trim()).or_insert(v.trim());
        }
    }
    let flag = |k: &str| m.get(k).is_some_and(|v| v.eq_ignore_ascii_case("true"));
    if m.get("Type").is_some_and(|t| *t != "Application") || flag("NoDisplay") || flag("Hidden") {
        return None;
    }
    let name = m.get("Name")?.to_string();
    let exec = m.get("Exec")?.to_string();
    Some(App {
        id: id.to_string(),
        name,
        generic: m.get("GenericName").unwrap_or(&"").to_string(),
        comment: m.get("Comment").unwrap_or(&"").to_string(),
        keywords: m
            .get("Keywords")
            .map(|k| {
                k.split(';')
                    .map(|s| s.trim().to_lowercase())
                    .filter(|s| !s.is_empty())
                    .collect()
            })
            .unwrap_or_default(),
        exec,
        icon: m.get("Icon").unwrap_or(&"").to_string(),
        terminal: flag("Terminal"),
        wm_class: m.get("StartupWMClass").unwrap_or(&"").to_string(),
    })
}

/// Entries Omarchy keeps out of its launcher (`launcher.hides`, its own list and yours): helper tools with a desktop file.
pub fn hidden_ids() -> std::collections::HashSet<String> {
    let home = std::env::var("HOME").unwrap_or_default();
    let base = std::env::var("OMARCHY_PATH").unwrap_or_else(|_| "/usr/share/omarchy".into());
    [format!("{base}/default/omarchy/launcher.hides"), format!("{home}/.config/omarchy/launcher.hides")]
        .iter()
        .filter_map(|f| std::fs::read_to_string(f).ok())
        .flat_map(|t| t.lines().map(|l| l.trim().trim_end_matches(".desktop").to_string()).filter(|l| !l.is_empty() && !l.starts_with('#')).collect::<Vec<_>>())
        .collect()
}

pub fn data_dirs() -> Vec<PathBuf> {
    let home = std::env::var("HOME").unwrap_or_default();
    let mut v = vec![std::env::var("XDG_DATA_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from(&home).join(".local/share"))];
    let dirs =
        std::env::var("XDG_DATA_DIRS").unwrap_or_else(|_| "/usr/local/share:/usr/share".into());
    v.extend(dirs.split(':').filter(|d| !d.is_empty()).map(PathBuf::from));
    v.into_iter().map(|d| d.join("applications")).collect()
}

fn walk(dir: &Path, base: &Path, out: &mut Vec<(String, PathBuf)>) {
    let Ok(rd) = std::fs::read_dir(dir) else {
        return;
    };
    for e in rd.flatten() {
        let p = e.path();
        if p.is_dir() {
            walk(&p, base, out);
        } else if p.extension().is_some_and(|x| x == "desktop") {
            if let Ok(rel) = p.strip_prefix(base) {
                out.push((
                    rel.to_string_lossy()
                        .replace('/', "-")
                        .trim_end_matches(".desktop")
                        .to_string(),
                    p.clone(),
                ));
            }
        }
    }
}

/// Every application the user would see, the user's own entries overriding the system's.
pub fn scan_apps(dirs: &[PathBuf]) -> Vec<App> {
    let hidden = hidden_ids();
    let mut seen = std::collections::HashSet::new();
    let mut apps = vec![];
    for d in dirs {
        let mut files = vec![];
        walk(d, d, &mut files);
        files.sort();
        for (id, path) in files {
            if !seen.insert(id.clone()) || hidden.contains(&id) {
                continue;
            }
            if let Some(app) = std::fs::read_to_string(&path)
                .ok()
                .and_then(|t| parse_desktop(&id, &t))
            {
                apps.push(app);
            }
        }
    }
    apps.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    apps
}

/// Does a window of class `class` belong to this app?
pub fn app_owns_class(app: &App, class: &str) -> bool {
    let c = class.to_lowercase();
    if c.is_empty() {
        return false;
    }
    let id = app.id.to_lowercase();
    let exe = exec_argv(&app.exec)
        .first()
        .map(|e| e.rsplit('/').next().unwrap_or(e).to_lowercase())
        .unwrap_or_default();
    app.wm_class.to_lowercase() == c
        || id == c
        || id.ends_with(&format!(".{c}"))
        || exe == c
        || app.name.to_lowercase() == c
}

// ---------------------------------------------------------------------------------------------
// Matching

/// Start offsets of the words of `s`: after any non-alphanumeric, and at camelCase humps.
fn word_starts(s: &str) -> Vec<usize> {
    let chars: Vec<(usize, char)> = s.char_indices().collect();
    let mut v = vec![];
    for (i, (o, c)) in chars.iter().enumerate() {
        if !c.is_alphanumeric() {
            continue;
        }
        let prev = i.checked_sub(1).map(|j| chars[j].1);
        if prev.is_none_or(|p| {
            !p.is_alphanumeric()
                || (p.is_lowercase() && c.is_uppercase())
                || (p.is_alphabetic() != c.is_alphabetic())
        }) {
            v.push(*o);
        }
    }
    v
}

/// Every word of `query` starts a word of `name` (`tax 2025` finds `2025 Tax Return.pdf`).
pub fn words_start(query: &str, name: &str) -> bool {
    let q: Vec<String> = query.split_whitespace().map(|w| w.to_lowercase()).collect();
    if q.is_empty() {
        return false;
    }
    let lower = name.to_lowercase();
    let starts: Vec<usize> = word_starts(name)
        .into_iter()
        .filter(|o| lower.is_char_boundary(*o))
        .collect();
    q.iter()
        .all(|w| starts.iter().any(|o| lower[*o..].starts_with(w.as_str())))
}

/// The first letter of `q` starts a word of `name` (a fuzzy match must begin where a word does).
fn word_initial(q: &str, name: &str) -> bool {
    let lower = name.to_lowercase();
    let first = q.chars().next();
    word_starts(name).into_iter().any(|o| lower.is_char_boundary(o) && lower[o..].chars().next() == first)
}

fn subsequence(q: &str, s: &str) -> bool {
    let mut it = s.chars();
    q.chars().all(|c| it.any(|x| x == c))
}

/// How well `query` matches a name: 0 for no match.
pub fn name_score(query: &str, name: &str) -> u32 {
    let q = query.trim().to_lowercase();
    let n = name.to_lowercase();
    if q.is_empty() || n.is_empty() {
        return 0;
    }
    if n == q {
        1000
    } else if n.starts_with(&q) {
        900u32.saturating_sub((n.len() - q.len()).min(100) as u32)
    } else if words_start(&q, name) {
        700
    } else if n.contains(&q) {
        500
    } else if !q.contains(' ') && q.chars().count() >= 2 && word_initial(&q, name) && subsequence(&q, &n) {
        250
    } else {
        0
    }
}

/// Words of a name, id or keyword list: breaks at non-alphanumerics and at camelCase humps.
fn words_of(s: &str) -> Vec<String> {
    let mut out = vec![];
    let mut cur = String::new();
    let mut prev: Option<char> = None;
    for c in s.chars() {
        let hump = prev.is_some_and(|p| p.is_lowercase() && c.is_uppercase());
        if !c.is_alphanumeric() || hump {
            if !cur.is_empty() {
                out.push(std::mem::take(&mut cur));
            }
        }
        if c.is_alphanumeric() {
            cur.push(c.to_ascii_lowercase());
        }
        prev = Some(c);
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

/// "lw" for LibreOffice Writer: the initials of its name, generic name, keywords and id words, as Omarchy's search reads them.
fn acronym(app: &App) -> String {
    let text = format!("{} {} {} {}", app.name, app.generic, app.keywords.join(" "), app.id);
    words_of(&text).iter().filter_map(|w| w.chars().next()).collect()
}

pub fn app_score(app: &App, query: &str, uses: u32, running: bool) -> u32 {
    let mut best = name_score(query, &app.name);
    best = best.max(name_score(query, &app.generic) * 9 / 10);
    let q = query.trim().to_lowercase();
    if app.keywords.iter().any(|k| *k == q) {
        best = best.max(650); // you typed one of its keywords exactly
    } else if app.keywords.iter().any(|k| k.starts_with(&q)) {
        best = best.max(400);
    }
    if q.chars().count() >= 2 && q.chars().count() <= 5 && !q.contains(' ') {
        let a = acronym(app);
        if a.starts_with(&q) {
            best = best.max(420);
        } else if a.contains(&q) {
            best = best.max(340);
        }
    }
    if best == 0 && q.chars().count() >= 3 && app.comment.to_lowercase().contains(&q) {
        best = 150;
    }
    if best == 0 {
        return 0;
    }
    best + uses.min(20) * 5 + if running { 30 } else { 0 }
}

// ---------------------------------------------------------------------------------------------
// Bangs

#[derive(Clone, Debug, PartialEq)]
pub struct Bang {
    pub trigger: String,
    pub name: String,
    pub url: String,
    pub home: Option<String>,
    pub agent: bool,
}

fn b(trigger: &str, name: &str, url: &str, home: Option<&str>, agent: bool) -> Bang {
    Bang {
        trigger: trigger.into(),
        name: name.into(),
        url: url.into(),
        home: home.map(String::from),
        agent,
    }
}

/// The Mac's built-in bangs that make sense here. `ddg` answers every other bang.
pub fn builtin_bangs() -> Vec<Bang> {
    vec![
        b(
            "claude",
            "Claude",
            "https://claude.ai/new?q={q}",
            Some("https://claude.ai/new"),
            true,
        ),
        b(
            "chatgpt",
            "ChatGPT",
            "https://chatgpt.com/?q={q}",
            Some("https://chatgpt.com/"),
            true,
        ),
        b(
            "pplx",
            "Perplexity",
            "https://www.perplexity.ai/search?q={q}",
            Some("https://www.perplexity.ai/"),
            true,
        ),
        b(
            "grok",
            "Grok",
            "https://grok.com/?q={q}",
            Some("https://grok.com/"),
            true,
        ),
        b(
            "copilot",
            "Microsoft Copilot",
            "https://copilot.microsoft.com/?q={q}",
            Some("https://copilot.microsoft.com/"),
            true,
        ),
        b(
            "lechat",
            "Le Chat",
            "https://chat.mistral.ai/chat?q={q}",
            Some("https://chat.mistral.ai/chat"),
            true,
        ),
        b(
            "g",
            "Google",
            "https://www.google.com/search?q={q}",
            None,
            false,
        ),
        b(
            "ddg",
            "DuckDuckGo",
            "https://duckduckgo.com/?q={q}",
            None,
            false,
        ),
        b(
            "b",
            "Bing",
            "https://www.bing.com/search?q={q}",
            None,
            false,
        ),
        b(
            "yt",
            "YouTube",
            "https://www.youtube.com/results?search_query={q}",
            None,
            false,
        ),
        b(
            "w",
            "Wikipedia",
            "https://en.wikipedia.org/wiki/Special:Search?search={q}",
            None,
            false,
        ),
        b(
            "i",
            "Images",
            "https://www.google.com/search?tbm=isch&q={q}",
            Some("https://images.google.com/"),
            false,
        ),
        b(
            "img",
            "Images",
            "https://www.google.com/search?tbm=isch&q={q}",
            Some("https://images.google.com/"),
            false,
        ),
        b(
            "v",
            "Videos",
            "https://www.google.com/search?tbm=vid&q={q}",
            None,
            false,
        ),
        b(
            "maps",
            "Google Maps",
            "https://www.google.com/maps/search/{q}",
            Some("https://www.google.com/maps"),
            false,
        ),
        b(
            "gh",
            "GitHub",
            "https://github.com/search?q={q}",
            None,
            false,
        ),
        b(
            "r",
            "Reddit",
            "https://www.reddit.com/search/?q={q}",
            None,
            false,
        ),
        b("x", "X", "https://x.com/search?q={q}", None, false),
        b("a", "Amazon", "https://www.amazon.com/s?k={q}", None, false),
        b(
            "so",
            "Stack Overflow",
            "https://stackoverflow.com/search?q={q}",
            None,
            false,
        ),
        b(
            "mdn",
            "MDN Web Docs",
            "https://developer.mozilla.org/en-US/search?q={q}",
            None,
            false,
        ),
        b(
            "npm",
            "npm",
            "https://www.npmjs.com/search?q={q}",
            None,
            false,
        ),
        b(
            "pypi",
            "PyPI",
            "https://pypi.org/search/?q={q}",
            None,
            false,
        ),
        b(
            "crates",
            "crates.io",
            "https://crates.io/search?q={q}",
            None,
            false,
        ),
        b(
            "aur",
            "Arch User Repository",
            "https://aur.archlinux.org/packages?K={q}",
            Some("https://aur.archlinux.org/"),
            false,
        ),
        b(
            "arch",
            "Arch Packages",
            "https://archlinux.org/packages/?q={q}",
            Some("https://archlinux.org/packages/"),
            false,
        ),
        b(
            "wiki",
            "ArchWiki",
            "https://wiki.archlinux.org/index.php?search={q}",
            Some("https://wiki.archlinux.org/"),
            false,
        ),
        b(
            "hf",
            "Hugging Face",
            "https://huggingface.co/models?search={q}",
            None,
            false,
        ),
        b(
            "scholar",
            "Google Scholar",
            "https://scholar.google.com/scholar?q={q}",
            None,
            false,
        ),
        b(
            "t",
            "Google Translate",
            "https://translate.google.com/?text={q}",
            None,
            false,
        ),
        b(
            "d",
            "Merriam-Webster",
            "https://www.merriam-webster.com/dictionary/{q}",
            None,
            false,
        ),
        b(
            "bible",
            "Bible Gateway",
            "https://www.biblegateway.com/quicksearch/?quicksearch={q}",
            None,
            false,
        ),
        b(
            "esv",
            "ESV Bible",
            "https://www.esv.org/search/?q={q}",
            None,
            false,
        ),
        b(
            "imdb",
            "IMDb",
            "https://www.imdb.com/find/?q={q}",
            None,
            false,
        ),
        b(
            "spotify",
            "Spotify",
            "https://open.spotify.com/search/{q}",
            None,
            false,
        ),
        b(
            "news",
            "Google News",
            "https://news.google.com/search?q={q}",
            None,
            false,
        ),
        b(
            "wa",
            "Wolfram Alpha",
            "https://www.wolframalpha.com/input?i={q}",
            None,
            false,
        ),
    ]
}

/// Your bangs (from config.toml) first, so one can replace a built-in.
pub fn all_bangs(custom: &Value) -> Vec<Bang> {
    let mine: Vec<Bang> = custom
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|v| {
            Some(Bang {
                trigger: v["trigger"].as_str()?.into(),
                name: v["name"].as_str()?.into(),
                url: v["url"].as_str()?.into(),
                home: None,
                agent: v["agent"].as_bool().unwrap_or(false),
            })
        })
        .collect();
    let taken: Vec<String> = mine.iter().map(|b| b.trigger.clone()).collect();
    mine.into_iter()
        .chain(
            builtin_bangs()
                .into_iter()
                .filter(|b| !taken.contains(&b.trigger)),
        )
        .collect()
}

/// Everything but letters, digits and `-._~` is percent-encoded, so words can never break out of
/// the address (an `&` or `#` in a search stays part of the search).
pub fn url_encode(s: &str) -> String {
    let mut o = String::new();
    for byte in s.bytes() {
        if byte.is_ascii_alphanumeric() || b"-._~".contains(&byte) {
            o.push(byte as char);
        } else {
            o.push_str(&format!("%{byte:02X}"));
        }
    }
    o
}

/// Only web addresses open; a bang can't run anything else.
pub fn safe_url(u: &str) -> Option<String> {
    (u.starts_with("https://") || u.starts_with("http://")).then(|| u.to_string())
}

impl Bang {
    pub fn address(&self, terms: &str) -> Option<String> {
        let t = terms.trim();
        if t.is_empty() {
            if let Some(h) = &self.home {
                return safe_url(h);
            }
            // The site itself: scheme and host, no path or query.
            let base = self.url.replace("{q}", "");
            let rest = base.split_once("://")?;
            let host = rest.1.split(['/', '?', '#']).next()?;
            return safe_url(&format!("{}://{host}/", rest.0));
        }
        safe_url(&self.url.replace("{q}", &url_encode(t)))
    }
}

// ---------------------------------------------------------------------------------------------
// Queries

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    All,
    Apps,
    Windows,
    Workspaces,
    Files,
    Install,
    Remove,
    Update,
    System,
}

impl Mode {
    pub fn parse(s: &str) -> Mode {
        match s {
            "apps" => Mode::Apps,
            "windows" => Mode::Windows,
            "workspaces" => Mode::Workspaces,
            "files" => Mode::Files,
            "install" => Mode::Install,
            "remove" => Mode::Remove,
            "update" => Mode::Update,
            "system" => Mode::System,
            _ => Mode::All,
        }
    }
}

#[derive(Debug, PartialEq)]
pub struct Query {
    pub mode: Mode,
    pub text: String,
    pub bang: Option<(String, String)>,
    pub ask: Option<String>,
}

/// `!yt cats` and `cats !yt` both give ("yt", "cats").
pub fn parse_bang(q: &str) -> Option<(String, String)> {
    let words: Vec<&str> = q.split_whitespace().collect();
    let trig = |w: &str| {
        w.strip_prefix('!')
            .filter(|t| !t.is_empty())
            .map(|t| t.to_lowercase())
    };
    if let Some(t) = words.first().and_then(|w| trig(w)) {
        return Some((t, words[1..].join(" ")));
    }
    if words.len() > 1 {
        if let Some(t) = trig(words[words.len() - 1]) {
            return Some((t, words[..words.len() - 1].join(" ")));
        }
    }
    None
}

pub fn parse_query(q: &str, mode: Mode) -> Query {
    let q = q.trim();
    if mode == Mode::All {
        if let Some(rest) = q.strip_prefix('?') {
            return Query {
                mode,
                text: String::new(),
                bang: None,
                ask: Some(rest.trim().to_string()),
            };
        }
        if let Some(b) = parse_bang(q) {
            return Query {
                mode,
                text: String::new(),
                bang: Some(b),
                ask: None,
            };
        }
        for (prefix, m) in [
            ("install ", Mode::Install),
            ("remove ", Mode::Remove),
            ("uninstall ", Mode::Remove),
        ] {
            if let Some(rest) = q.strip_prefix(prefix) {
                return Query {
                    mode: m,
                    text: rest.trim().to_string(),
                    bang: None,
                    ask: None,
                };
            }
        }
    }
    Query {
        mode,
        text: q.to_string(),
        bang: None,
        ask: None,
    }
}

// ---------------------------------------------------------------------------------------------
// Calculator and Omarchy's menus

/// `2+3*4`, `(1.5+2)^2`, `10%3`, `-4/8`: arithmetic and nothing else. None if it is not an expression.
pub fn calc(expr: &str) -> Option<String> {
    let e: Vec<char> = expr.chars().filter(|c| !c.is_whitespace()).collect();
    if e.is_empty() || e.len() > 120 || !e.iter().any(|c| c.is_ascii_digit()) || !e.iter().any(|c| "+-*/%^".contains(*c)) {
        return None;
    }
    if !e.iter().all(|c| c.is_ascii_digit() || "+-*/%^().,".contains(*c)) {
        return None;
    }
    struct P<'a> { s: &'a [char], i: usize }
    impl P<'_> {
        fn peek(&self) -> Option<char> { self.s.get(self.i).copied() }
        fn expr(&mut self) -> Option<f64> {
            let mut v = self.term()?;
            while let Some(c @ ('+' | '-')) = self.peek() {
                self.i += 1;
                let r = self.term()?;
                v = if c == '+' { v + r } else { v - r };
            }
            Some(v)
        }
        fn term(&mut self) -> Option<f64> {
            let mut v = self.power()?;
            while let Some(c @ ('*' | '/' | '%')) = self.peek() {
                self.i += 1;
                let r = self.power()?;
                v = match c { '*' => v * r, '/' => v / r, _ => v % r };
            }
            Some(v)
        }
        fn power(&mut self) -> Option<f64> {
            let b = self.unary()?;
            if self.peek() == Some('^') {
                self.i += 1;
                let e = self.power()?;
                return Some(b.powf(e));
            }
            Some(b)
        }
        fn unary(&mut self) -> Option<f64> {
            match self.peek()? {
                '-' => { self.i += 1; Some(-self.unary()?) }
                '+' => { self.i += 1; self.unary() }
                '(' => {
                    self.i += 1;
                    let v = self.expr()?;
                    (self.peek() == Some(')')).then(|| { self.i += 1; v })
                }
                _ => {
                    let st = self.i;
                    while self.peek().is_some_and(|c| c.is_ascii_digit() || c == '.' || c == ',') { self.i += 1; }
                    self.s[st..self.i].iter().filter(|c| **c != ',').collect::<String>().parse().ok()
                }
            }
        }
    }
    let mut p = P { s: &e, i: 0 };
    let v = p.expr()?;
    if p.i != e.len() || !v.is_finite() {
        return None;
    }
    Some(if v.fract() == 0.0 && v.abs() < 1e15 { format!("{}", v as i64) } else { format!("{:.10}", v).trim_end_matches('0').trim_end_matches('.').to_string() })
}

/// Omarchy's root menus from its menu definition (and yours): `"style": {"icon":"…","label":"Style"}`.
pub fn omarchy_menus() -> Vec<(String, String)> {
    let home = std::env::var("HOME").unwrap_or_default();
    let base = std::env::var("OMARCHY_PATH").unwrap_or_else(|_| "/usr/share/omarchy".into());
    let mut out: Vec<(String, String)> = vec![];
    for f in [format!("{base}/default/omarchy/omarchy-menu.jsonc"), format!("{home}/.config/omarchy/extensions/omarchy-menu.jsonc")] {
        let Ok(text) = std::fs::read_to_string(&f) else { continue };
        for line in text.lines() {
            let t = line.trim();
            let Some(rest) = t.strip_prefix('"') else { continue };
            let Some((id, rest)) = rest.split_once("\":") else { continue };
            if id.contains('.') || !id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') || !rest.contains("\"icon\"") {
                continue;
            }
            let Some(label) = rest.split("\"label\":\"").nth(1).and_then(|l| l.split('"').next()) else { continue };
            if rest.contains("\"when\"") || out.iter().any(|(i, _)| i == id) {
                continue;
            }
            out.push((id.to_string(), label.to_string()));
        }
    }
    out
}

// ---------------------------------------------------------------------------------------------
// Results

#[derive(Clone, Debug, PartialEq)]
pub enum Action {
    Launch(String),
    Focus(String),
    Switch(u8),
    Run {
        argv: Vec<String>,
        terminal: bool,
    },
    Url(String),
    OpenPath(String),
    /// Runs in a floating Omarchy terminal (it may need your password); asks first.
    Pkg {
        verb: &'static str,
        name: String,
    },
    Internal(&'static str),
    Nothing,
}

impl Action {
    pub fn needs_confirm(&self) -> bool {
        matches!(self, Action::Pkg { .. })
    }
}

#[derive(Clone, Debug)]
pub struct Hit {
    pub id: String,
    pub section: &'static str,
    pub title: String,
    pub subtitle: String,
    pub icon: String,
    pub score: u32,
    pub badge: Option<String>,
    pub action: Action,
}

impl Hit {
    pub fn json(&self) -> Value {
        json!({ "id": self.id, "section": self.section, "title": self.title, "subtitle": self.subtitle, "icon": self.icon, "badge": self.badge, "confirm": self.action.needs_confirm() })
    }
}

#[derive(Clone, Debug)]
pub struct LWin {
    pub addr: String,
    pub app: String,
    pub title: String,
    pub ws: u8,
    pub badge: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Pkg {
    pub repo: String,
    pub name: String,
    pub version: String,
    pub desc: String,
    pub installed: bool,
}

/// Parses `pacman -Ss` output.
pub fn parse_pacman_ss(out: &str) -> Vec<Pkg> {
    let mut v = vec![];
    let mut lines = out.lines().peekable();
    while let Some(l) = lines.next() {
        if l.starts_with(char::is_whitespace) || l.trim().is_empty() {
            continue;
        }
        let mut words = l.split_whitespace();
        let Some((repo, name)) = words.next().and_then(|f| f.split_once('/')) else {
            continue;
        };
        let version = words.next().unwrap_or("").to_string();
        let installed = l.contains("[installed");
        let desc = lines
            .peek()
            .filter(|n| n.starts_with(char::is_whitespace))
            .map(|n| n.trim().to_string())
            .unwrap_or_default();
        v.push(Pkg {
            repo: repo.into(),
            name: name.into(),
            version,
            desc,
            installed,
        });
    }
    v
}

/// Package names that are safe to hand to a shell.
pub fn safe_pkg(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 100
        && !name.starts_with(['-', '.'])
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || "@._+-".contains(c))
}

pub struct Ctx<'a> {
    pub apps: &'a [App],
    pub windows: &'a [LWin],
    /// (workspace, app names) for the nine.
    pub spaces: &'a [(u8, Vec<String>)],
    pub history: &'a HashMap<String, u32>,
    pub cfg: &'a Value,
    pub files: &'a [String],
    pub packages: &'a [Pkg],
    pub explicit: &'a [String],
    pub has_claude: bool,
    /// Omarchy's root menus (id, label), for the launcher to open them.
    pub menus: &'a [(String, String)],
}

/// What the daemon must fetch before it can answer.
#[derive(Debug, Default, PartialEq)]
pub struct Plan {
    pub files: Option<String>,
    pub packages: Option<String>,
    pub explicit: bool,
}

pub fn plan(q: &Query, cfg: &Value) -> Plan {
    let mut p = Plan::default();
    let words = q.text.split_whitespace().count();
    let files_on = cfg["launcher"]["files"].as_bool().unwrap_or(true);
    let install_on = cfg["launcher"]["install"].as_bool().unwrap_or(true);
    if q.bang.is_none() && q.ask.is_none() {
        if files_on
            && ((q.mode == Mode::All && q.text.chars().count() >= 3 && words >= 1)
                || (q.mode == Mode::Files && !q.text.is_empty()))
        {
            p.files = Some(q.text.clone());
        }
        if install_on && q.mode == Mode::Install && q.text.chars().count() >= 2 {
            p.packages = Some(q.text.clone());
        }
        if install_on && q.mode == Mode::Remove {
            p.explicit = true;
        }
    }
    p
}

fn system_commands(ctx: &Ctx) -> Vec<(&'static str, &'static str, &'static str, Action)> {
    let run = |a: &[&str]| Action::Run {
        argv: a.iter().map(|s| s.to_string()).collect(),
        terminal: false,
    };
    let mut v = vec![
        (
            "sys:overview",
            "Show All Workspaces",
            "BaneySpaces",
            Action::Internal("overview"),
        ),
        (
            "sys:settings",
            "BaneySpaces Settings",
            "BaneySpaces",
            Action::Internal("settings"),
        ),
        (
            "sys:agent",
            "Show or Hide the Agent Workspace",
            "BaneySpaces",
            Action::Internal("agent"),
        ),
        (
            "sys:lock",
            "Lock Screen",
            "System",
            run(&["omarchy", "system", "lock"]),
        ),
        (
            "sys:screenshot",
            "Take a Screenshot",
            "System",
            run(&["omarchy", "capture", "screenshot"]),
        ),
        (
            "sys:theme",
            "Change Theme",
            "System",
            run(&["omarchy-menu", "toggle", "theme"]),
        ),
        (
            "sys:nightlight",
            "Toggle Night Light",
            "System",
            run(&["omarchy", "toggle", "nightlight"]),
        ),
        (
            "sys:menu",
            "Omarchy Menu",
            "System",
            run(&["omarchy-menu", "toggle"]),
        ),
        (
            "sys:shell",
            "Restart the Omarchy Shell",
            "System",
            run(&["omarchy", "restart", "shell"]),
        ),
        (
            "sys:terminal",
            "New Terminal",
            "Terminal",
            run(&["omarchy", "launch", "terminal"]),
        ),
    ];
    if ctx.has_claude {
        v.push((
            "sys:claude",
            "New Claude Session",
            "Terminal",
            Action::Run {
                argv: vec!["claude".into()],
                terminal: true,
            },
        ));
    }
    v
}

/// Answers a query. Sections come in the order the Mac shows them: what you're asking for first.
pub fn search(ctx: &Ctx, q: &Query) -> Vec<Hit> {
    let mut hits: Vec<Hit> = vec![];
    let bangs = all_bangs(&ctx.cfg["bangs"]);
    let find_bang = |t: &str| bangs.iter().find(|b| b.trigger == t).cloned();
    let fallback = find_bang("ddg").unwrap();

    // `!yt cats`: the bang first; one we don't know goes to DuckDuckGo, which knows thousands.
    if let Some((t, terms)) = &q.bang {
        let (bang, known) = match find_bang(t) {
            Some(b) => (b, true),
            None => (fallback.clone(), false),
        };
        let query = if known {
            terms.clone()
        } else {
            format!("!{t} {terms}")
        };
        let addr = bang.address(&query);
        hits.push(Hit {
            id: format!("bang:{t}"),
            section: "Web",
            title: if terms.is_empty() {
                format!("Open {}", bang.name)
            } else {
                format!("{} for “{terms}”", bang.name)
            },
            subtitle: if known {
                format!("!{t}")
            } else {
                format!("!{t} through DuckDuckGo")
            },
            icon: "web-browser".into(),
            score: 10_000,
            badge: None,
            action: addr.map(Action::Url).unwrap_or(Action::Nothing),
        });
        return hits;
    }
    if let Some(question) = &q.ask {
        let trig = ctx.cfg["launcher"]["agent"].as_str().unwrap_or("claude");
        let bang = find_bang(trig)
            .filter(|b| b.agent)
            .or_else(|| find_bang("claude"))
            .unwrap();
        hits.push(Hit {
            id: format!("ask:{}", bang.trigger),
            section: "Ask",
            title: if question.is_empty() {
                format!("Ask {}", bang.name)
            } else {
                format!("Ask {}: {question}", bang.name)
            },
            subtitle: "Opens a new chat in your browser".into(),
            icon: "dialog-question".into(),
            score: 10_000,
            badge: None,
            action: bang
                .address(question)
                .map(Action::Url)
                .unwrap_or(Action::Nothing),
        });
        return hits;
    }

    let text = q.text.as_str();
    let all = q.mode == Mode::All;
    let running = |app: &App| {
        ctx.windows
            .iter()
            .filter(|w| app_owns_class(app, &w.app))
            .collect::<Vec<_>>()
    };

    // Apps
    if all || q.mode == Mode::Apps {
        for app in ctx.apps {
            let wins = running(app);
            let uses = ctx
                .history
                .get(&format!("app:{}", app.id))
                .copied()
                .unwrap_or(0);
            let score = if text.is_empty() {
                if q.mode == Mode::Apps {
                    1 + uses
                } else {
                    0
                }
            } else {
                app_score(app, text, uses, !wins.is_empty())
            };
            if score == 0 {
                continue;
            }
            let subtitle = match wins.first() {
                Some(w) => format!(
                    "Open · workspace {}{}",
                    w.ws,
                    if wins.len() > 1 {
                        format!(" · {} windows", wins.len())
                    } else {
                        String::new()
                    }
                ),
                None if app.generic.is_empty() => app.comment.clone(),
                None => app.generic.clone(),
            };
            hits.push(Hit {
                id: format!("app:{}", app.id),
                section: "Apps",
                title: app.name.clone(),
                subtitle,
                icon: app.icon.clone(),
                score,
                badge: wins.iter().find_map(|w| w.badge.clone()),
                action: match wins.first() {
                    Some(w) => Action::Focus(w.addr.clone()),
                    None => Action::Launch(app.id.clone()),
                },
            });
        }
    }

    // Windows (terminals, browsers, agents): by title or app
    if (all && !text.is_empty()) || q.mode == Mode::Windows {
        for w in ctx.windows {
            let score = if text.is_empty() {
                1
            } else {
                name_score(text, &w.title).max(name_score(text, &w.app))
            };
            if score == 0 {
                continue;
            }
            let icon = ctx
                .apps
                .iter()
                .find(|a| app_owns_class(a, &w.app))
                .map(|a| a.icon.clone())
                .unwrap_or_else(|| w.app.to_lowercase());
            hits.push(Hit {
                id: format!("win:{}", w.addr),
                section: "Windows",
                title: if w.title.is_empty() {
                    w.app.clone()
                } else {
                    w.title.clone()
                },
                subtitle: format!("{} · workspace {}", w.app, w.ws),
                icon,
                score: score.saturating_sub(100),
                badge: w.badge.clone(),
                action: Action::Focus(w.addr.clone()),
            });
        }
    }

    // Workspaces
    if (all && !text.is_empty()) || q.mode == Mode::Workspaces {
        for (n, apps) in ctx.spaces {
            let label = format!("Workspace {n}");
            let listing = apps.join(", ");
            let score = if text.is_empty() {
                1
            } else if text.parse::<u8>().ok() == Some(*n) {
                950
            } else {
                name_score(text, &label).max(name_score(text, &listing) / 2)
            };
            if score == 0 || (apps.is_empty() && !text.is_empty() && text.parse::<u8>().is_err()) {
                continue;
            }
            hits.push(Hit {
                id: format!("ws:{n}"),
                section: "Workspaces",
                title: label,
                subtitle: if apps.is_empty() {
                    "Empty".into()
                } else {
                    listing
                },
                icon: "view-grid".into(),
                score: score.saturating_sub(150),
                badge: None,
                action: Action::Switch(*n),
            });
        }
    }

    // Calculator: `12*(3+4)` answers itself, and Return copies the answer.
    if all && !text.is_empty() {
        if let Some(v) = calc(text) {
            hits.push(Hit {
                id: "calc".into(), section: "Calculator", title: format!("= {v}"), subtitle: format!("{text}  ·  Return copies it"),
                icon: "accessories-calculator".into(), score: 5000, badge: None,
                action: Action::Run { argv: vec!["wl-copy".into(), "--".into(), v], terminal: false },
            });
        }
    }

    // Omarchy's own menus (Style, Setup, Learn, ...): one row each, so nothing the Omarchy menu offered is out of reach.
    if (all && !text.is_empty()) || q.mode == Mode::System {
        for (id, label) in ctx.menus.iter().filter(|(i, _)| i != "apps") {
            let title = format!("Omarchy: {label}");
            let score = if text.is_empty() { 1 } else { name_score(text, label).max(name_score(text, &title)) };
            if score == 0 { continue; }
            hits.push(Hit {
                id: format!("omenu:{id}"), section: "System", title, subtitle: "Omarchy menu".into(), icon: "preferences-system".into(),
                score: score.saturating_sub(130), badge: None,
                action: Action::Run { argv: vec!["omarchy-menu".into(), "toggle".into(), id.clone()], terminal: false },
            });
        }
    }

    // System and BaneySpaces commands
    if (all && !text.is_empty()) || q.mode == Mode::System {
        for (id, title, sub, action) in system_commands(ctx) {
            let score = if text.is_empty() {
                1
            } else {
                name_score(text, title).max(name_score(text, sub) / 3)
            };
            if score == 0 {
                continue;
            }
            hits.push(Hit {
                id: id.into(),
                section: "System",
                title: title.into(),
                subtitle: sub.into(),
                icon: "preferences-system".into(),
                score: score.saturating_sub(120),
                badge: None,
                action,
            });
        }
    }
    if q.mode == Mode::Update {
        hits.push(Hit {
            id: "sys:update".into(),
            section: "Update",
            title: "Update the System".into(),
            subtitle: "omarchy update, in a terminal".into(),
            icon: "system-software-update".into(),
            score: 1,
            badge: None,
            action: Action::Run {
                argv: vec!["omarchy".into(), "update".into()],
                terminal: true,
            },
        });
    }

    // Files
    if (all || q.mode == Mode::Files) && !text.is_empty() {
        let mut files: Vec<(u32, &String)> = ctx
            .files
            .iter()
            .filter_map(|p| {
                let base = p.trim_end_matches('/').rsplit('/').next().unwrap_or(p);
                words_start(text, base).then(|| {
                    (
                        name_score(text, base) + 1000u32.saturating_sub(p.len() as u32).min(400),
                        p,
                    )
                })
            })
            .collect();
        files.sort_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(b.1)));
        let limit = if all { 5 } else { 30 };
        for (score, p) in files.into_iter().take(limit) {
            let trimmed = p.trim_end_matches('/');
            let (dir, base) = trimmed.rsplit_once('/').unwrap_or(("", trimmed));
            let home = std::env::var("HOME").unwrap_or_default();
            let dir = if !home.is_empty() && dir.starts_with(&home) {
                dir.replacen(&home, "~", 1)
            } else {
                dir.to_string()
            };
            hits.push(Hit {
                id: format!("file:{p}"),
                section: "Files",
                title: base.to_string(),
                subtitle: dir,
                icon: if p.ends_with('/') {
                    "folder".into()
                } else {
                    "text-x-generic".into()
                },
                score: score.saturating_sub(300),
                badge: None,
                action: Action::OpenPath(p.clone()),
            });
        }
    }

    // Install and remove
    if q.mode == Mode::Install {
        for p in ctx.packages.iter().filter(|p| safe_pkg(&p.name)) {
            let score = name_score(text, &p.name).max(1) + if p.installed { 0 } else { 5 };
            hits.push(Hit {
                id: format!("pkg:{}", p.name),
                section: "Install",
                title: p.name.clone(),
                subtitle: format!(
                    "{} · {}{}",
                    p.repo,
                    p.desc,
                    if p.installed { " · installed" } else { "" }
                ),
                icon: "package-x-generic".into(),
                score,
                badge: None,
                action: if p.installed {
                    Action::Nothing
                } else {
                    Action::Pkg {
                        verb: "add",
                        name: p.name.clone(),
                    }
                },
            });
        }
    }
    if q.mode == Mode::Remove {
        for n in ctx.explicit.iter().filter(|n| safe_pkg(n)) {
            let score = if text.is_empty() {
                1
            } else {
                name_score(text, n)
            };
            if score == 0 {
                continue;
            }
            hits.push(Hit {
                id: format!("rm:{n}"),
                section: "Remove",
                title: n.clone(),
                subtitle: "Installed explicitly · asks before removing".into(),
                icon: "package-x-generic".into(),
                score,
                badge: None,
                action: Action::Pkg {
                    verb: "drop",
                    name: n.clone(),
                },
            });
        }
    }

    hits.sort_by(|a, b| {
        b.score
            .cmp(&a.score)
            .then(a.title.to_lowercase().cmp(&b.title.to_lowercase()))
    });
    // With nothing typed, the agents that finished or need you come first.
    if text.is_empty() && all {
        let mut first: Vec<Hit> = ctx
            .windows
            .iter()
            .filter(|w| matches!(w.badge.as_deref(), Some("finished" | "asking" | "error")))
            .map(|w| Hit {
                id: format!("win:{}", w.addr),
                section: "Agents",
                title: if w.title.is_empty() {
                    w.app.clone()
                } else {
                    w.title.clone()
                },
                subtitle: format!(
                    "{} · workspace {}",
                    w.badge.clone().unwrap_or_default(),
                    w.ws
                ),
                icon: w.app.to_lowercase(),
                score: 0,
                badge: w.badge.clone(),
                action: Action::Focus(w.addr.clone()),
            })
            .collect();
        let mut recent: Vec<Hit> = ctx
            .apps
            .iter()
            .filter_map(|a| ctx.history.get(&format!("app:{}", a.id)).map(|n| (n, a)))
            .map(|(n, a)| Hit {
                id: format!("app:{}", a.id),
                section: "Apps",
                title: a.name.clone(),
                subtitle: running(a)
                    .first()
                    .map(|w| format!("Open · workspace {}", w.ws))
                    .unwrap_or_else(|| a.generic.clone()),
                icon: a.icon.clone(),
                score: *n,
                badge: None,
                action: running(a)
                    .first()
                    .map(|w| Action::Focus(w.addr.clone()))
                    .unwrap_or(Action::Launch(a.id.clone())),
            })
            .collect();
        recent.sort_by(|a, b| b.score.cmp(&a.score).then(a.title.cmp(&b.title)));
        recent.truncate(8);
        first.append(&mut recent);
        hits = first;
    }

    // Plain text can always go to the web or to your agent.
    if all && !text.is_empty() {
        let engine = find_bang(
            ctx.cfg["launcher"]["search_engine"]
                .as_str()
                .unwrap_or("ddg"),
        )
        .filter(|b| !b.agent)
        .unwrap_or(fallback.clone());
        let agent = find_bang(ctx.cfg["launcher"]["agent"].as_str().unwrap_or("claude"))
            .filter(|b| b.agent)
            .unwrap_or_else(|| find_bang("claude").unwrap());
        let img = find_bang("i").unwrap();
        for (id, b, title) in [
            (
                format!("web:{}", engine.trigger),
                engine,
                "Search the web for",
            ),
            ("web:i".to_string(), img, "Search images for"),
            (format!("ask:{}", agent.trigger), agent, "Ask"),
        ] {
            let ask = title == "Ask";
            hits.push(Hit {
                id,
                section: if ask { "Ask" } else { "Web" },
                title: if ask {
                    format!("Ask {}: {text}", b.name)
                } else {
                    format!("{title} “{text}”")
                },
                subtitle: if ask {
                    "Opens a new chat in your browser".into()
                } else {
                    b.name.clone()
                },
                icon: if ask {
                    "dialog-question".into()
                } else {
                    "web-browser".into()
                },
                score: 0,
                badge: None,
                action: b.address(text).map(Action::Url).unwrap_or(Action::Nothing),
            });
        }
    }
    hits.truncate(60);
    hits
}

#[cfg(test)]
mod tests {
    use super::*;

    fn app(id: &str, name: &str, generic: &str, exec: &str) -> App {
        App {
            id: id.into(),
            name: name.into(),
            generic: generic.into(),
            comment: String::new(),
            keywords: vec![],
            exec: exec.into(),
            icon: id.into(),
            terminal: false,
            wm_class: String::new(),
        }
    }
    fn apps() -> Vec<App> {
        vec![
            app("firefox", "Firefox", "Web Browser", "firefox %u"),
            app(
                "org.gnome.Nautilus",
                "Files",
                "File Manager",
                "nautilus --new-window %U",
            ),
            app("foot", "Foot", "Terminal", "foot"),
            app("org.pwmt.zathura", "Zathura", "", "zathura %f"),
        ]
    }
    fn win(addr: &str, app: &str, title: &str, ws: u8) -> LWin {
        LWin {
            addr: addr.into(),
            app: app.into(),
            title: title.into(),
            ws,
            badge: None,
        }
    }
    fn run(q: &str, mode: Mode, wins: &[LWin]) -> Vec<Hit> {
        run_with(q, mode, wins, &[], &[], &[])
    }
    fn run_with(
        q: &str,
        mode: Mode,
        wins: &[LWin],
        files: &[String],
        pkgs: &[Pkg],
        explicit: &[String],
    ) -> Vec<Hit> {
        let a = apps();
        let cfg = json!({ "launcher": { "files": true, "install": true, "search_engine": "ddg", "agent": "claude" }, "bangs": [] });
        let h = HashMap::new();
        let spaces = vec![
            (1u8, vec!["foot".to_string()]),
            (2, vec![]),
            (3, vec!["firefox".to_string()]),
        ];
        let ctx = Ctx {
            apps: &a,
            windows: wins,
            spaces: &spaces,
            history: &h,
            cfg: &cfg,
            files,
            packages: pkgs,
            explicit,
            has_claude: true,
            menus: &[],
        };
        search(&ctx, &parse_query(q, mode))
    }

    #[test]
    fn exec_lines_lose_their_field_codes_and_keep_quoting() {
        assert_eq!(exec_argv("firefox %u"), ["firefox"]);
        assert_eq!(
            exec_argv("nautilus --new-window %U"),
            ["nautilus", "--new-window"]
        );
        assert_eq!(
            exec_argv("env FOO=1 \"/opt/My App/run\" --x=\"a b\" %F"),
            ["env", "FOO=1", "/opt/My App/run", "--x=a b"]
        );
        assert_eq!(exec_argv("sh -c \"echo 100%%\""), ["sh", "-c", "echo 100%"]);
    }

    #[test]
    fn desktop_entries_parse_and_hidden_ones_do_not() {
        let t = "[Desktop Entry]\nType=Application\nName=Firefox\nName[de]=Feuerfuchs\nGenericName=Web Browser\nKeywords=internet;www;\nExec=firefox %u\nIcon=firefox\nStartupWMClass=firefox\n[Desktop Action new]\nName=New Window\nExec=firefox --new-window\n";
        let a = parse_desktop("firefox", t).unwrap();
        assert_eq!(
            (a.name.as_str(), a.icon.as_str(), a.wm_class.as_str()),
            ("Firefox", "firefox", "firefox")
        );
        assert_eq!(a.keywords, ["internet", "www"]);
        assert!(parse_desktop("x", "[Desktop Entry]\nName=X\nExec=x\nNoDisplay=true\n").is_none());
        assert!(parse_desktop("x", "[Desktop Entry]\nName=X\nExec=x\nHidden=true\n").is_none());
        assert!(parse_desktop("x", "[Desktop Entry]\nType=Link\nName=X\nExec=x\n").is_none());
    }

    #[test]
    fn scanning_lets_your_entry_override_the_systems() {
        let d = std::env::temp_dir().join(format!("bs-apps-{}", std::process::id()));
        let (user, sys) = (d.join("user"), d.join("sys"));
        std::fs::create_dir_all(&user).unwrap();
        std::fs::create_dir_all(sys.join("sub")).unwrap();
        std::fs::write(
            user.join("a.desktop"),
            "[Desktop Entry]\nName=Mine\nExec=a\n",
        )
        .unwrap();
        std::fs::write(
            sys.join("a.desktop"),
            "[Desktop Entry]\nName=Theirs\nExec=a\n",
        )
        .unwrap();
        std::fs::write(
            sys.join("sub/b.desktop"),
            "[Desktop Entry]\nName=B\nExec=b\n",
        )
        .unwrap();
        let apps = scan_apps(&[user, sys]);
        assert_eq!(
            apps.iter().map(|a| a.name.as_str()).collect::<Vec<_>>(),
            ["B", "Mine"]
        );
        assert_eq!(apps[0].id, "sub-b");
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    fn an_app_owns_its_windows_by_class_or_id_or_exec() {
        let a = apps();
        assert!(app_owns_class(&a[0], "firefox"));
        assert!(app_owns_class(&a[0], "Firefox"));
        assert!(app_owns_class(&a[1], "nautilus"));
        assert!(app_owns_class(&a[3], "zathura"));
        assert!(!app_owns_class(&a[2], ""));
        assert!(!app_owns_class(&a[2], "firefox"));
    }

    #[test]
    fn words_start_words_like_the_mac() {
        assert!(words_start("tax 2025", "2025 Tax Return.pdf"));
        assert!(words_start("ret tax", "2025 Tax Return.pdf"));
        assert!(words_start("my doc", "my_documentFile.txt"));
        assert!(words_start("file", "my_documentFile.txt"), "camelCase hump");
        assert!(!words_start("ax", "2025 Tax Return.pdf"), "mid-word");
        assert!(!words_start("", "x"));
    }

    #[test]
    fn scores_rank_exact_over_prefix_over_word_over_substring_over_fuzzy() {
        let s = |q, n| name_score(q, n);
        assert!(s("foot", "Foot") > s("foo", "Foot"));
        assert!(s("foo", "Foot") > s("term", "Alacritty Terminal"));
        assert!(s("term", "Alacritty Terminal") > s("ritty", "Alacritty"));
        assert!(s("ritty", "Alacritty") > s("ffx", "Firefox"));
        assert!(s("ffx", "Firefox") > 0);
        assert_eq!(s("zzz", "Firefox"), 0);
        assert_eq!(s("fire", "LibreOffice Impress"), 0, "mid-word letters are not a match");
        assert_eq!(s("ffe", "LibreOffice Impress"), 0, "a fuzzy match must start at a word");
    }

    #[test]
    fn typing_finds_apps_and_a_running_app_takes_you_to_its_workspace() {
        let h = run("fire", Mode::All, &[]);
        assert_eq!(h[0].title, "Firefox");
        assert_eq!(h[0].action, Action::Launch("firefox".into()));
        let h = run("fire", Mode::All, &[win("0x1", "firefox", "Docs", 3)]);
        assert_eq!(h[0].action, Action::Focus("0x1".into()));
        assert!(h[0].subtitle.contains("workspace 3"), "{}", h[0].subtitle);
    }

    #[test]
    fn generic_names_and_keywords_find_apps() {
        assert_eq!(run("browser", Mode::All, &[])[0].title, "Firefox");
        assert_eq!(run("file man", Mode::All, &[])[0].title, "Files");
    }

    #[test]
    fn windows_match_by_title_and_workspaces_by_number() {
        let w = [win("0x2", "foot", "claude — baneyspaces", 1)];
        let h = run("baneyspaces", Mode::All, &w);
        assert!(h
            .iter()
            .any(|x| x.section == "Windows" && x.action == Action::Focus("0x2".into())));
        let h = run("3", Mode::All, &[]);
        assert_eq!(h[0].action, Action::Switch(3));
    }

    #[test]
    fn bangs_go_to_their_site_and_unknown_ones_to_duckduckgo() {
        let h = run("!yt lofi & chill", Mode::All, &[]);
        assert_eq!(h.len(), 1);
        assert_eq!(
            h[0].action,
            Action::Url("https://www.youtube.com/results?search_query=lofi%20%26%20chill".into())
        );
        let h = run("cats !w", Mode::All, &[]);
        assert_eq!(
            h[0].action,
            Action::Url("https://en.wikipedia.org/wiki/Special:Search?search=cats".into())
        );
        let h = run("!gamefaqs zelda", Mode::All, &[]);
        assert_eq!(
            h[0].action,
            Action::Url("https://duckduckgo.com/?q=%21gamefaqs%20zelda".into())
        );
        let h = run("!yt", Mode::All, &[]);
        assert_eq!(
            h[0].action,
            Action::Url("https://www.youtube.com/".into()),
            "no words: the site itself"
        );
    }

    #[test]
    fn a_leading_question_mark_asks_your_agent() {
        let h = run("?why is the sky blue", Mode::All, &[]);
        assert_eq!(h.len(), 1);
        assert_eq!(
            h[0].action,
            Action::Url("https://claude.ai/new?q=why%20is%20the%20sky%20blue".into())
        );
    }

    #[test]
    fn plain_text_can_always_go_to_the_web_images_or_your_agent() {
        let h = run("zzqx", Mode::All, &[]);
        let ids: Vec<&str> = h.iter().map(|x| x.id.as_str()).collect();
        assert_eq!(ids, ["web:ddg", "web:i", "ask:claude"]);
    }

    #[test]
    fn a_bang_can_only_open_web_addresses() {
        let evil = Bang {
            trigger: "x".into(),
            name: "x".into(),
            url: "file:///etc/passwd?{q}".into(),
            home: None,
            agent: false,
        };
        assert_eq!(evil.address("a"), None);
        let js = Bang {
            trigger: "x".into(),
            name: "x".into(),
            url: "javascript:{q}".into(),
            home: None,
            agent: false,
        };
        assert_eq!(js.address(""), None);
        assert_eq!(url_encode("a b/c?d=e&f#g"), "a%20b%2Fc%3Fd%3De%26f%23g");
    }

    #[test]
    fn your_own_bang_replaces_a_built_in() {
        let all = all_bangs(
            &json!([{ "trigger": "g", "name": "Mine", "url": "https://example.com/?q={q}" }]),
        );
        assert_eq!(all.iter().filter(|b| b.trigger == "g").count(), 1);
        assert_eq!(all.iter().find(|b| b.trigger == "g").unwrap().name, "Mine");
        assert_eq!(all[0].trigger, "g");
    }

    #[test]
    fn files_must_start_every_word_and_are_capped_at_five() {
        let files: Vec<String> = (0..9)
            .map(|i| format!("/home/u/Docs/2025 Tax Return {i}.pdf"))
            .chain(["/home/u/notes/ax.txt".to_string()])
            .collect();
        let h = run_with("tax 2025", Mode::All, &[], &files, &[], &[]);
        assert_eq!(h.iter().filter(|x| x.section == "Files").count(), 5);
        let h = run_with("ax", Mode::Files, &[], &files, &[], &[]);
        assert!(h.iter().any(|x| x.title == "ax.txt"));
        assert!(
            !h.iter().any(|x| x.title.contains("Tax")),
            "mid-word does not match"
        );
        let p = plan(
            &parse_query("tax 2025", Mode::All),
            &json!({ "launcher": { "files": true } }),
        );
        assert_eq!(p.files.as_deref(), Some("tax 2025"));
        assert_eq!(
            plan(
                &parse_query("ta", Mode::All),
                &json!({ "launcher": { "files": true } })
            )
            .files,
            None,
            "too short"
        );
        assert_eq!(
            plan(
                &parse_query("tax", Mode::All),
                &json!({ "launcher": { "files": false } })
            )
            .files,
            None
        );
    }

    #[test]
    fn pacman_output_parses_and_install_asks_first() {
        let out = "extra/firefox 131.0-1 [installed]\n    Fast, Private & Safe Web Browser\nextra/firefox-i18n-de 131.0-1\n    German language pack for Firefox\nchaotic-aur/weird 1-1 (group)\n    x\n";
        let pk = parse_pacman_ss(out);
        assert_eq!(pk.len(), 3);
        assert!(pk[0].installed && !pk[1].installed);
        assert_eq!(pk[1].desc, "German language pack for Firefox");
        let h = run_with("firefox", Mode::Install, &[], &[], &pk, &[]);
        assert!(h.iter().all(|x| x.section == "Install"));
        let de = h.iter().find(|x| x.title == "firefox-i18n-de").unwrap();
        assert_eq!(
            de.action,
            Action::Pkg {
                verb: "add",
                name: "firefox-i18n-de".into()
            }
        );
        assert!(de.action.needs_confirm());
        let ff = h.iter().find(|x| x.title == "firefox").unwrap();
        assert_eq!(ff.action, Action::Nothing, "already installed");
    }

    #[test]
    fn install_words_switch_menus_and_package_names_are_checked() {
        let q = parse_query("install firefox", Mode::All);
        assert_eq!((q.mode, q.text.as_str()), (Mode::Install, "firefox"));
        assert_eq!(parse_query("remove foo", Mode::All).mode, Mode::Remove);
        assert!(safe_pkg("lib32-gcc-libs") && safe_pkg("python-pyqt6+x"));
        assert!(
            !safe_pkg("a; rm -rf ~")
                && !safe_pkg("-Syu")
                && !safe_pkg("a b")
                && !safe_pkg("$(x)")
                && !safe_pkg("")
        );
        let pk = vec![Pkg {
            repo: "x".into(),
            name: "evil;touch x".into(),
            version: "1".into(),
            desc: String::new(),
            installed: false,
        }];
        assert!(
            run_with("evil", Mode::Install, &[], &[], &pk, &[]).is_empty(),
            "an unsafe name is never offered"
        );
        let h = run_with(
            "fire",
            Mode::Remove,
            &[],
            &[],
            &[],
            &["firefox".to_string(), "foot".to_string()],
        );
        assert_eq!(h.len(), 1);
        assert_eq!(
            h[0].action,
            Action::Pkg {
                verb: "drop",
                name: "firefox".into()
            }
        );
    }

    #[test]
    fn with_nothing_typed_agents_that_need_you_come_first() {
        let mut w = win("0x9", "foot", "claude", 4);
        w.badge = Some("finished".into());
        let h = run("", Mode::All, &[win("0x1", "foot", "sh", 1), w]);
        assert_eq!(h[0].section, "Agents");
        assert_eq!(h[0].action, Action::Focus("0x9".into()));
    }

    #[test]
    fn acronyms_find_apps_and_hidden_helpers_stay_hidden() {
        let w = app("libreoffice-writer", "LibreOffice Writer", "Word Processor", "libreoffice --writer");
        assert!(app_score(&w, "lw", 0, false) > 0, "lw for LibreOffice Writer");
        assert!(app_score(&w, "xz", 0, false) == 0);
        let d = std::env::temp_dir().join(format!("bs-hides-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(d.join("bssh.desktop"), "[Desktop Entry]\nName=SSH Server Browser\nExec=bssh\n").unwrap();
        std::fs::write(d.join("kept.desktop"), "[Desktop Entry]\nName=Kept\nExec=kept\n").unwrap();
        let hidden = hidden_ids();
        let apps = scan_apps(&[d.clone()]);
        let base = std::env::var("OMARCHY_PATH").unwrap_or_else(|_| "/usr/share/omarchy".into());
        if std::path::Path::new(&format!("{base}/default/omarchy/launcher.hides")).exists() {
            assert!(hidden.contains("bssh") && !apps.iter().any(|a| a.id == "bssh"), "Omarchy hides bssh");
        }
        assert!(apps.iter().any(|a| a.id == "kept"));
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    fn the_calculator_answers_arithmetic_and_nothing_else() {
        assert_eq!(calc("2+3*4").as_deref(), Some("14"));
        assert_eq!(calc("(1.5+2)^2").as_deref(), Some("12.25"));
        assert_eq!(calc("10 % 3").as_deref(), Some("1"));
        assert_eq!(calc("-4/8").as_deref(), Some("-0.5"));
        assert_eq!(calc("1,000*3").as_deref(), Some("3000"));
        assert_eq!(calc("2^3^2").as_deref(), Some("512"));
        for bad in ["", "42", "firefox", "2+", "(2+3", "1/0", "2+3; rm", "$(x)+1", "1e3+1", "+"] {
            assert_eq!(calc(bad), None, "{bad:?}");
        }
        let h = run("12*(3+4)", Mode::All, &[]);
        assert_eq!(h[0].title, "= 84");
        assert_eq!(h[0].action, Action::Run { argv: vec!["wl-copy".into(), "--".into(), "84".into()], terminal: false });
        let neg = run("-4/8", Mode::All, &[]);
        assert_eq!(neg[0].action, Action::Run { argv: vec!["wl-copy".into(), "--".into(), "-0.5".into()], terminal: false }, "a negative answer is not an option of wl-copy");
    }

    #[test]
    fn omarchy_menus_are_read_from_its_definition() {
        let base = std::env::var("OMARCHY_PATH").unwrap_or_else(|_| "/usr/share/omarchy".into());
        if !std::path::Path::new(&format!("{base}/default/omarchy/omarchy-menu.jsonc")).exists() {
            return;
        }
        let m = omarchy_menus();
        let ids: Vec<&str> = m.iter().map(|(i, _)| i.as_str()).collect();
        for want in ["apps", "learn", "style", "setup", "install", "remove", "update"] {
            assert!(ids.contains(&want), "{want} in {ids:?}");
        }
        assert!(m.iter().all(|(i, _)| !i.contains('.')));
    }

    #[test]
    fn menus_list_their_own_kind() {
        assert!(run("", Mode::System, &[])
            .iter()
            .all(|h| h.section == "System" || h.subtitle == "BaneySpaces"));
        assert!(run("", Mode::System, &[])
            .iter()
            .any(|h| h.title == "Lock Screen"));
        let ws = run("", Mode::Workspaces, &[]);
        assert_eq!(ws.len(), 3);
        assert_eq!(run("", Mode::Update, &[])[0].id, "sys:update");
        assert_eq!(run("", Mode::Apps, &[]).len(), 4);
    }
}
