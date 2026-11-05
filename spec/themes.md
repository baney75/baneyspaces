# Themes and the dock switch

Every platform (macOS, Windows, Linux and Omarchy) draws its UI from the same themes and
palettes, and every one lets you turn the dock off. `themes.json` and `palettes.json` are the
contract; this file says how to read them.

## Settings

| Key | Values | Default |
| --- | --- | --- |
| `appearance.theme` | `baneyspaces`, `omarchy`, `minimal` | `omarchy` on Omarchy, `baneyspaces` elsewhere |
| `appearance.palette` | `auto`, or any name in `palettes.json` | `auto` |
| `dock.enabled` | `true`, `false` | `true`; `false` on macOS (`default_by_platform`) |

All three are in Settings on every platform and apply live: no restart, and the next frame after
the change already shows them (budget: 200 ms). The CLI sets them too:
`baneyspaces set appearance.theme omarchy`, `baneyspaces set dock.enabled false`.

## Themes

A theme is shape, type and motion. A palette is color. Any theme takes any palette.

- **BaneySpaces**: rounded, translucent and blurred, the system font, a soft shadow, dots for
  workspaces. It is the current macOS look.
- **Omarchy**: blocky. Square corners everywhere, a solid 2 px border (the accent color when
  focused), an opaque fill, no blur and no shadow, a monospace font, workspaces as numbered
  blocks, and fades only, with no scaling or lift. It matches Omarchy's own Hyprland look
  (`rounding = 0`, `border_size = 2`, `gaps_in = 5`).
- **Minimal**: flat and small. Thin borders, an opaque fill, bars for workspaces, short fades.

Token meanings (`themes.json`):

- `radius`: corner radius in points: the dock bar, a tile, a list row, and the "+N" list or
  window strip panel.
- `border`: `role` names a palette role. `opacity` applies to it, or `gradient` gives the
  opacity at the top and at the bottom. `focused_*` is for the current workspace, the selected
  row and the hovered tile.
- `fill`: `material` is the platform's blur (`ultra-thin` is macOS's `.ultraThinMaterial`; use
  the nearest on Windows (Acrylic) and Linux (compositor blur), or none). `tint_role` at
  `tint_opacity` is laid over it, and `opacity` applies to the whole panel. `adjustable` means
  Settings may change the opacity, as macOS does today. A `null` material means an opaque fill
  in `tint_role`.
- `shadow`: blur radius, y offset and opacity of black, or `null` for none.
- Three roles aren't palette entries: `light` is plain white, `dark` is plain black (shadows and
  dimming, in every palette), and `workspace` is the workspace's own tint color (each workspace
  has one).

- `font.family`: a key into `fonts`. Use the first family that is installed.
- `space`: gap between tiles, panel padding, and tile size.
- `indicator`: how a workspace shows in the dock, the bar module and the overview: `dot`,
  `bar` or `number-block` (its number in a square).
- `motion`: durations in ms. `scale_from` and `lift` of 1.0 mean no scaling, and a theme whose
  `scale_from` is 1.0 does not slide the dock in either (a fade only). Under Reduce Motion (or its
  platform equivalent), every duration is 0.

The BaneySpaces theme is exactly what macOS draws today. Its tokens are the shipped values, and
macOS's conformance test holds them, so picking it changes nothing on screen. Where a surface
draws text at several sizes (macOS does: 10.5 to 13 pt), `font.size` is the base size, 12: other
sizes scale by `font.size / 12`, and a theme whose `font.weight` is `regular` draws medium and
semibold text regular (bold stays bold).

