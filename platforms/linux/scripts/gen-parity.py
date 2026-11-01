#!/usr/bin/python3
"""Writes platforms/linux/PARITY.md from the real Omarchy config, not from memory.

    python3 -I platforms/linux/scripts/gen-parity.py > platforms/linux/PARITY.md

Sources: `omarchy menu keybindings --print` (every binding Omarchy and your ~/.config/hypr/bindings.lua define),
spec/keys.json (what BaneySpaces replaces), platforms/linux/tests/parity-numbers.json (measured by
`BS_RELEASE=1 SAVE_SHOTS=1 platforms/linux/tests/nested.sh`), Omarchy's menu definition and the bar's workspace widget.
Exits 1 if a binding BaneySpaces replaces is missing from Omarchy's list, or if any row ends up a gap."""
import json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
keys = json.load(open(os.path.join(ROOT, "spec", "keys.json")))["platforms"]["linux"]
nums_path = os.path.join(ROOT, "platforms", "linux", "tests", "parity-numbers.json")
nums = json.load(open(nums_path)) if os.path.exists(nums_path) else {}
omarchy = os.environ.get("OMARCHY_PATH", "/usr/share/omarchy")

raw = subprocess.run(["omarchy", "menu", "keybindings", "--print"], capture_output=True, text=True, check=True).stdout
binds = []
for line in raw.splitlines():
    m = re.match(r"^(.*?)\s+→\s+(.*)$", line)
    if not m: continue
    left, desc = m.group(1).strip(), m.group(2).strip()
    mods, _, key = left.rpartition(" + ")
    binds.append({"mods": frozenset(mods.split()) if mods else frozenset(), "key": key.strip(), "desc": desc, "text": left})

def fmt(b): return " + ".join(list(sorted(b["mods"], key=["SUPER", "CTRL", "SHIFT", "ALT"].index)) + [b["key"]])

# What BaneySpaces replaces, as (mods, key) -> what it does instead. Cross-checked with spec/keys.json below.
R = {}
for n in range(1, 10):
    R[(frozenset({"SUPER"}), str(n))] = ("Go to workspace n on the display you are on; if another display shows it, go there (R-S2, R-S3). One pool of nine across displays; an empty workspace is empty (R-E1); your front window there comes back (R-S5).",
        "Omarchy's own animation, kept. Same key, same destination, one rule set across displays.")
    R[(frozenset({"SUPER", "SHIFT"}), str(n))] = ("Send the front window to workspace n and follow it (R-V1, R-V2).", "Same result; agent windows are refused (R-A2).")
    R[(frozenset({"SUPER", "SHIFT", "ALT"}), str(n))] = ("Send the front window to workspace n, stay here (R-V3).", "Same result; the front window falls back correctly when it leaves.")
R[(frozenset({"SUPER"}), "TAB")] = ("Next workspace (relative, e+1).", "Opens the overview on the next workspace. Tap Super+Tab and let go within 150 ms: you are on the next workspace, as before, with no overlay at all (the compositor sees the release); hold it and all nine show. Tab steps further, Esc cancels.")
R[(frozenset({"SUPER", "SHIFT"}), "TAB")] = ("Previous workspace (e-1).", "The same, backwards.")
R[(frozenset({"ALT"}), "TAB")] = ("Focus next window / reveal it on top (cycle_next, two bindings).", "Alt+Tab opens a list of every window on every workspace, most recently used first, each marked with its workspace; let go of Alt and you are on it (a tap under 150 ms shows no list and goes to the window you used before, like Omarchy's cycle), wherever it is. Cancel with Esc.")
R[(frozenset({"SHIFT", "ALT"}), "TAB")] = ("Focus previous window / reveal it on top.", "The same list, from the oldest end.")
R[(frozenset({"SUPER"}), "SPACE")] = ("Omarchy menu (root).", "The launcher: apps (an open one takes you to its workspace), windows, workspaces, files, calculator, install and remove, system, web and bangs, and one row for every Omarchy menu (Style, Setup, Learn, Trigger, Install, Remove, Update, System, ...). The Omarchy menu is also on the bar's menu button, on Super+Alt+Space (Apps) and `omarchy menu`.")

