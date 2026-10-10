# Changelog

## 0.1.0 · 2026-10-10

The first release.

- Nine workspaces on ⌘1–⌘9. ⌘⇧1–⌘⇧9 sends the front window to a workspace and follows it.
  Pick ⌃, ⌥ or ⌃⌥ instead of ⌘ in setup.
- Windows on other workspaces are hidden by hiding their app, as ⌘H does, so nothing is moved,
  minimized or shown in Mission Control. An app split across workspaces parks its other windows
  just off screen and puts them back exactly.
- The overview: the Mission Control key or ⌃↑ shows all nine workspaces in a 3×3 grid. Click a
  workspace or a window to go there, press 1–9, or drag a window onto another workspace.
- Full screen fills the screen instead of creating a separate macOS desktop, so every window
  stays on a workspace.
- The Dock and ⌘Tab take you to the workspace a window lives on.
- A setup window checks Accessibility access, shortcut conflicts, the overview keys, the number
  of macOS desktops and Open at Login, and fixes what it can in one click.
- Quitting brings every window back; after a crash, the next launch does.
- `baneyspaces://` URLs for scripts: switch, move, restore and viewer.
