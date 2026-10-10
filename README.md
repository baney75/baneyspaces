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

- **It's instant.** No animation and no slide. The workspace is on screen when your finger
  leaves the key.
- **Nothing tiles.** Every window keeps its own position and size.
- **New windows open where you are.** Open something on workspace 4 and it lives on workspace 4.
- **The Dock and ⌘Tab still work.** Click an app whose window is on workspace 6 and you go to
  workspace 6.
- **Full screen plays along.** A full-screen window that you leave behind exits full screen and
  fills the screen instead, so it stays on its workspace rather than on a macOS desktop of its own.
- **Empty means empty.** Go to a workspace with nothing on it and you get a clean desktop.
  Typing goes nowhere until you open something.

The menu bar shows the workspace you're on. Open the menu to see which apps sit on each workspace,
or to jump to one with the mouse.

## Your windows are safe

A hidden window isn't minimized or closed. BaneySpaces parks it just past the bottom-right corner
of your screen and remembers where it stood. Every app keeps running, keeps playing audio, and
keeps its place.

- **Quit BaneySpaces** and every window comes back to where it was.
- **If BaneySpaces crashes,** the next launch finds anything left in the corner and puts it back.
- **Bring Every Window Back** in the menu gathers every window onto workspace 1, all visible.
  It gets you out of any tangle.

## Install

```sh
git clone https://github.com/baney75/baneyspaces.git
cd baneyspaces
make install
```

That builds the app, copies it to `~/Applications`, and starts it. The first time it runs:

1. macOS asks you to give BaneySpaces **Accessibility** access. Moving another app's windows
   requires it. Turn it on in System Settings › Privacy & Security › Accessibility.
2. BaneySpaces adds itself to **Open at Login**. Switch that off in the menu if you'd rather not.

Until access is granted, the menu bar shows a warning triangle, and the shortcuts open the
settings page for you.

If you used AeroSpace for the same shortcuts, `make install` quits it and removes it from your
login items, so the two don't fight over the keys. AeroSpace itself stays installed.

### Free up ⌘⇧3, ⌘⇧4 and ⌘⇧5

macOS uses those three for screenshots, and it claims them before any other app sees them. To send
windows to workspaces 3, 4 and 5, turn those off in System Settings › Keyboard › Keyboard
Shortcuts › Screenshots. ⌃⌘⇧3 and ⌃⌘⇧4 still capture to the clipboard.

## Scripting

The same actions are open to scripts and other tools:

```sh
open baneyspaces://switch/2     # go to workspace 2
open baneyspaces://move/5       # send the front window to workspace 5
open baneyspaces://restore      # bring every window back onto workspace 1
```

`~/Library/Application Support/BaneySpaces/state.json` always holds the current workspace and
the apps on each one.

## Limits

- **One set of workspaces covers every display.** ⌘3 changes what every screen shows.
- **Shortcuts stop while Secure Input is on.** When a password field or a terminal's secure
  keyboard entry holds Secure Input, macOS lets no other app see keystrokes. That applies to
  every global shortcut, not just these.
- **Windows on other macOS desktops are left alone.** BaneySpaces manages the desktop you're on.
  One macOS desktop and nine BaneySpaces workspaces is the intended setup.
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