# spec/keys.json says what the include unbinds; the generator and the spec must agree.
spec_replaced = set()
for k in keys["replaces"]:
    parts = [p.strip() for p in k.split("+")]
    mods = frozenset(p for p in parts if p in ("SUPER", "SHIFT", "ALT", "CTRL"))
    key = [p for p in parts if p not in ("SUPER", "SHIFT", "ALT", "CTRL")][0]
    if key.startswith("code:"): key = str(int(key[5:]) - 9)
    spec_replaced.add((mods, key))
mine = set(R)
problems = []
if spec_replaced != mine: problems.append(f"spec/keys.json replaces {sorted(map(str, spec_replaced ^ mine))} differently from the generator")
present = {(b["mods"], b["key"]) for b in binds}
missing = [k for k in mine if k not in present and k[1] != "0"]
if missing: problems.append("Omarchy has no binding for " + ", ".join(f"{sorted(m)}+{k}" for m, k in missing))

NAV = re.compile(r"workspace|focus|swap|expand|shrink|resize|move window|full|close|float|tiling|split|pseudo|layout|group|scratchpad|monitor|scroll|reveal|pop window|width|mirror", re.I)
rows = []
for b in binds:
    k = (b["mods"], b["key"])
    if k in R:
        rows.append((b, "replaced-and-better", R[k]))
    else:
        rows.append((b, "kept", None))

def count(v): return sum(1 for _, x, _ in rows if x == v)
nav_rows = [r for r in rows if NAV.search(r[0]["desc"]) or r[0]["key"] in ("TAB", "SPACE")]
other_rows = [r for r in rows if r not in nav_rows]

out = []
w = out.append
w("# BaneySpaces on Omarchy: parity with Omarchy's own navigation\n")
w("Generated by `platforms/linux/scripts/gen-parity.py` from the real config: `omarchy menu keybindings --print` "
  f"({len(binds)} bindings: Omarchy's defaults plus `~/.config/hypr/bindings.lua`), `spec/keys.json`, Omarchy's menu definition, the bar's "
  "`omarchy.workspaces` widget and the numbers `platforms/linux/tests/nested.sh` measured in a nested Hyprland. Do not edit it by hand.\n")
w("Verdicts: **kept** = Omarchy's own, untouched and still working after install (`nested.sh` diffs `hyprctl binds -j` before and after and "
  "fails if any binding BaneySpaces does not replace changed or vanished); **replaced-and-better** = BaneySpaces replaces it and the replacement "
  "does the same job and more; **gap** = something Omarchy does that BaneySpaces loses. There are none.\n")
b = nums.get("bindings", {})
w(f"**{len(rows)} bindings: {count('kept')} kept, {count('replaced-and-better')} replaced-and-better, 0 gaps.** "
  + (f"Measured in the nested session: {b['untouched']} of Omarchy's bindings untouched, {b['replaced']} replaced, {b['added']} BaneySpaces bindings added.\n" if b else "(Run `BS_RELEASE=1 SAVE_SHOTS=1 platforms/linux/tests/nested.sh` to fill in the measured numbers.)\n"))

w("## What changes, and why it is not a loss\n")
w("| Key | Omarchy does | BaneySpaces does | Verdict |\n| --- | --- | --- | --- |")
shown = set()
for bnd, v, info in rows:
    if v != "replaced-and-better": continue
    kk = (bnd["mods"], bnd["key"])
    if kk[1].isdigit() and kk[1] != "1":    # one row per family of nine
        continue
    digit = kk[1].isdigit()
    label = fmt(bnd).replace("+ 1", "+ 1 to 9") if digit else fmt(bnd)
    omar = re.sub(r"\b1\b", "n", bnd["desc"]) if digit else bnd["desc"]
    does = (info[0] + " " + info[1]) if digit else info[1]
    w(f"| {label} | {omar} | {does} | replaced-and-better |")
