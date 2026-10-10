<p align="center">
  <img src="docs/icon.png" alt="BaneySpaces icon: nine tiles, one lit" width="128">
</p>

<h1 align="center">BaneySpaces</h1>

<p align="center">
  <b>Nine workspaces. One row of keys. Nothing to configure.</b><br>
  ⌘1 through ⌘9 takes you there. Add ⇧ and the window comes with you.<br>
  <sub>Made by <a href="https://dbaney.com">Donovan Baney</a> · <a href="https://x.com/baney75">@baney75</a> · macOS 13 or later</sub>
</p>

---

macOS already has desktops. Switching between them takes a swipe and an animation, and a
window can't be sent to one without dragging it through Mission Control. Tiling window managers
fix that, then take over your layout in exchange.

BaneySpaces does the one part you wanted. Your windows stay exactly where you put them, at the
size you made them. You just get nine places to put them and a key for each.

## How it works

| Keys | What happens |
| --- | --- |
| ⌘1 – ⌘9 | Go to that workspace. |
| ⌘⇧1 – ⌘⇧9 | Send the front window to that workspace and follow it. |
| Mission Control key, or ⌃↑ | See all nine workspaces at once. |

Prefer to keep ⌘1 for your browser's first tab? Pick ⌃, ⌥ or ⌃⌥ in setup instead.

- **It's instant.** No animation and no slide. The workspace is on screen when your finger
  leaves the key.
- **Nothing tiles.** Every window keeps its own position and size.
- **New windows open where you are.** Open something on workspace 4 and it lives on workspace 4.
- **The Dock and ⌘Tab still work.** Click an app whose window is on workspace 6 and you go to
  workspace 6.
- **Full screen means fill the screen.** macOS full screen moves a window to a desktop of its own,
  and Mission Control fills up with extra desktops that ⌘1–⌘9 can't reach. BaneySpaces brings the
  window straight back out and fills the screen with it, so every window stays on a workspace.
- **Empty means empty.** Go to a workspace with nothing on it and you get a clean desktop.
  Typing goes nowhere until you open something.

## See everything at once

Press the Mission Control key (F3 on Apple keyboards) or ⌃↑, and BaneySpaces shows all nine
workspaces in the same 3×3 grid as the number keys, with every window's app and title.

- **Click a workspace,** or press its number, to go there.
- **Click a window** to go straight to it.
- **Drag a window** onto another workspace to move it. The card follows your cursor and the
  workspace it will land on lights up.
- **Esc,** or the same key again, puts you back where you were.

The menu bar icon shows the number of the workspace you're on, and its menu has the same view.

## Your windows are safe

A window on another workspace isn't minimized, closed or moved. BaneySpaces hides its app, the
same as ⌘H, so it drops out of sight and out of Mission Control while it keeps running and
playing audio. When one app has windows on two workspaces, the window that doesn't belong here
steps just off screen and comes back to the exact spot it left.

- **Quit BaneySpaces** and every window comes back to where it was.
- **If BaneySpaces crashes,** the next launch shows every app it hid and puts back any window it
  moved.
- **Bring Every Window Back** in the menu gathers every window onto workspace 1, all visible.
  It gets you out of any tangle.

## Install

```sh
git clone https://github.com/baney75/baneyspaces.git
cd baneyspaces
make install
```

That builds the app, copies it to `~/Applications`, and starts it. A setup window walks you
through four checks, each of which turns green on its own as soon as it's done:

1. **Let BaneySpaces arrange windows.** macOS asks before any app can show and hide other apps'
   windows. One button opens the right page in System Settings.
2. **Pick your keys.** ⌘, ⌃, ⌥ or ⌃⌥, with what each one gives up. If macOS already uses the keys,
   one click frees them.
3. **Keep one macOS desktop,** so no window ends up out of reach.
4. **Start with your Mac.**

Open setup again any time from the menu bar icon, or by opening BaneySpaces from Finder or
Spotlight.

If you used AeroSpace for the same shortcuts, `make install` quits it and removes it from your
login items, so the two don't fight over the keys. AeroSpace itself stays installed.

macOS uses ⌘⇧3, ⌘⇧4 and ⌘⇧5 for screenshots and claims them before any other app. Setup's
**Free Them** button turns those off so they can move windows; ⌃⌘⇧3 and ⌃⌘⇧4 still capture
to the clipboard.

## Scripting

The same actions are open to scripts and other tools:

```sh
open baneyspaces://switch/2     # go to workspace 2
open baneyspaces://move/5       # send the front window to workspace 5
open baneyspaces://restore      # bring every window back onto workspace 1
open baneyspaces://viewer       # show or hide the overview
```

`~/Library/Application Support/BaneySpaces/state.json` always holds the current workspace and
the apps on each one.

## Limits

- **One set of workspaces covers every display.** ⌘3 changes what every screen shows.
- **Shortcuts stop while Secure Input is on.** When a password field or a terminal's secure
  keyboard entry holds Secure Input, macOS lets no other app see keystrokes. That applies to
  every global shortcut, not just these.
- **Windows on other macOS desktops are left alone.** Keep one macOS desktop in Mission Control
  and let the nine workspaces do the rest.
- **Switching between two windows of the same app with ⌘\`** doesn't follow a window onto
  another workspace yet. The Dock and ⌘Tab do.

## Build from source

```sh
make test      # unit tests for the workspace model and screen math
make app       # build/BaneySpaces.app
make install   # build, install to ~/Applications, start
```

The app is signed with a local certificate that `scripts/signing-identity.sh` creates on first
build and keeps in its own keychain. Because the signature stays the same, macOS keeps the
Accessibility grant across rebuilds.

## License

MIT. See [LICENSE](LICENSE).
