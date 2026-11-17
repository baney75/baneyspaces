//! `baneyspaces theme preview`: one self-contained HTML page that shows a theme on product-shaped
//! UI. It has no external requests. Every color, radius, font and duration comes from the same
//! `--pc-*` variables the exports use; the page never writes a color of its own.

/// The first line of every preview page. A file that does not start with it is not ours, and
/// `preview --out` will not replace it.
pub(super) const MARKER: &str = "<!-- polycarp-theme-preview -->";

use super::{color_lines, shared_vars, Full, Resolved};

fn esc(s: &str) -> String {
    s.chars()
        .map(|c| match c {
            '&' => "&amp;".to_string(),
            '<' => "&lt;".to_string(),
            '>' => "&gt;".to_string(),
            '"' => "&quot;".to_string(),
            c => c.to_string(),
        })
        .collect()
}

/// The page, for the given modes ("light", "dark", or both for a side-by-side view).
pub(super) fn render(full: &Full, surface: Option<&str>, modes: &[&str]) -> String {
    let r = match surface {
        Some(s) => full.surface(s),
        None => &full.base,
    }
    .exported();
    let first = modes.first().copied().unwrap_or("light");

    let mut vars = String::new();
    for (k, v) in shared_vars(&r) {
        vars.push_str(&format!("  --pc-{k}: {v};\n"));
    }
    vars.push_str(&color_lines(&r, first, "  "));

    let mut mode_css = String::new();
    for m in modes {
        mode_css.push_str(&format!(
            ".pc-{m} {{\n  color-scheme: {m};\n{}}}\n",
            color_lines(&r, m, "  ")
        ));
    }

    let scope = surface.map_or("no product overrides".to_string(), |s| {
        format!("product: {s}")
    });
    let mut body = String::new();
    for m in modes {
        body.push_str(&pane(&r, m));
    }
    let title = format!("{} ({})", esc(&full.title), esc(&full.name));
    format!(
        "{MARKER}\n<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n\
         <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n\
         <title>Polycarp theme preview: {title}</title>\n<style>\n:root {{\n{vars}}}\n{mode_css}{CSS}{indicator}</style>\n</head>\n\
         <body>\n<header class=\"top\"><h1>{title}</h1><p>{} &middot; {}</p></header>\n\
         <main class=\"panes{}\">\n{body}</main>\n</body>\n</html>\n",
        esc(full.description.as_deref().unwrap_or("")),
        esc(&scope),
        if modes.len() > 1 { " two" } else { "" },
        indicator = indicator_css(&r.shape.indicator),
    )
}

/// How the dock marks a workspace's status, for the theme's `indicator`.
fn indicator_css(kind: &str) -> &'static str {
    match kind {
        "bar" => {
            ".tile .ind { position: absolute; left: 0; right: 0; bottom: 0; height: 3px; background: var(--pc-status); border-radius: 0 0 var(--pc-radius) var(--pc-radius); }\n"
        }
        "number-block" => {
            ".tile .ind { display: none; }\n.tile .num { background: var(--pc-status); color: var(--pc-background); border-radius: var(--pc-radius-small); padding: 0 6px; }\n.tile.st-idle .num { background: var(--pc-sunken); color: var(--pc-muted); }\n.tile.on .num { background: var(--pc-accent); color: var(--pc-on-accent); }\n"
        }
        _ => {
            ".tile .ind { position: absolute; top: 8px; right: 8px; width: 8px; height: 8px; border-radius: 50%; background: var(--pc-status); }\n"
        }
    }
}

const TILES: [(&str, &str); 9] = [
    ("Mail", "idle"),
    ("Code", "on"),
    ("Notes", "working"),
    ("Browser", "idle"),
    ("Chat", "urgent"),
    ("Music", "idle"),
    ("Files", "done"),
    ("Terminal", "working"),
    ("Agent", "idle"),
];