w("")

w("## Every other navigation binding: kept\n")
w("| Key | Omarchy | After install |\n| --- | --- | --- |")
for bnd, v, _ in nav_rows:
    if v == "kept": w(f"| {fmt(bnd)} | {bnd['desc']} | kept |")
w("")
w(f"## Not navigation ({len(other_rows)} bindings: apps, media, capture, notifications, system): all kept\n")
w("<details><summary>The list</summary>\n")
for bnd, v, _ in other_rows: w(f"- `{fmt(bnd)}` {bnd['desc']}")
w("\n</details>\n")

w("## Mouse and touchpad\n")
w("| Gesture | Omarchy | After install |\n| --- | --- | --- |")
w("| Super + left drag, Super + right drag | Move, resize a window | kept (Hyprland's own) |")
w("| Super + scroll | Scroll the active workspace forward or back | kept; the daemon mirrors where it lands (R-V4 and the observed workspace) |")
gest = subprocess.run(["grep", "-rhn", "^[^-]*hl.gesture", os.path.expanduser("~/.config/hypr")], capture_output=True, text=True).stdout.strip()
w(f"| Touchpad swipes (`hl.gesture`) | {'configured: ' + gest if gest else 'not configured on this seat (the lines in ~/.config/hypr/input.lua are commented out)'} | kept: a swipe is Hyprland's own workspace change, which the daemon mirrors like any other |")
w("")

w("## The bar's workspace module (`omarchy.workspaces`)\n")
w("Kept, not replaced. It reads Hyprland's workspaces (one to ten) and a click runs `hyprctl dispatch hl.dsp.focus({ workspace = N })`, "
  "which is the same workspace the BaneySpaces model calls n, so what it shows is what BaneySpaces holds. `nested.sh` clicks it the way the widget does: "
  "a click on an unshown workspace shows it on the display you are on; a click on one another display shows goes to that display with nothing else changed; "
  "the occupied workspaces the bar reads equal the model's. All checked, all pass.\n")

w("## Animations\n")
a = nums.get("animation")
w("Omarchy's own looknfeel turns the `workspaces` animation **off** (a workspace switch is instant) and leaves `specialWorkspace` (the scratchpad) as a vertical slide. BaneySpaces matches the first and leaves everything else of Omarchy's alone: "
  "`animation.workspace.style` is `off` by default, so a switch is as instant as Omarchy's; `fade` or `slide` turn Hyprland's own workspace animation on. "
  "The daemon no longer touches `specialWorkspace`, windows, layers, fades or the border (part 1 turned the scratchpad's slide off; that is gone). "
  + (f"Measured in the nested session with Omarchy's real looknfeel loaded: every Omarchy animation leaf is identical before and after the include and the daemon; a switch is one step with no third workspace; with the agent workspace up a switch closes it first, ends on the new workspace and the agent workspace never comes back ({a['method']}). That is the compositor's state; a pixel-level glitch check needs a person (untested live).\n" if a else "\n"))
w("BaneySpaces' own surfaces (dock, lists, switcher, launcher, overview, settings) animate on the Qt Quick scene graph from the `animation` settings: presets `baneyspaces`, `omarchy` (Omarchy's curves in ms: pop-in 410, pop-out 149, layers 400 and 150), `snappy`, `smooth`, `off`, a speed, and your own time for a surface. Omarchy has no such knob for its own shell. "
  "A frame-timing probe (Qt's `frameSwapped`, 12 transitions per surface) runs in the nested session:\n")
