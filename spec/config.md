# Configuration: keys, themes, animations, behavior

Donovan, 2026-11-01: BaneySpaces must be easy for agents to customize, "including keybindings,
themes, animations, behavior and more", and its animations must be the best. One configuration
works the same on macOS, Windows, Linux and Omarchy. A person edits a file; an agent uses the CLI
or MCP tools that validate every change before it lands. Both reach the same settings.

This file is the contract. `config.schema.json` is generated from it by the first implementation, and from then on the two
change together. A platform that reads a key the schema doesn't define, or ignores one it does,
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

Agents may change anything in this file (Donovan, 2026-11-01: "agents should be able to customize in
any way they choose"). Every change is recorded in `history/` and in the trace log, with the caller:
`user`, `settings`, or `agent:<name>`. Three things stay out of reach of every edit, so nobody gets
locked out of their own machine:

1. **The recovery chord.** Hold the platform modifier with Shift and Escape for two seconds
   (⌘⇧Esc, Super+Shift+Esc, Win+Shift+Esc). It restores the default keys and the default theme
   and shows what was undone. Config can't rebind or remove it.
2. **The reset command.** `baneyspaces config reset` and Settings › Reset always work.
3. **Validation.** A change that fails the schema, leaves no binding to switch to some workspace,
   or sets an animation over 1000 ms is refused with the exact path and reason. The running
   config doesn't change.

Workspace and window operations (switch, move, show the agent workspace) are still refused to agent
processes at run time. Agents may still bind those operations to keys for the person to press. That
is the line: an agent can change what your keys do, but it can't press them for you.

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

[behavior.launcher]
open = "here"                      # here | go

[[rules]]                          # first match wins
app = "Ghostty"                    # app name or bundle id; title = a regex
workspace = 2
float = false

[hooks]                            # commands run as you on these events, logged
on_switch = "~/.config/baneyspaces/hooks/switch.sh"
on_window_open = ""
```

**Open here.** `behavior.launcher.open` decides what opening an app does (Donovan, 2026-11-01: "if
someone presses on a space and tries to open it it should open there"). With `here`, anything opened
from a workspace lands on that workspace and you stay on it. The workspace is the one the open was
asked from: the launcher's (the one its screen is showing when it opens), a dock "+" tile or tile
menu, the overview's empty slot or a tile, or a dock app icon in the workspace you're on.

| The app is | `here` does |
| --- | --- |
| not running | starts it; its first window is claimed for that workspace, so a slow start or a restored window can't land elsewhere |
| running, with a window there | brings that window forward |
| running, able to make a window (Ghostty, Helium, TextEdit, Finder, Terminal, Word) | makes a new window with its own New Window menu item, on that workspace |
| running, without a New Window item (Photos, Music, App Store, System Settings, Calculator, Messages) | moves its existing window to that workspace and focuses it |
| running, with no window | asks it for one, claimed for that workspace |

The app coming forward is never followed to its old workspace: it activates before its window
exists. `go` is the old behavior: go to where the app already is. Holding ⌥ does that for one open
(⌥↩ in the launcher, ⌥-click in the dock and the overview), whatever the setting says. The setting is
also `baneyspaces set behavior.launcher.open here|go`.

Hooks run with your user's rights. An agent that sets a hook is shown in Settings › Hooks, and
the change is recorded in `history/`, so nothing runs that you can't see.

## Conformance

Each platform runs `spec/conformance/config/*.json`. Every case is a config document and an
expectation: `valid`, or the error path and code, plus the effective values after it applies.
The recovery chord, the validation limits and the history file format are cases too.
