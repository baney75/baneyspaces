# Configuration: keys, themes, animations, behavior

Donovan, 2026-11-01: BaneySpaces must be easy for agents to customize, "including keybindings,
themes, animations, behavior and more", and its animations must be the best. One configuration
works the same on macOS, Windows, Linux and Omarchy. A person edits a file; an agent uses the CLI
or MCP tools that validate every change before it lands. Both reach the same settings.

This file is the contract. `config.schema.json` is generated from the Rust schema tree in `crates/baneyspaces-core/src/config_schema.rs`
(`UPDATE_SPEC=1 cargo test -p baneyspaces-core`), and the two change together: a test fails when the committed schema differs.
`animation-presets.json` is generated the same way and holds every preset's numbers. A platform that reads a key the schema doesn't define, or ignores one it does,
fails its conformance test.

## Where it lives

| Platform | File |
| --- | --- |
| macOS, Linux, Omarchy | `$XDG_CONFIG_HOME/baneyspaces/config.toml` (default `~/.config/baneyspaces/config.toml`) |
| Windows | `%APPDATA%\BaneySpaces\config.toml` |

Custom themes go in `themes/<name>.toml` next to the file. History goes in `history/`, the last 50
versions, each stamped with who changed it.

The file holds only what differs from the defaults. A missing file means every default. Settings
already stored by the app today (the workspace modifier, panel opacity, dock on or off) move into
the file on first launch, and the old store is kept read-only for one release.

## Who may change what

Agents may change what looks and feels (Donovan, 2026-11-01: "agents should be able to customize in any way they choose"):
themes, palettes, animations, behavior, rules and key bindings to plain actions (`switch`, `move`, `overview`, `mode`, ...). Every change is
recorded in `history/` and in the trace log, with the caller: `user`, `settings`, or `agent:<name>`. The caller is read from the peer, never
from a flag, and an agent that edits `config.toml` directly is recorded as `user` (nothing on the machine can tell the two apart), which is
why the next rule does not depend on it.

