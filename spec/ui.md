# UI rules (dock, switcher, launcher, overview)

The surfaces every platform draws. The Mac implements them in `Sources/`, Linux as an Omarchy shell plugin
(`platforms/linux/omarchy/plugins/`) that draws a snapshot the daemon pushes. The decisions live in the daemon
(`platforms/linux/baneyspaces/src/ui.rs`, `launcher.rs`) so they are unit tested without a compositor.
Rule ids are checked by name in those tests.

## Workspace Dock

### R-D1 One tile per workspace in use, plus the one you are on, plus a dashed "+"
A workspace is in use when it has a window or a display shows it. The dashed tile is the first empty workspace
no display shows; with all nine in use there is none. A tile with more than four apps shows three and a "+N".

### R-D2 It comes up at the edge, and goes down 300 ms after the pointer leaves
Rest the pointer on the last rows of a display (`behavior.dock.reveal_ms`, 0 by default) and the dock comes up on that display. Not over
a full-screen window unless `behavior.dock.in_fullscreen` is on.

### R-D3 The keep zone is the bar you see plus 12 pt
Not the panel, not a label row. While a list is open: the bar plus the list's own frame, each plus 12 pt.
Before the bar is measured, the bottom 120 pt of that display.

### R-D4 A pointer that rests where it opened the dock holds it
Only while it stays still there; once it moves, only the keep zone counts. A drag and an open menu hold the dock
(`dock hold`), a script can pin it (`dock show`).

### R-D5 Lists are windows of their own and close 250 ms after the pointer leaves
The "+N" list, the strip of an app's windows and the context menus never resize or move the bar. They close
250 ms after the pointer leaves the list and the tile that opened it; Esc or a click outside closes at once.

### R-D6 Motion
The dock slides 8 pt and fades in 180 ms, out 140 ms. A list grows from 96% and fades 140 ms in, 100 ms out.
A drag lifts to 104%. Each animation is scoped to its own layer (never a parent of the tiles). With reduced
motion everything is instant. `animation.respect_reduce_motion` (default true) follows the desktop's animation setting.

### R-D7 Moving by drag
Dropping an app's icon (or one window from a list) on a tile sends those windows there and you stay where you
are; dropping on the dashed tile starts a new workspace with them. Windows of an agent are never moved.

### R-D8 Agent status
A turning ring on an app means an agent in it is working, a yellow "?" asking, a red "!" stopped on an error, an
orange count finished while you were elsewhere. Hooks report the state (`agent-status set`); without them a
terminal title is read (a braille spinner means working, a star means idle). A hook outranks a title. Finished
and error clear when you look at the window; a working badge nobody refreshed for 15 minutes is dropped.

## Switcher

### R-W1 Alt+Tab steps through the windows of every workspace
Most recently used first, each marked with its workspace. The first press selects the window you used before this
one; Shift steps back; letting go of Alt goes to the selected window, wherever it is (R-F1 brings its workspace to
the display you are on); Esc cancels. Windows of an agent are never offered. `switcher.items = apps` offers each
app's most recent window. A switcher nobody finishes closes itself after 15 s.

## Launcher

### R-L1 One box
Type to search apps, windows, workspaces, files and commands at once. An app that is already open takes you to
the workspace it is on. Tab goes into a menu (Apps, Files, Install, Remove, Update, System, Workspaces),
Backspace on an empty search comes back. With nothing typed, agents that finished or need you come first.

### R-L2 Files
Every word typed must start a word of the name (`tax 2025` finds `2025 Tax Return.pdf`; words also break at `_`
and in camelCase). The best five show under the apps.

### R-L3 Install and remove ask first
Return on a package shows what will run and waits for a second Return. The command is `omarchy pkg add|drop <name>`
in a terminal (it may ask for a password). Names are checked before they reach a shell.

### R-L4 The web, bangs and agents
Plain text can go to your search engine, an image search or your agent. `!yt cats` and `cats !yt` go to a site; a
bang that is not built in goes to DuckDuckGo. `?question` asks the agent in a new chat. A bang opens only
http(s) addresses. Your own bangs live in config.toml.

## Overview

### R-O1 Nine workspaces in a 3 x 3 grid
Click a workspace or press its number to go there; arrows move the highlight, Return goes. Click a window to go
to it. Drag a window onto another workspace to move it (you stay in the overview). Esc closes. Previews are a
capture where the platform offers one, else the app's icon and the title.

## Settings

`~/.config/baneyspaces/config.toml`, read with the paths and defaults of `spec/config.md`. Unknown keys are ignored; a known key with a bad value falls back to
its default and is reported. `baneyspaces config` lists every key and what it takes.
