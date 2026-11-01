# The overview

The overview shows all nine workspaces at once. You go to one, move a window between them, or find
a window by typing. macOS, Linux and Windows draw it from this page and from the theme
(`themes.md`). Donovan, 2026-11-01, on the old one: eight empty boxes took the screen, workspace 1's
seven windows were cut off at five and a half, and "You're here" was red. Omarchy has no overview,
and macOS's Mission Control has no workspaces, so this one has to be the best of the three.

## Layout

- **Adaptive by default** (`behavior.overview.layout = "adaptive"`). Workspaces with windows share
  the screen in proportion to how many windows each has. A workspace with one window gets at least
  a quarter of the share a workspace with seven gets. `grid` keeps nine equal tiles.
- **Empty workspaces become a strip** (`behavior.overview.empty = "compact"`): one row of numbered
  slots along the bottom, each the size of a dock tile, showing its number and its tint. They're
  still click and drop targets. Hovering or dragging over one opens it to a full tile. `full`
  gives them full tiles; `hidden` leaves them out except while a window is dragged.
- **Nothing is ever cut off.** Every window of every workspace is shown. Cards scale down to fit
  their tile, then the tile grows, then the other tiles shrink. A tile never scrolls or clips. If
  more than 24 windows share one tile, the smallest cards collapse into a "+N" card that expands in
  place.
- **Multiple displays:** each display shows its own overview, with the workspace it's showing marked.
  Workspaces on other displays appear dimmed, with that display's name.

## Window cards

- **Live previews** where the platform allows (macOS with Screen Recording granted, Hyprland
  toplevel export, Windows DWM thumbnails), at the window's aspect ratio.
- **Without previews,** a card at the window's aspect ratio with the app icon large in the
  middle and the window title below.
- **Every card** shows the app icon and the title, truncated in the middle so both ends stay
  readable. The agent's badge and status color appear on agent windows.
- **Cards keep the window's relative position and size within the workspace** where that reads
  well (two side-by-side windows stay side by side). They fall back to a tidy grid when windows
  overlap heavily.

## The current workspace and selection

- The workspace you're on is marked with the theme's focused border in `accent`: a soft accent glow
  in BaneySpaces, a 2 px accent border in Omarchy, a 1 px border in Minimal. Never red: red means
  something is wrong.
- The selected workspace or card (from keys or hover) has the theme's selection fill. Its number
  turns `accent`.

## Input

- `1`–`9` go to that workspace. The arrow keys move the selection between workspaces and cards,
  and Return goes to it. Esc closes.
- **Type to find.** Any letter starts a filter over all windows on all workspaces, matching the
  title and app with the launcher's fuzzy matcher. Cards that don't match dim to 25 %. Return goes
  to the best match's window. A filter that matches no window offers the launcher's results for
  that text as one row ("Open 'xyz' here").
- **Drag** a card to another tile or to a strip slot to move the window. Drop on the strip's `+` to
  move the window to the first empty workspace. Hold Option or Alt while dropping to move and follow.
- **Click** a tile's empty area to go to that workspace. Click a card to go to that window.
  Middle-click a card to close the window (it asks first if the app has unsaved changes).
- **Open here:** clicking a strip slot, or pressing `+` on a selected tile, opens the launcher for
  that workspace (`config.md`, `behavior.launcher.open`).

## Help

One dim line at the bottom: `1–9 go · type to find · drag to move · esc`. It hides after the
overview has been opened 20 times, and `?` shows it again.

## Motion

Opening: each card springs from its window's real place on screen into its tile. A snapshot layer
moves, never the window itself. Closing reverses it toward the chosen workspace. It's interruptible
and uses the `overview.in`, `overview.out` and `overview.tile` animations (`config.md`) under the
animation quality bar there. With previews off, cards fade and scale from 0.96 instead.

## Speed

The first frame of the overview shows within one frame of the key, using cached previews if live
ones aren't ready. Live previews fill in after. The filter answers each keystroke within 8 ms for
200 windows.

## Checks every platform runs

- A render test with Donovan's reported load (workspace 1 holding Word, Helium, Obsidian, T3 Code,
  Excel, Grok Bot and Terminal; the rest empty) that fails if any card is clipped or missing.
- A layout test across 0, 1, 7, 24 and 60 windows per workspace and 1–3 displays: no clipping, no
  overlap between cards, and every workspace reachable.
- The frame-timing probe for `overview.in` and `overview.out`.
- A filter latency test with 200 windows.