fn pane(r: &Resolved, mode: &str) -> String {
    let mut tiles = String::new();
    for (i, (name, st)) in TILES.iter().enumerate() {
        let class = if *st == "on" {
            "on st-idle".to_string()
        } else {
            format!("st-{st}")
        };
        tiles.push_str(&format!(
            "<div class=\"tile {class}\"><span class=\"num\">{}</span><span class=\"lbl\">{name}</span><i class=\"ind\"></i></div>\n",
            i + 1
        ));
    }
    let bars: String = (0..16)
        .map(|i| format!("<i style=\"animation-delay:{}ms\"></i>", i * 70))
        .collect();
    format!(
        r##"<section class="pane pc-{mode}" data-density="{density}">
<div class="label">{mode} mode</div>

<div class="card">
  <h2>Workspaces</h2>
  <div class="dock">
{tiles}  </div>
  <p class="hint">Indicator style: {indicator}. Code is selected, Notes and Terminal are working, Chat needs you, Files finished.</p>
</div>

<div class="stage">
  <div class="overlay">
    <div class="mic"><span></span></div>
    <div class="say">
      <div class="status working"><i class="pulse"></i> Listening</div>
      <p>Remind me to send the draft to Ruth <span class="soft">before Fri</span></p>
      <div class="wave">{bars}</div>
    </div>
    <div class="keys"><kbd>Esc</kbd> cancel<br><kbd>Fn</kbd> finish</div>
  </div>
</div>

<div class="split">
  <div class="card side">
    <div class="side-head"><b>Quarterly report</b><span class="x">&times;</span></div>
    <div class="turn me">Summarize this page and send it to Ruth.</div>
    <div class="turn ai">I read the page. It has <code>3</code> tables and one open question about the budget.
      <div class="status working"><i class="pulse"></i> Working: drafting the email</div></div>
    <div class="ask">
      <div class="status urgent">Needs you</div>
      <p>Tabkyra wants to click <b>Send</b> on the mail page.</p>
      <div class="row"><button class="btn secondary">Not now</button><button class="btn primary">Allow once</button></div>
    </div>
    <div class="field"><span>Ask about this page</span></div>
  </div>

  <div class="card form">
    <h2>Dictation</h2>
    <label class="f"><span>Language</span><div class="select">English (US)<i>&#9662;</i></div></label>
    <label class="f"><span>Shortcut</span><div class="input focus"><kbd>Fn</kbd> <kbd>Space</kbd></div></label>
    <div class="f"><span>Insert text automatically</span><div class="switch on"><i></i></div></div>
    <div class="f"><span>Keep audio</span><div class="switch"><i></i></div></div>
    <div class="f"><span>Microphone level</span><div class="slider"><div></div></div></div>
    <div class="seg"><span>Auto</span><span class="on">Light</span><span>Dark</span></div>
    <ul class="list"><li>Built-in microphone</li><li class="on">Studio USB microphone</li><li>Headset</li></ul>
    <p class="hint">Words you add here are spelled the way you typed them.</p>
  </div>
</div>

<div class="split">
  <div class="card">
    <h2>Buttons and status</h2>
    <div class="row"><button class="btn primary">Save</button><button class="btn secondary">Cancel</button><button class="btn disabled" aria-disabled="true">Disabled</button></div>
    <p class="status urgent">&#9650; Needs you: approve the purchase</p>
    <p class="status working">&#9679; Working: indexing 12 files</p>
    <p class="status done">&#10003; Done: 3 notes saved</p>
  </div>
  <div class="card dialog">
    <h2>Delete the theme &ldquo;mine&rdquo;?</h2>
    <p class="hint">Its file is removed. You can still undo this from history.</p>
    <div class="row"><button class="btn secondary">Cancel</button><button class="btn danger">Delete</button></div>
  </div>
</div>

<pre class="code"><span class="n">1</span><span class="c"># themes/mine.toml</span>
<span class="n">2</span><span class="k">extends</span> = <span class="s">"polycarp"</span>
<span class="n">3</span><span class="k">[light]</span>
<span class="n">4</span><span class="k">accent</span> = <span class="s">"#a4502a"</span>   <span class="c"># 4.96 on background</span>
<span class="n">5</span><span class="k">[shape]</span>
<span class="n">6</span><span class="k">radius</span> = <span class="w">0</span>
<span class="n">7</span><span class="e">dark.muted on dark.surface is 3.04, needs 4.5</span></pre>
</section>
"##,
        density = esc(&r.shape.density),
        indicator = esc(&r.shape.indicator),
    )
}

const CSS: &str = r##"
* { box-sizing: border-box; }
body { margin: 0; padding: 28px; background: var(--pc-sunken); color: var(--pc-foreground);
  font: var(--pc-font-weight) var(--pc-font-size)/var(--pc-line-height) var(--pc-font-ui); }
.top h1 { margin: 0 0 4px; font: 700 28px/1.2 var(--pc-font-display); color: var(--pc-strong); }
.top p { margin: 0 0 20px; color: var(--pc-muted); }
.panes { display: grid; gap: 24px; grid-template-columns: minmax(0, 1fr); max-width: 980px; margin: 0 auto; }
.panes.two { grid-template-columns: repeat(auto-fit, minmax(560px, 1fr)); max-width: none; }
.pane[data-density="compact"] { --pc-space-1: 4px; --pc-space-2: 8px; --pc-space-3: 12px; }
.pane[data-density="regular"] { --pc-space-1: 6px; --pc-space-2: 12px; --pc-space-3: 18px; }
.pane[data-density="spacious"] { --pc-space-1: 9px; --pc-space-2: 16px; --pc-space-3: 26px; }
.pane { background: var(--pc-background); color: var(--pc-foreground); display: grid; gap: var(--pc-space-3);
  padding: var(--pc-space-3); border: var(--pc-border-width) solid var(--pc-border);
  border-radius: var(--pc-radius-large); position: relative; align-content: start; }