**Executable configuration waits for a click** (lead's decision, round 1 of the review of #122). These are *pending*, and inert, until
a person approves them in Settings:

- every `hooks.*` entry that is not empty;
- every key binding (in `keys.bindings` or a mode) whose action is `exec ...`, `agent run ...`, or a `config`, `theme` or `set` command.

Cosmetic configuration, and bindings to plain CLI actions, take effect at once as before. Inert means as if the entry were not there: a
default it would have replaced stays bound. The rules:

1. **Approval is per entry**, keyed by a SHA-256 of (path, value). Any change to the value, or the same value on another path, is a new entry
   and is pending. Setting a value back to one that was approved is approved again.
2. **Approvals are stored outside `config.toml`**, in `approvals.json` in the state directory (mode 0600), and are written **only by the
   Settings UI on a real click**: a pending list with Approve and Remove per entry. Approve adds the entry's id; Remove is a plain
   `config unset`. **No CLI, MCP or control-socket operation approves**: `config approve` and the `config_approve` operation are refused
   (`not_in_scope`) with a message pointing to Settings. (The Linux daemon has one test-only operation, `test_settings_approve`, behind
   `BANEYSPACES_TEST_OPS=1`, which `nested.sh` uses in place of the click.)
3. **What is pending is visible.** `config get` returns a `pending` list (`id`, `path`, `value`, `kind`, `written_by_hint`) beside the
   configured values, which still show the pending entries; `config.json` (`pending`) carries the same for Settings. `written_by_hint` is
   the caller of the version that last set the value in the kept history, and is a hint only: a hand edit reads `user`, and a value older than
   the 50 kept versions has no writer. Approval never depends on it.
4. **A hook that is approved runs as the user**, with no agent token. An approved binding runs when its key is pressed.

Three things stay out of reach of every edit, so nobody gets locked out of their own machine:

1. **The recovery chord.** Hold the platform modifier with Shift and Escape for two seconds
   (⌘⇧Esc, Super+Shift+Esc, Win+Shift+Esc). It restores the default keys and the default theme, leaves any mode, and shows what was undone.
   The hold is continuous: all three keys stay down for the whole two seconds, any release cancels it, and a tap followed by a later
   Escape does not count. It works from every mode. Config can't rebind or remove it.
2. **The reset command.** `baneyspaces config reset` and Settings › Reset always work.
3. **Validation.** A change that fails the schema, leaves no binding to switch to some workspace, or sets an animation over 1000 ms is
   refused with the exact path and reason. The running config doesn't change.

Workspace and window operations (switch, move, show the agent workspace) are still refused to agent processes at run time. Agents may still
bind those operations to keys for the person to press. That is the line: an agent can change what your keys do, but it can't press them for
you, and a command it wants run needs a click.

## Interface

```sh
baneyspaces config get [path]              # the effective value, defaults filled in, as JSON
baneyspaces config set <path> <value>      # validated, applied live, recorded in history
baneyspaces config unset <path>            # back to the default
baneyspaces config apply <file|->          # a whole TOML or JSON document, validated as one change
baneyspaces config validate <file|->       # the check without applying it
baneyspaces config schema                  # config.schema.json, for agents to read first
baneyspaces config diff [version]          # against the defaults or a history version
baneyspaces config undo [n]                # step back n versions (default 1)
baneyspaces config history                 # versions with time, caller and summary
baneyspaces config reset [section]         # one section or everything
baneyspaces theme list|show <name>|create <name> --extends <base>|set <name>|delete <name>
```

The MCP server exposes the same set as tools (`config_get`, `config_set`, `config_apply`,
`config_validate`, `config_schema`, `config_diff`, `config_undo`, `config_history`,
`config_reset`, `theme_list`, `theme_show`, `theme_create`, `theme_set`, `theme_delete`).
Paths use dots: `animation.dock.in.duration_ms`, `keys.bindings."mod+1"`. Every answer uses the
envelope in `envelope.md`.

A change applies live: the next frame after it validates already uses it. Budget: 200 ms from
the command to the screen. Editing the file by hand is noticed and applied the same way. An invalid
file leaves the last good config running and shows the error in Settings and the trace log.

## Keys

```toml
[keys]
mod = "cmd"                        # cmd | ctrl | alt (macOS), super (Linux), win | ctrl | alt (Windows)

[keys.bindings]
"mod+1" = "switch 1"               # any CLI command is an action
"mod+shift+1" = "move 1"
"mod+tab" = "switcher windows"
"mod+space" = "launcher"
"mod+grave" = "overview"
"mod+return" = "exec ghostty"      # exec runs a command as you
"mod+r" = "mode resize"            # enter a mode
"mod+h" = "none"                   # unbind a default

[keys.modes.resize]
"h" = "window resize -40 0"
"escape" = "mode default"
```

- **Actions.** An action is a `baneyspaces` CLI command line, so anything the CLI does is bindable,
  plus `exec <command>`, `mode <name>` and `none`. The list of actions is in `cli.md` and in
  `baneyspaces config schema`.
- **Chords.** A chord is modifiers plus one key, in a fixed spelling: `mod`, `cmd`, `ctrl`, `alt`,
  `shift`, `super` and `win`, then a key name from `keys.json`.
- **Modes.** A mode is a named set of bindings, like a Hyprland submap. `escape` leaves it unless
  it's rebound.
- **Conflicts with the system.** A chord the OS or the compositor already owns is reported with
  `config validate` and in Settings, with what owns it. On Omarchy, chords BaneySpaces doesn't
  bind stay Omarchy's (see `platforms/linux/PARITY.md`).

## Themes

```toml
[theme]
name = "omarchy"                   # a built-in or a file in themes/
palette = "auto"                   # auto or any palette in palettes.json, or a custom one

[theme.override]                   # any token from themes.json, for this machine only
radius.tile = 4
font.family = "monospace"
```

A custom theme, `themes/mine.toml`, holds `extends = "<built-in or custom theme>"`, any tokens
to change, and optionally `[palette]` with the twelve roles. Every token in `themes.json` can be
set; nothing is hard-coded on any surface (see `themes.md`). Agents create themes with
`theme create` and switch to them with `theme set`.

## Animations

The quality bar every platform is measured against, by a probe that fails:

1. **Every animation runs on the compositor**: Core Animation on macOS, the Qt Quick scene graph on
   Linux, DirectComposition on Windows. No layout pass runs per frame. Two regression ledger rows
   on macOS came from layout-driven animation.
2. **It hits the display's refresh rate, 120 Hz included.** Over a probe of 100 transitions per
   surface, at most 1 frame in 200 runs over 1.5× the frame interval, and none over 2×.
3. **The first frame is on screen within one frame of the input that caused it.**
4. **Interruptible.** A new target mid-flight continues from the current position and velocity,
   with no jump and no restart.
5. **Workspace switches are instant by default,** with no windows sliding anywhere. That's
   Omarchy's choice too (`workspaces` animation off) and the macOS ledger's first rule.
   `animation.workspace.style` can turn on `fade` or `slide` for those who want it.
   Even then the windows themselves never move: the effect is a snapshot layer over them.
6. **Reduce Motion** (or its platform equivalent) sets every duration to 0 unless the person sets
   `animation.respect_reduce_motion = false`.

```toml
[animation]
preset = "baneyspaces"             # baneyspaces | omarchy | snappy | smooth | off
speed = 1.0                        # multiplies every duration; 0 = off, 0.5 = twice as fast
respect_reduce_motion = true

[animation.dock.in]                # any surface's transition can be set on its own
curve = "spring"                   # spring | bezier | linear
response = 0.32                    # spring: seconds to settle, roughly
damping = 0.86                     # spring: 1 = no overshoot
duration_ms = 180                  # bezier and linear
points = [0.23, 1, 0.32, 1]        # bezier control points
```

**Surfaces:** `dock.in`, `dock.out`, `list.in`, `list.out`, `row`, `hover`, `drag_lift`,
`overview.in`, `overview.out`, `overview.tile`, `switcher.in`, `switcher.out`, `switcher.select`,
`launcher.in`, `launcher.out`, `hud.in`, `hud.out`, `cursor.glide` (the agent cursor),
`workspace` (off by default) and `border` (Linux focus border).

**Presets:**

| Preset | What it is |
| --- | --- |
| `baneyspaces` | Today's macOS motion (`themes.json` `motion`), as springs with the same settle times. |
| `omarchy` | Omarchy's Hyprland curves, converted to milliseconds (Hyprland speed 1 = 100 ms): pop-in 410 ms easeOutQuint (0.23, 1, 0.32, 1); pop-out 149 ms linear; fade-in 173 ms (0.5, 0.5, 0.75, 1); fade-out 146 ms; layers in 400 ms, out 150 ms; border 539 ms; workspaces off. |
| `snappy` | Every duration × 0.6, critically damped springs. |
| `smooth` | Every duration × 1.3, damping 0.8. |
| `off` | Nothing animates. |

## Behavior

```toml
[behavior]
follow_focus = true                # switch to a window's workspace when you activate it yourself
new_window = "current"             # current | app (where the app's other windows are)
workspace_names = { 1 = "Main", 2 = "School" }
workspace_tints = { 1 = "#7aa2f7" }

[behavior.dock]
enabled = true                     # same as dock.enabled in themes.md
edge = "bottom"                    # bottom | left | right
reveal_ms = 0
hide_ms = 400

[behavior.overview]
layout = "adaptive"                # adaptive (workspaces with windows get the room) | grid
empty = "compact"                  # compact | full | hidden
previews = "live"                  # live (needs screen capture permission) | icons

[behavior.switcher]
mode = "windows"                   # windows | apps
hold_ms = 120

[[rules]]                          # first match wins
app = "Ghostty"                    # app name or bundle id; title = a regex
workspace = 2
float = false

[hooks]                            # commands run as you on these events, logged
on_switch = "~/.config/baneyspaces/hooks/switch.sh"
on_window_open = ""
```

Hooks run with your user's rights. An agent that sets a hook is shown in Settings › Hooks, and
the change is recorded in `history/`, so nothing runs that you can't see.

## Details every platform follows

These settle what the sections above leave open. The conformance cases hold them.

- **Chords.** `keys.json` `chords` lists the key names, the `mod` values each platform takes (macOS `cmd`, `ctrl`, `alt`; Linux `super`;
  Windows `win`, `ctrl`, `alt`) and the recovery chord. A chord is lowercase, modifiers then one key. `cmd`, `super` and `win` are one key, the
  logo key. A chord in `keys.bindings` needs a modifier; a chord in a mode may be a bare key. Two spellings of one chord (`mod+1`, `super+1`
  when `mod` is `super`) are one chord: the later one in the file replaces a default, and two in the file are `duplicate_chord`.
- **Defaults.** The default bindings are `keys.json` for the platform, spelled with `mod`: `switch n`, `move n`, `move n --stay` (Linux),
  `overview`, `agent-workspace toggle` (a key that would collide with `switch 9`, as the Mac's and Windows' agent key does, is left out).
- **No lockout.** At least one binding in `keys.bindings` must run `switch <n>`, or enter a mode that has one. Every mode needs a way out
  (`mode default`; `escape` does it unless rebound). The recovery chord, with extra modifiers it is a different chord, is `reserved_chord`
  whether bound to an action or to `none`, at top level or in a mode.
- **Actions.** `spec/cli.md` lists the commands. `daemon`, `mcp`, `help` and `recovery` are not bindable.
- **Animations.** A surface's table overlays its preset. `curve` is optional; the fields imply it (`response` or `damping`: spring; `points`:
  bezier; `duration_ms` alone keeps a bezier or linear preset curve and turns a spring one into a bezier). A field for another curve than the
  one named is `wrong_curve`. Durations are checked after `speed`: 410 ms at speed 2.5 is 1025 ms and refused at `animation.<surface>.duration_ms`.
  `animation.workspace.style` is `off` (default), `fade` or `slide`; the surface's windows never move.