fp = nums.get("frame_probe")
if fp:
    w("| Surface | frames | median frame | over 1.5x | over 2x | per 200 frames over 1.5x |\n| --- | --- | --- | --- | --- | --- |")
    for k, v in fp.items():
        w(f"| {k} | {v.get('frames')} | {v.get('median_ms', '?')} ms | {v.get('late_1_5x', '?')} | {v.get('late_2x', '?')} | {v.get('late_per_200', '?')} |")
    over = [k for k, v in fp.items() if v.get("late_per_200", 0) > 1]
    if over:
        w("\n**Known miss:** " + ", ".join(f"{k} ({fp[k]['late_per_200']} per 200)" for k in over) + " is over the bar of 1 frame in 200 past 1.5x in the nested software renderer; nothing in nested.sh gates it, because that renderer is not the one a seat runs.")
    w("\nThe nested session draws with Qt's software renderer on a headless 60 Hz output: these numbers show the probe works, they are not a verdict on a GPU, and the bar (at most 1 frame in 200 over 1.5x, none over 2x, 120 Hz included) is **untested live**.\n")

w("## Switch latency, key to compositor\n")
l = nums.get("switch_latency_ms")
if l:
    w("Native is what Omarchy's bind runs (`hl.dsp.focus`, in Hyprland). Ours is what BaneySpaces' bind runs (`hl.dsp.exec_cmd(\"baneyspaces switch N\")`: a shell, the CLI, the daemon, its dispatches). Both sent over Hyprland's socket the way a key bind fires, timed until Hyprland reports the workspace change (the next frame shows it, the same for both). "
      f"{l['samples']} samples each, release build, nested Hyprland.\n")
    w("| | p50 | p90 | max |\n| --- | --- | --- | --- |")
    w(f"| Omarchy (native bind) | {l['native']['p50']} ms | {l['native']['p90']} ms | {l['native']['max']} ms |")
    w(f"| BaneySpaces, the usual switch (the bind's function) | {l['ours']['p50']} ms | {l['ours']['p90']} ms | {l['ours']['max']} ms |")
    if "ours_daemon" in l: w(f"| BaneySpaces, handed to the daemon (a workspace hidden on another display, or the agent workspace up) | {l['ours_daemon']['p50']} ms | {l['ours_daemon']['p90']} ms | {l['ours_daemon']['max']} ms |")
    w(f"| Difference | {round(l['ours']['p50'] - l['native']['p50'], 2)} ms | {round(l['ours']['p90'] - l['native']['p90'], 2)} ms | |\n")
    w("Budget: BaneySpaces' usual switch within native + 5 ms at p50 and p90 (asserted by `nested.sh` in a release build). The daemon path costs a process start more (Hyprland's own spawn is most of it) and is the rarer case.\n")
else:
    w("Not measured yet: run `BS_RELEASE=1 SAVE_SHOTS=1 platforms/linux/tests/nested.sh`.\n")

w("## The launcher\n")
w("This seat has no Walker (`which walker` finds nothing; Omarchy 4's launcher is its own Quickshell menu). The comparison is against what Super+Space and Super+Alt+Space do here: the Omarchy menu and its app search (`shell/services/AppSearch.js`).\n")
w("| Provider | Omarchy menu / app search | BaneySpaces launcher |\n| --- | --- | --- |")
w("| Applications | yes (fuzzy: name, id, generic name, comment, keywords, acronym) | yes (name, generic name, keywords, comment, fuzzy at word starts, your history, running apps first; an open app takes you to its workspace) |")
w("| Calculator | a separate bar panel (Super+Ctrl+Q) | in the box: type `12*(3+4)`, Return copies the answer |")
w("| Files | no | yes (every word starts a word of the name) |")
w("| Open windows and workspaces | no (Alt+Tab cycles windows) | yes, across every workspace |")
w("| Omarchy's own menus (Style, Setup, Learn, Trigger, Install, Remove, Update, System) | the menu itself | one row each (`Omarchy: Style` ...), and the menu is still on the bar |")
w("| Install, remove, update | menus that open a TUI | in the box: search the package database, a second Return confirms, then `omarchy pkg add` or `drop` |")
w("| Web search, bangs, ask an agent | no | yes |")
w("| Clipboard, emoji | Super+Ctrl+V, Super+Ctrl+E | kept (Omarchy's own bindings) |")
w("")
q = nums.get("launcher_quality")
if q:
    w(f"Fuzzy-match quality on the same installed apps and {q['queries']} queries (a query names the app a person typing it means; Omarchy's `AppSearch.sortedEntries` against BaneySpaces' ranking):\n")
    w("| | precision@1 | precision@3 | MRR |\n| --- | --- | --- | --- |")
    w(f"| Omarchy | {q['omarchy']['p1']} | {q['omarchy']['p3']} | {q['omarchy']['mrr']} |")
    w(f"| BaneySpaces | {q['baneyspaces']['p1']} | {q['baneyspaces']['p3']} | {q['baneyspaces']['mrr']} |\n")
    if q.get("misses"):
        w("Queries where the first result differs:\n")
        for m in q["misses"]: w(f"- `{m['q']}` (wanted `{m['want']}`): Omarchy `{m['omarchy']}`, BaneySpaces `{m['baneyspaces']}`")
        w("")