On macOS `auto` is a built-in palette over the BaneySpaces defaults: `background` is near-black
(white 0.07), `foreground` and `light` white, `sunken` black, and `accent` is the accent chosen in
Settings (or the system's). Its panels are dark in light mode too, as they have always been.

## Palettes

`palettes.json` holds Omarchy's bundled themes (MIT), mapped to BaneySpaces' roles:
background, surface, sunken, foreground, strong, muted, border, accent, selection, urgent,
working and done. Regenerate it with `scripts/gen-palettes.py`; never edit it by hand.

`auto` means:

- **Omarchy**: the live Omarchy theme. Read `colors.toml` from the current theme (bundled under
  `/usr/share/omarchy/themes`, or your own under `~/.config/omarchy/themes`) with the same role
  mapping, and follow theme changes without a restart.
- **macOS**: the built-in dark palette below, with the accent from Settings.
- **Windows**: the system's light or dark mode and its accent color, over the `baneyspaces`
  defaults.

## Polycarp themes

`polycarp theme set <name>` (the Polycarp command, see `themes/README.md`) writes
`<config>/current/theme.json`. `<config>` is `POLYCARP_CONFIG_DIR` if set and absolute, else
`$XDG_CONFIG_HOME/polycarp` if absolute, else `~/.config/polycarp`; on Windows `%APPDATA%\Polycarp`.
macOS reads `surfaces.spaces` and the top-level `mode` (`auto` follows Dark Mode).

A Mac app opened from Finder or at login does not see variables exported in a shell profile. So
`POLYCARP_CONFIG_DIR` or `XDG_CONFIG_HOME` may be set for `polycarp` in a terminal and missing for
BaneySpaces, and then BaneySpaces reads the default `~/.config/polycarp` while the command wrote somewhere
else. BaneySpaces reads the default path unless the variable reaches it (set it for the app with
`launchctl setenv`, or leave it unset for both). `polycarp theme current` prints `folder:`, the folder the
command writes; BaneySpaces reads `<folder>/current/theme.json`.

**Precedence.** While the file holds a valid theme it is the theme in force. It draws every surface
instead of `appearance.theme`, `appearance.palette` and the accent, and it takes the next frame like
any Settings change. It never rewrites those stored values: delete the file (or write one that is
invalid) and the person's own choice is back, as they left it. `baneyspaces set appearance.theme ...`
still stores its value while a Polycarp theme is in force; it draws once the file is gone. The answer says
so: a `note` line, "saved, but not drawn until the Polycarp theme is removed ...".

**Reading.** Strictly, from one file handle: a regular file of at most 256 KB; `schema` 1 (a newer one is refused with a line that says to update the app); colors `#rrggbb`;
numbers in range and really numbers; known enums; font stacks without CSS; and the pairs the UI
draws text on at 4.5:1 in both modes: every pair `polycarp theme` checks (foreground, strong and muted
on background, surface and sunken; foreground and strong on selection; urgent, working, done and
accent on background and surface; `on_accent` on accent; the status colors on sunken at 3:1), and
every text pair Spaces draws (`Look.textPairs`: tooltips, tiles, the overview and the accent badge). Anything else, including a directory, a pipe, a symlink loop
or an unreadable file or folder, means no Polycarp theme and one log line in `trace.log`
(`polycarp theme: ignored ...`, once until the reason changes); the app never fails on it. A missing
file is not a problem and logs nothing (unless a theme was in force: `file removed`).

**Following.** About once a second a background queue stats the file; a change is read there and applied
on the main queue. A file that changed while it was read is read again on the next tick, and so is one whose read failed
for now (out of file handles, an I/O error): the theme in force stays and one line says so. A change of
mode (`chmod`) counts as a change.

**Mapping.** The look is the `minimal` look (palette colors everywhere, the theme's own widths)
with these values:

| Polycarp | Spaces |
| --- | --- |
| `light` / `dark` colors | the twelve roles, by `mode` (`on_accent` is checked against the accent but not drawn: the badge text is black or white, whichever reads) |
| `radius_large`, `radius`, `radius_small` | bar and panels, tiles and list, rows |
| `border_width` | rest; the focused width is 1.5 times it (0 stays 0); border `border`, focused `accent` |
| `blur` | on or off: above 0 is the platform blur at 0.92 opacity, else an opaque fill |
| `shadow` | opacity of BaneySpaces' own shadow (24 radius, 10 down); 0 is none |
| `density` | gap, padding, tile: compact 6/8/56, regular 8/10/64, spacious 10/12/72 |
| `indicator` | `dot`, `bar`, `number-block` |
| `type.ui`, `size`, `weight` | family (the system font when the stack starts with a system or sans name, the monospace font when it starts with a monospace one, else the first installed name, matched without regard to case as in CSS; when none is installed, the system serif or the monospaced system font if the first generic name in the stack asks for one, so a stack of only `serif` draws the system serif and `Missing Font, monospace` draws monospace); base size is `size` x 0.75 (16 draws 12); `weight` 500 and up draws medium and semibold as asked, below that regular |
| `motion.normal`, `fast` | panel and list in, and out, row hover |
| `motion.scale_from` | dock and list scale; 1.0 means fades only and no lift |
| `motion.reduced` | every duration 0 and no scaling |

No field in `themes.json` for: `radius` and `radius_large` stand in for four radii (there are no
separate list and tile values), `blur` is a switch and not a radius, `type.display` and `type.mono`
(checked, not drawn), `type.line_height`, `motion.slow` and `motion.easing` (checked, not used: panels
ease out), and the panel opacity setting (a Polycarp panel is not adjustable).

`baneyspaces doctor` prints `polycarp_theme:` as `none ...` or `in force: <title> (<name>, mode <m>)`.
Settings > Appearance names the theme in force and how to change it.

## Every surface uses the theme

The dock, the "+N" list and window strip, the window switcher (⌘Tab or Alt+Tab), the launcher,
the overview, the workspace indicator (menu bar, Omarchy bar module or tray) and Settings all
take radius, border, fill, font, spacing, indicator and motion from the theme, and color from the
palette. No surface hard-codes a color, radius or duration. The agent cursor and the agent
workspace's tint are the exception: they keep their own colors so agent activity is never
mistaken for yours.

Each platform has a check that fails when a surface ignores the theme: it renders every surface
in all three themes and compares the tokens it used with `themes.json`.

## The dock switch

`themes.json` keeps `default` a plain bool (`true`) and lists the exceptions under
`default_by_platform`. On macOS the Workspace Dock replaces the macOS Dock, so it stays opt-in: a new install leaves
the macOS Dock alone until you turn the Workspace Dock on. Elsewhere the dock starts on.

With `dock.enabled` false:

- No dock window exists. Nothing reveals at the screen edge, and the "+N" list and window strip
  never open.
- Dragging a window to the bottom edge does nothing special. Dragging to the top still works where
  the platform has it.
- Everything else keeps working: workspace keys, the window switcher, the launcher, the overview,
  the agent workspace and the workspace indicator.
- Turning it back on brings the dock back on the next edge reveal, with no restart.
