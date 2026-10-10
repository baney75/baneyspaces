<p align="center">
  <img src="docs/icon.png" alt="BaneySpaces icon: nine tiles, one lit" width="128">
</p>

<h1 align="center">BaneySpaces</h1>

<p align="center">
  <a href="https://github.com/baney75/baneyspaces/actions/workflows/ci.yml"><img src="https://github.com/baney75/baneyspaces/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/baney75/baneyspaces/releases/latest"><img src="https://img.shields.io/github/v/release/baney75/baneyspaces?color=e8434a" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-1f2937" alt="macOS 13 or later">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-3b82f6" alt="MIT license"></a>
</p>

<p align="center">
  <b>Nine workspaces. One row of keys. Nothing to configure.</b><br>
  ⌘1 through ⌘9 takes you there. Add ⇧ and the window comes with you.<br>
  <sub><a href="https://dbaney.com/baneyspaces/">dbaney.com/baneyspaces</a> · Made by <a href="https://dbaney.com">Donovan Baney</a> · <a href="https://x.com/baney75">@baney75</a> · macOS 13 or later</sub>
</p>

<p align="center">
  <img src="docs/shots/overview.jpg" alt="The BaneySpaces overview: nine workspace tiles in a 3×3 grid, each listing its windows by app and title" width="860">
</p>

```sh
curl -fsSL https://raw.githubusercontent.com/baney75/baneyspaces/main/install.sh | bash
```

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

<p align="center">
  <img src="docs/shots/overview-drag.jpg" alt="Dragging a Mail window card onto workspace 6 in the overview; the target tile is outlined" width="760">
</p>

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

Requires macOS 13 Ventura or later, on Apple silicon or Intel. In Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/baney75/baneyspaces/main/install.sh | bash
```

The installer builds BaneySpaces from source with Apple's free command line tools and copies it
to `~/Applications`. If the tools are missing, it opens Apple's installer for them first (about
1 GB, usually 5 to 15 minutes); paste the command again when that finishes. Because the app is
built on your Mac, there is no "unidentified developer" warning. If the build fails, the
installer shows the error and where the full log is.

Prefer to read the source first? Build it yourself:

```sh
git clone https://github.com/baney75/baneyspaces.git
cd baneyspaces
make install
```

<p align="center">
  <img src="docs/shots/setup.jpg" alt="The BaneySpaces setup window" width="420">
</p>

Then a setup window opens. There is one thing you have to do:

1. **Click Allow BaneySpaces.** macOS shows its own prompt and opens Privacy & Security ›
   Accessibility with BaneySpaces already in the list. Turn on its switch and come back.
   Accessibility lets BaneySpaces show, hide and move other apps' windows; it can't read what
   you type.

Setup notices the switch within a moment, says **BaneySpaces is on. Try ⌘2.**, and closes itself.
Everything else is optional and already set sensibly:

- **Your keys.** ⌘ by default, or ⌃, ⌥ or ⌃⌥ with what each one gives up. macOS uses ⌘⇧3, ⌘⇧4
  and ⌘⇧5 for screenshots and claims them first; **Free Them** turns those off so they can move
  windows (⌃⌘⇧3 and ⌃⌘⇧4 still capture to the clipboard), and **Turn Them Back On** undoes it.
- **See every workspace at once.** The Mission Control key and ⌃↑ open the overview, or switch
  that off to keep them for Mission Control.
- **Start with your Mac.** On unless you turn it off. If macOS wants you to approve it, setup
  shows a button that opens Login Items.

If AeroSpace is running, setup shows a **Quit AeroSpace** step, since both want the same keys.
The installer also quits it and turns off its open-at-login setting. AeroSpace stays installed.

Open setup again any time from the menu bar icon, or by opening BaneySpaces from Finder or
Spotlight.

### If the permission won't take

macOS ties the Accessibility switch to the app's signature. If you reinstalled, or the local
signing key had to be replaced, the switch can show on while macOS still says no. Setup spots
this a few seconds after you click Allow and offers **Fix Permission**, which clears the old
entry and asks again. By hand it is:

```sh
tccutil reset Accessibility com.baney.baneyspaces
```

If you turn the permission off while BaneySpaces is running, it brings every hidden window back,
hands the shortcuts back to your other apps and reopens setup.

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
Accessibility grant across rebuilds. The key is only replaced when it is truly unusable, and the
build says so, since a new key means allowing BaneySpaces again (setup's Fix Permission).

## Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/baney75/baneyspaces/main/uninstall.sh | bash
```

BaneySpaces quits first, which brings every hidden window and app back; if it won't quit, the
uninstaller stops without deleting anything. Then it turns the screenshot shortcuts back on if
setup turned them off, and removes the app, its settings, its local signing key and its
Accessibility entry.

## License

MIT. See [LICENSE](LICENSE).