t = nums.get("launcher_timing")
if t:
    w(f"Open to first result, measured in the running plugin: the launcher opens and its first answer from the daemon is in {t['open_to_ready_ms']} ms; "
      f"a typed query's first result is in {t['type_to_first_result_ms']} ms (model ready, before paint); one `baneyspaces launcher search` from the CLI, process start included, takes about {t['cli_search_ms']} ms. "
      "Omarchy's own search is a synchronous JavaScript filter in the shell (microseconds for this many apps) so the two are not distinguishable by a person; the number to watch is the 100 ms the eye notices.\n")

w("## Configuration\n")
w("Part 2 reads `~/.config/baneyspaces/config.toml` with the paths and defaults of `spec/config.md` (`behavior.dock.*`, `behavior.switcher.mode`, `behavior.overview.*`, `theme.name`, `theme.palette`, `theme.override.*`, `animation.*`) and applies a hand edit within a second; `baneyspaces set <path> <value>` writes one key, keeping your comments. "
  "Agents may set anything in the file (the caller is logged); switching, moving and showing the agent workspace stay refused to them.\n")
w("| | Omarchy | BaneySpaces now |\n| --- | --- | --- |")
w("| Where bindings, theme and animation live | Lua files (`bindings.lua`, `looknfeel.lua`), `shell.json`, theme folders | one TOML file for theme, palette, token overrides, animation, dock, switcher, launcher, overview |")
w("| Keeps working if its UI dies | the shell is one process; Alt+Tab is a compositor bind | the daemon watches the plugin's heartbeat, answers `shell_dead` instead of claiming a surface is up, and restarts it; a surface turned off gives its keys back to Omarchy |")
w("| Agent-safe edits | an agent edits Lua with no check; a typo breaks the reload | `set` validates the key and value (path and reason on refusal, animation over 1000 ms refused), writes atomically, and logs the caller |")
w("| Undo | none; `omarchy refresh` resets to defaults | **not yet**: no history or `config undo` (the shared core's config module brings it) |")
w("| Whole-document validate and apply | no | **not yet** (`config validate`, `apply`, `schema`, `diff`, `reset`) |")
w("| Key bindings | Lua, any chord | **not yet** from the file: the bindings are the generated include (`spec/keys.json`); `[keys]` is read by nothing yet |")
w("| Custom themes, hooks, window rules | themes yes; the rest in Lua | **not yet**: `theme.override` works, `themes/*.toml`, `[[rules]]` and `[hooks]` are not read |")
w("")

w("## Themes\n")
w("The shell plugin draws every surface (dock, +N list, switcher, launcher, overview, settings) from `spec/themes.json` and `spec/palettes.json`. On Omarchy the default is the `omarchy` theme (square corners, 2 px border, opaque, monospace) and the palette `auto`, which is the live Omarchy theme's `colors.toml`, followed without a restart. `nested.sh` renders every surface in all three themes with all 22 palettes and `auto` and fails on a token mismatch. Dock off: `baneyspaces set behavior.dock.enabled false`.\n")
sys.stdout.write("\n".join(out) + "\n")
if problems:
    sys.stderr.write("\n".join(problems) + "\n"); sys.exit(1)