- **Themes.** `shadow = false` (JSON `null`) is no shadow and `fill.material = "none"` is an opaque fill, because TOML has no null. A partial
  `shadow` table is completed from the BaneySpaces theme. `theme.palette` is `auto`, a name in `palettes.json`, or the name of a custom theme that
  carries a `[palette]` (all twelve roles). With `auto`, the active custom theme's own palette wins, else the platform's (Omarchy's live theme),
  else `catppuccin`. A custom theme file must have `extends`; a problem in a theme the config uses is an error, in one it does not use, a warning.
- **Linux-only keys.** `behavior.dock.auto_hide|size|in_fullscreen|badges`, `behavior.switcher.enabled`, `behavior.launcher.*`,
  `behavior.overview.enabled` and `[[bangs]]` (`trigger`, `name`, `url` with `{q}`, `agent`) are in the schema and ignored on other platforms.
- **Behavior.** `follow_focus = false`: your own activation of a window on another workspace does not take you there. `new_window = "app"`: a
  new window joins the workspace of its app's most recent window. `[[rules]]` match on `app` (case-insensitive) and `title` (regex); a rule
  with neither matches nothing. The first match sets `workspace` and `float` for a window that opens (never an agent window).
- **Hooks** run with `BANEYSPACES_HOOK` set and `BANEYSPACES_WORKSPACE` or `BANEYSPACES_WINDOW`, once approved (see Who may change
  what); they are logged to `config.log` and recorded in history, and run as the user.

## Files, history and callers

A CLI or MCP change edits `config.toml` in place: the file is re-read from disk under the lock, and only the settings that changed are
touched, so comments, blank lines and the order of what the person wrote stay (a changed `[[rules]]` list is written again as a whole).
A file edited by hand is noticed, validated, and recorded as `user`; a file that does not validate leaves the last good
config running and `config.json` (`status`) and the trace log say why. `config set` is refused while the file is invalid; `config reset`
and `config undo` work from the last good config and keep every broken file they write over (`config.toml`, and each `themes/*.toml` that
differs) as `*.invalid-<time>`. A theme file that cannot be read (not UTF-8, over 1 MiB) is reported as a warning and never touched.

`history/NNNNNNNN.json`: `{format: 1, seq, time (RFC 3339 UTC), caller, summary (one line), config (the text of config.toml), themes
({name: text}), undo?}`. The first change also records the state before it (`system`). **Undo is history too**: `config undo [n]` writes a
new version holding the state n live versions back (`undo: n`, summary `undo n: back to version K ...`) and deletes nothing. The live
versions are the changes not already stepped over by a later undo, so repeating it goes further back. An agent may undo only versions it made
itself (`not_in_scope` otherwise); `user` and `settings` may undo anything. Writes use a temp file, `fsync` and `rename`.

The caller is taken from the peer, never from a flag: a process that carries an agent launch token is `agent:<name of the launch>`; a call
over MCP is `agent:<id>`; a CLI with `--agent-id` is `agent:<id>`; Settings sends `settings`; anything else is `user`.

A refused change is the envelope code `config_invalid` with `error.data.issues` (`{path, code, reason}`): `unknown_key`, `type`, `range`,
`value`, `length`, `bad_key`, `bad_chord`, `reserved_chord`, `duplicate_chord`, `bad_action`, `bad_mod`, `lockout`, `wrong_curve`, `too_long`,
`bad_theme`, `bad_palette`, `bad_regex`, `bad_url`, `required`, `pending_approval` (a warning), `syntax`.

## Conformance case format

`conformance/config/*.json` are arrays of `{name, platform?, omarchy?, reduce_motion?, themes?, steps}`. A step has `do` (`set`, `unset`,
`apply`, `validate`, `reset`, `undo`, `approve` (the Settings click), `approve_by_command` (must be refused), `edit_file`, `theme_create`, `theme_set`, `theme_delete`, `recovery`, `check`), its arguments, and
optionally `expect` (`"ok"` or `{error, issues: [{path, code}]}`), `effective` (dotted path to value), `configured` (dotted path into what is configured, pending entries included), `absent` (dotted paths that must not be in what runs),
`pending` (the paths waiting for a click, exactly), `resolved` (JSON pointer into `config.json` to value), `history` (`len`, `callers` newest first) and `file` (the exact text of `config.toml`).

## Conformance

Each platform runs `spec/conformance/config/*.json`. Every case is a config document and an
expectation: `valid`, or the error path and code, plus the effective values after it applies.
The recovery chord, the validation limits and the history file format are cases too.
