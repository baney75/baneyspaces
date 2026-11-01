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
