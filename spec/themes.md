# Themes and the dock switch

Every platform (macOS, Windows, Linux and Omarchy) draws its UI from the same themes and
palettes, and every one lets you turn the dock off. `themes.json` and `palettes.json` are the
contract; this file says how to read them.

## Settings

| Key | Values | Default |
| --- | --- | --- |
| `appearance.theme` | `baneyspaces`, `omarchy`, `minimal` | `omarchy` on Omarchy, `baneyspaces` elsewhere |
| `appearance.palette` | `auto`, or any name in `palettes.json` | `auto` |
| `dock.enabled` | `true`, `false` | `true` |

All three are in Settings on every platform and apply live: no restart, and the next frame after
the change already shows them (budget: 200 ms). The CLI sets them too:
`baneyspaces set appearance.theme omarchy`, `baneyspaces set dock.enabled false`.

## Themes

A theme is shape, type and motion. A palette is color. Any theme takes any palette.

- **BaneySpaces**: rounded, translucent and blurred, the system font, soft shadows, dots for
  workspaces. It is the current macOS look.
- **Omarchy**: blocky. Square corners everywhere, a solid 2 px border (the accent color when
  focused), an opaque fill, no blur and no shadow, a monospace font, workspaces as numbered
  blocks, and fades only, with no scaling or lift. It matches Omarchy's own Hyprland look
  (`rounding = 0`, `border_size = 2`, `gaps_in = 5`).
- **Minimal**: flat and small. Thin borders, an opaque fill, bars for workspaces, short fades.

Token meanings (`themes.json`):

- `radius`: corner radius in points: panels, tiles and list rows.
- `border`: `role` names a palette role, and `opacity` is applied to it. `focused_*` is for the
  current workspace, the selected row and the hovered tile.
- `fill`: the panel background role, its opacity, and whether the platform's blur is behind it.
  Where blur isn't available, use the opacity alone.
- `font.family`: a key into `fonts`. Use the first family that is installed.
- `space`: gap between tiles, panel padding, and tile size.
- `indicator`: how a workspace shows in the dock, the bar module and the overview: `dot`,
  `bar` or `number-block` (its number in a square).
- `motion`: durations in ms. `scale_from` and `lift` of 1.0 mean no scaling. Under Reduce Motion
  (or its platform equivalent), every duration is 0.

## Palettes

`palettes.json` holds Omarchy's bundled themes (MIT), mapped to BaneySpaces' roles:
background, surface, sunken, foreground, strong, muted, border, accent, selection, urgent,
working and done. Regenerate it with `scripts/gen-palettes.py`; never edit it by hand.

`auto` means:

- **Omarchy**: the live Omarchy theme. Read `colors.toml` from the current theme (bundled under
  `/usr/share/omarchy/themes`, or your own under `~/.config/omarchy/themes`) with the same role
  mapping, and follow theme changes without a restart.
- **macOS and Windows**: the system's light or dark mode and its accent color, over the
  `baneyspaces` defaults the platform already draws.

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

With `dock.enabled` false:

- No dock window exists. Nothing reveals at the screen edge, and the "+N" list and window strip
  never open.
- Dragging a window to the bottom edge does nothing special. Dragging to the top still works where
  the platform has it.
- Everything else keeps working: workspace keys, the window switcher, the launcher, the overview,
  the agent workspace and the workspace indicator.
- Turning it back on brings the dock back on the next edge reveal, with no restart.
