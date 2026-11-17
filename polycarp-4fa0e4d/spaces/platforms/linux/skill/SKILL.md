---
name: baneyspaces
description: Drive desktop apps on Linux (Omarchy, Hyprland) through BaneySpaces' agent workspace, a hidden Hyprland workspace of your own. Open an allowlisted terminal, viewer or browser there, run a command in a terminal there, read an app's controls and click or type into them, lay out its windows and take a PNG of one. Use when a task on a Linux or Omarchy desktop needs a GUI app, a second terminal or a screenshot of an app, instead of hyprctl, ydotool or screenshots of the user's screen.
---

# BaneySpaces on Linux

`baneyspaces` is the workspace manager on this Omarchy (Hyprland) seat. Agents get one workspace of
their own, `special:agent`, which stays hidden. Everything you open goes there, never takes focus
and never appears on the user's screen. You cannot see or touch the user's windows, and you do not
need to.

Every command prints one JSON envelope: `{"ok":true,"data":{...}}`, or
`{"ok":false,"error":{"code","message","retry","suggestion"}}`. Read `error.suggestion` and follow
it. Put `--agent-id <name>` before the command to name yourself in the action log.

## Check first

```sh
baneyspaces doctor          # daemon, Hyprland, hands engine, accessibility bus
baneyspaces agent status    # what is on the agent workspace, and which windows are drivable
```

`daemon_down` means the daemon is not running. Tell the user; do not start it yourself.

## Open an app

```sh
baneyspaces agent open foot                       # a terminal, on the agent workspace
baneyspaces agent open mpv clip.mp4               # a file from the handoff folder
baneyspaces agent open chromium page.html --wait 10
baneyspaces agent run --dir ~/project -- make test   # a command in a terminal there
```

- **Apps by name only, from a short allowlist:** terminals (foot, kitty, alacritty, ghostty, xterm,
  st, urxvt, weston-terminal), dialogs (zenity, yad), viewers (mpv, imv, swayimg) and browsers
  (chromium, google-chrome, brave, microsoft-edge, helium, firefox, librewolf). Anything else, or a
  path, is refused (`needs_sandbox`, `bad_arguments`). No flags and no URLs.
- **Files come only from the handoff folder**, `~/.local/state/baneyspaces/handoff` (under
  `$XDG_STATE_HOME` when it is set). Copy a file there and pass its name. Terminals and dialogs take
  no file: use `agent run` to run something.
- **Browsers start with a private, empty profile.** They are not the user's signed-in browser.
- The result's `data.window` is the window id (`0x...`). Take ids from results; never type one.
  With `pending: true` the app is still starting: wait, then run `agent windows`.
- `--new_window=false` reuses the window your session already opened for that app.

## Read and act on an app

```sh
baneyspaces agent snapshot --window 0x5da0 -i     # interactive controls, each with a ref like @s8f3k2p9:e8
baneyspaces agent find --window 0x5da0 --role button --name Save
baneyspaces agent click @s8f3k2p9:e8
baneyspaces agent type @s8f3k2p9:e3 hello world
baneyspaces agent set-value @s8f3k2p9:e3 hello
baneyspaces agent toggle @s8f3k2p9:e5
baneyspaces agent select @s8f3k2p9:e6 Large
baneyspaces agent scroll @s8f3k2p9:e2 down 3
baneyspaces agent get @s8f3k2p9:e3 value
```

- Snapshot, then act on a ref from that snapshot. A ref belongs to one snapshot of one window;
  `stale_ref` means take a new snapshot. Snapshot again to check the result.
- `get` reads `text`, `value`, `title`, `bounds`, `role` or `states`.
- `verified: true` in a result means the engine read the outcome back from the control.
- Keys and the pointer (`agent press`, `agent key`, `agent pointer`) are not supported on Linux
  yet. Use `type` or `set-value` on a ref.

## See a window

```sh
baneyspaces agent shot --window 0x5da0 --out page.png
```

The PNG goes to `~/.local/state/baneyspaces/shots/` and `data.path` says where. The window stays
hidden. Prefer `snapshot` for reading text; use `shot` to see layout or images.

## Arrange and close

```sh
baneyspaces agent workspaces                      # the nine workspaces and the agent workspace (counts only)
baneyspaces agent arrange halves                  # full, halves, thirds or grid
baneyspaces agent move --window 0x5da0 --frame 0,0,800,600
baneyspaces agent close --window 0x5da0           # only windows your session opened
baneyspaces agent log --since 600                 # what you did in the last ten minutes
```

Your session is `--session S`, else `$BANEYSPACES_SESSION`, else your terminal. `close` and
`--new_window=false` only see windows that session opened.

## Never

- `switch`, `move`, `focus-monitor`, `overview`, `stop`, `agent-workspace`, `agent move <window>`
  and `agent bring` are the user's. They are refused to agents (`not_in_scope`). Do not retry.
- Do not use `hyprctl`, `ydotool`, `wtype` or `grim` on the user's screen to get around a refusal.
  A shell from `agent run` has no Hyprland instance on purpose.
- `not_in_scope` on a window means the user took it back or it is theirs. Leave it alone.
- `needs_lend` means a window the user parked on the agent workspace. It is theirs; ask them.