.label { font: 600 12px/1 var(--pc-font-mono); letter-spacing: .08em; text-transform: uppercase; color: var(--pc-muted); }
h2 { margin: 0 0 var(--pc-space-2); font: 700 1.1em/1.3 var(--pc-font-display); color: var(--pc-strong); }
p { margin: var(--pc-space-1) 0; }
.hint { color: var(--pc-muted); font-size: .875em; }
.card { background: var(--pc-surface); border: var(--pc-border-width) solid var(--pc-border);
  border-radius: var(--pc-radius-large); padding: var(--pc-space-3);
  box-shadow: 0 1px 2px rgba(0,0,0,var(--pc-shadow)); }
.split { display: grid; gap: var(--pc-space-3); grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); }

.dock { container-type: inline-size; display: grid; grid-template-columns: repeat(9, minmax(0, 1fr)); gap: var(--pc-space-1); }
.tile { position: relative; background: var(--pc-sunken); color: var(--pc-muted); border: var(--pc-border-width) solid var(--pc-border);
  border-radius: var(--pc-radius); padding: var(--pc-space-2) 2px; text-align: center; min-width: 0;
  display: grid; gap: 2px; transition: background var(--pc-motion-fast) var(--pc-motion-easing); }
.tile .num { font: 600 .9em/1.4 var(--pc-font-mono); color: var(--pc-strong); justify-self: center; }
.tile .lbl { font-size: clamp(6.5px, 1.5cqw, 11px); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.tile.on { background: var(--pc-selection); border-color: var(--pc-accent); color: var(--pc-strong); }
.tile.st-idle { --pc-status: var(--pc-border); }
.tile.st-working { --pc-status: var(--pc-working); }
.tile.st-urgent { --pc-status: var(--pc-urgent); }
.tile.st-done { --pc-status: var(--pc-done); }

.stage { border-radius: var(--pc-radius-large); padding: var(--pc-space-3);
  background: linear-gradient(120deg, var(--pc-selection), var(--pc-sunken) 55%, var(--pc-accent)); }
.overlay { display: flex; gap: var(--pc-space-2); align-items: center; max-width: 520px; margin: 0 auto;
  background: var(--pc-surface); border: var(--pc-border-width) solid var(--pc-border);
  border-radius: var(--pc-radius-large); padding: var(--pc-space-2) var(--pc-space-3);
  box-shadow: 0 10px 30px rgba(0,0,0,var(--pc-shadow)); backdrop-filter: blur(var(--pc-blur)); -webkit-backdrop-filter: blur(var(--pc-blur)); }
.mic { width: 38px; height: 38px; border-radius: 50%; background: var(--pc-accent); display: grid; place-items: center; flex: none; }
.mic span { width: 10px; height: 18px; border-radius: 6px; background: var(--pc-on-accent); }
.say { flex: 1; min-width: 0; }
.say p { margin: 2px 0 6px; color: var(--pc-strong); }
.soft { color: var(--pc-muted); }
.wave { display: flex; gap: 3px; align-items: center; height: 18px; }
.wave i { width: 3px; height: 100%; border-radius: 2px; background: var(--pc-accent); transform-origin: center;
  animation: bar var(--pc-motion-slow) var(--pc-motion-easing) infinite alternate; }
@keyframes bar { from { transform: scaleY(.25); } to { transform: scaleY(1); } }
.keys { font-size: .75em; color: var(--pc-muted); text-align: right; line-height: 2; }
kbd { font: 600 .9em/1 var(--pc-font-mono); background: var(--pc-sunken); color: var(--pc-strong);
  border: var(--pc-border-width) solid var(--pc-border); border-radius: var(--pc-radius-small); padding: 2px 6px; }

.status { font-weight: 600; margin: var(--pc-space-1) 0; }
.status.urgent { color: var(--pc-urgent); }
.status.working { color: var(--pc-working); }
.status.done { color: var(--pc-done); }
.pulse { display: inline-block; width: 8px; height: 8px; border-radius: 50%; background: var(--pc-working);
  margin-right: 4px; animation: pulse var(--pc-motion-slow) var(--pc-motion-easing) infinite alternate; }
@keyframes pulse { from { opacity: .35; } to { opacity: 1; } }

.side { display: grid; gap: var(--pc-space-2); align-content: start; }
.side-head { display: flex; justify-content: space-between; color: var(--pc-strong); }
.x { color: var(--pc-muted); }
.turn { padding: var(--pc-space-2); border-radius: var(--pc-radius); max-width: 92%; }
.turn.me { background: var(--pc-accent); color: var(--pc-on-accent); justify-self: end; }
.turn.ai { background: var(--pc-background); border: var(--pc-border-width) solid var(--pc-border); }
code { font: .9em var(--pc-font-mono); background: var(--pc-sunken); color: var(--pc-strong); padding: 1px 5px; border-radius: var(--pc-radius-small); }
.ask { border: var(--pc-border-width) solid var(--pc-urgent); border-radius: var(--pc-radius); padding: var(--pc-space-2); background: var(--pc-background); }
.row { display: flex; gap: var(--pc-space-2); flex-wrap: wrap; margin-top: var(--pc-space-2); }
.field, .input, .select { background: var(--pc-sunken); border: var(--pc-border-width) solid var(--pc-border);
  border-radius: var(--pc-radius); padding: var(--pc-space-1) var(--pc-space-2); color: var(--pc-muted); }
.field span { color: var(--pc-muted); }

.btn { font: 600 1em var(--pc-font-ui); padding: var(--pc-space-1) var(--pc-space-3); border-radius: var(--pc-radius);
  border: var(--pc-border-width) solid var(--pc-border); cursor: pointer;
  transition: background var(--pc-motion-normal) var(--pc-motion-easing), transform var(--pc-motion-fast) var(--pc-motion-easing); }
.btn:active { transform: scale(var(--pc-motion-scale-from)); }
.btn.primary { background: var(--pc-accent); color: var(--pc-on-accent); border-color: var(--pc-accent); }
.btn.secondary { background: var(--pc-surface); color: var(--pc-strong); }
.btn.disabled { background: var(--pc-sunken); color: var(--pc-muted); border-style: dashed; cursor: not-allowed; }
.btn.danger { background: var(--pc-urgent); color: var(--pc-background); border-color: var(--pc-urgent); }
.dialog { box-shadow: 0 14px 40px rgba(0,0,0,var(--pc-shadow)); border-color: var(--pc-urgent); }

.form { display: grid; gap: var(--pc-space-2); align-content: start; }
.f { display: flex; justify-content: space-between; align-items: center; gap: var(--pc-space-2); }
.f > span { color: var(--pc-foreground); }
.select i { font-style: normal; margin-left: 10px; color: var(--pc-muted); }
.input.focus { outline: 2px solid var(--pc-accent); outline-offset: 1px; color: var(--pc-strong); }
.switch { width: 38px; height: 22px; border-radius: 11px; background: var(--pc-sunken); border: var(--pc-border-width) solid var(--pc-border); position: relative; flex: none; }
.switch i { position: absolute; top: 2px; left: 2px; width: 16px; height: 16px; border-radius: 50%; background: var(--pc-muted);
  transition: left var(--pc-motion-normal) var(--pc-motion-easing); }
.switch.on { background: var(--pc-accent); border-color: var(--pc-accent); }
.switch.on i { left: 18px; background: var(--pc-on-accent); }
.slider { width: 130px; height: 6px; border-radius: 3px; background: var(--pc-sunken); border: var(--pc-border-width) solid var(--pc-border); }
.slider div { width: 62%; height: 100%; border-radius: 3px; background: var(--pc-accent); }
.seg { display: flex; border: var(--pc-border-width) solid var(--pc-border); border-radius: var(--pc-radius); overflow: hidden; }
.seg span { flex: 1; text-align: center; padding: var(--pc-space-1); color: var(--pc-muted); background: var(--pc-sunken); }
.seg span.on { background: var(--pc-selection); color: var(--pc-strong); font-weight: 600; }
.list { list-style: none; margin: 0; padding: 0; border: var(--pc-border-width) solid var(--pc-border); border-radius: var(--pc-radius); overflow: hidden; }
.list li { padding: var(--pc-space-1) var(--pc-space-2); border-bottom: var(--pc-border-width) solid var(--pc-border); }
.list li:last-child { border-bottom: 0; }
.list li.on { background: var(--pc-selection); color: var(--pc-strong); }

.code { margin: 0; background: var(--pc-sunken); border: var(--pc-border-width) solid var(--pc-border);
  border-radius: var(--pc-radius); padding: var(--pc-space-2) var(--pc-space-3); font: .875em/1.6 var(--pc-font-mono);
  color: var(--pc-foreground); overflow: auto; }
.code .n { color: var(--pc-muted); display: inline-block; width: 2em; user-select: none; }
/* Text on sunken only uses foreground, strong and muted: those are checked at 4.5 there. */
.code .c { color: var(--pc-muted); }
.code .k { color: var(--pc-strong); font-weight: 700; }
.code .s { color: var(--pc-foreground); }
.code .w { color: var(--pc-foreground); }
.code .e { color: var(--pc-strong); font-style: italic; }
"##;
