# Changelog

## Unreleased

- **Change the colors and looks in Settings › Appearance.** Pick an accent (nine colors, System
  to follow macOS, or any color you choose), a palette for the nine workspace colors (Rainbow,
  Accent, Calm or Mono) and a color of your own for any one workspace, a panel style (Glass,
  Tinted or Solid) with an opacity slider, and a Small, Medium or Large Workspace Dock. It applies
  to the dock, ⌘Tab, the launcher, the overview and the switch overlay as you change it, and a
  strip at the top of the tab previews it. A workspace color that's too bright for the white
  numbers is dimmed. The defaults are the look it has always had.
- **The Deck sidebar is gone; the launcher is the one search.** The sidebar, its switcher, its
  window layouts (stack, split, free, tile) and docking, the left-edge trigger, the back and
  forward keys and the Deck setting and menu item are removed. **⌃⌘K** now opens the launcher
  from any app, and the launcher finds terminal tabs and splits, browser tabs, agent windows and
  files. **New Claude Session** and **New Terminal** are launcher commands. Agent badges stay on
  the Workspace Dock, the notice when an agent finishes and **⌃⌘U** (now from any app) still work,
  and so do the `baneyspaces` command and phones. Agent tracking is always on now; it has no
  setting of its own. If you kept the sidebar pinned, the windows beside it keep the size they
  had; widen them once. The command's `layout`, `tile`, `sidebar` and `palette`
  subcommands are gone. The Install Hooks button moved to the Dock tab in setup. A phone's shell
  and screenshot are in the command (`baneyspaces phone shell`, `baneyspaces phone shot`), and **New
  Terminal** opens in the folder of the terminal you were in.
- **Install and update without building.** A stable release now carries the finished, signed app,
  so the one-line install and the updater download a few MB instead of building on your Mac,
  and need no command line tools. The installer checks the app against BaneySpaces' release key
  and refuses anything else. Browser users get `BaneySpaces.dmg` with the drag-to-Applications
  window; the first open needs **System Settings › Privacy & Security › Open Anyway**, because
  BaneySpaces isn't notarized. The Nightly build and older releases still build from source, and so does an update of a copy
  you built yourself (while the command line tools are installed), so macOS keeps its
  Accessibility permission.
- **Each display shows a workspace of its own.** With a second monitor or Sidecar, ⌘3 used to
  change what every screen showed. Now it changes only the display you're on: the one you last
  clicked, anywhere on it (a window, the desktop, the Workspace Dock or the overview), or whose
  window you switched to. The other keeps its workspace and its windows. Press the
  number of the workspace the other display shows and you go there instead, as in AeroSpace.
  Drag a window onto the other display and it joins that display's workspace. A display you
  plug in starts on an empty workspace, and the switch overlay shows on the display that
  switched. With one display nothing changes.
- **Find files from the launcher.** Type a name and the best five matching files and folders come
  in under the apps, from your home folder, iCloud Drive and other cloud drives; Tab into the new
  **Files** menu for more. Every word you type must start a word of the name, so `tax 2025` finds
  `2025 Tax Return.pdf`. Return opens it, ⌘Return shows it in Finder. Files you opened lately
  come first, and Library, hidden and build folders stay out of the way. It asks Spotlight: most
  searches take a tenth of a second, a common two-letter one up to half a second. macOS may ask
  once to let BaneySpaces see your Documents, Desktop, Downloads or iCloud Drive.
- **Dragging a window to the top fills the screen again.** Since the overview took over that
  drag, BaneySpaces had also switched off macOS's "Drag windows to menu bar to fill screen", so
  letting go at the top did nothing. It's back on, turned on once for you if BaneySpaces had
  turned it off. Let go at the top and the window fills the screen, even with the overview up;
  let go over a workspace and it moves there. Only Mission Control stays off for that drag.
- **An agent's spinner on the dock no longer stays stuck.** Every Claude session inside T3 Code
  reports to T3's one window, but the first session to claim it kept it for good, so a turn you
  stopped (which sends no hook) left the spinner turning for up to six hours while your other
  sessions finished. Now the window shows all of them: a question first, then any session still
  working, else the latest. A turn stopped without a hook stops counting as work after 15 minutes,
  and the spinner clears then unless another session is still working. In a terminal, Claude's own
  idle title wins after 5 seconds. The spinner itself now turns in Core Animation, so it can't freeze mid-turn
  when the dock hides and comes back.
- **New Claude, front and center, and quicker.** The Deck's toolbar led with three identical gray
  icons. Now "New Claude" leads in Claude's orange, with Tile and New Terminal as small buttons
  beside it, and every button gives under the press. The session still tiles into your Claude
  window the way ⌘⇧A does, sharing its state, but through a script BaneySpaces compiled once.
  Running `claude-desk` cost a shell, an `osascript` launch and a fresh compile, about 160 to 220 ms,
  on every press. Until the pane is up the button reads "Opening…", the sidebar stays, and a
  second press waits.
- **Drag a window down to the dock to move it to another workspace.** Pulling a window by its
  title bar to the bottom edge used to do nothing: the dock stayed down while the button was held.
  Now it comes up for the window, the tile under the pointer lights, and the label says where it's
  going. Let go on a tile, or on the dashed one for an empty workspace, and the window moves there,
  back in the spot you picked it up from; you stay where you are. Let go anywhere else and it stays
  where you dropped it. This needs the dock on the bottom edge: at the top the drag opens the
  overview, and at the sides macOS tiles the window to half the screen.
- **The dock comes up from the edge again.** It waits while another app's menu is open, but it
  counted any menu-level window anywhere on screen, and macOS sometimes leaves an empty one
  under the menu bar for hours. Now only a menu near the pointer that came up in the last 30 seconds
  holds it back.
- **Drag a window to the top of the screen and the overview opens, not Mission Control.**
  Pulling a window up against the menu bar used to throw you into macOS's Mission Control.
  Now, after a quarter second at the top, BaneySpaces' own 3×3 overview opens with the window's
  card under your pointer. Let go over a workspace and the window goes there, back in the spot
  you picked it up from; let go anywhere else and it stays where you dropped it. macOS's own
  answers to that drag (Mission Control and fill-the-screen) stay off while it's on. Their
  settings are saved first and put back when you turn it off in **Settings › Keys** or uninstall.
- **Arrow keys in the overview.** The arrows move the highlight from workspace to workspace in
  the 3×3 grid, and Return goes there, so you can pick one without the mouse or a number key.
- **Dock tiles stay put under the pointer.** Hovering a tile could slide it sideways over the
  tile beside it or the "+", because the grow-on-hover spring also animated the dock re-centering
  itself as the label above it changed width. Now hover only grows the tile, icon or button.
- **Drag a file to the dock to drop it in a window on another workspace.** The Workspace Dock
  used to stay down while a mouse button was held, so a file, link or image dragged from Finder or
  a browser couldn't reach it. Now it comes up for the drag. Hold over an app's icon and that app's
  window there comes forward; hold over a tile and you go to that workspace. Then carry the file
  up into the window and let go. Drop on an app's icon and the app opens the file or link, when
  it's one that app can open, as in the macOS Dock.
- **The dock says which app an agent is working in.** The blue dot on a tile meant a coding
  agent was at work on that workspace, but it looked like an unread badge and didn't say where.
  Now a small turning ring sits on the icon of the app the agent runs in (Ghostty, T3 Code), the
  hover label names it ("Claude working: Fix the flaky upload test"), and its window is marked
  in the window strip. An app with an agent is never hidden behind a tile's "+N".
- **A finished agent is one click away.** Click the orange count on a tile, or the app's icon,
  and you land on the agent's own window instead of the app's last one.
- **Shorter menus.** The menu bar menu lists only the workspaces in use, the one you're on and
  one empty workspace, and shortens a long app list ("Helium, Ghostty, Obsidian +2"). The
  switches, Keep Usable by Automation and Bring Every Window Back moved under **Options**;
  **Check for Updates** lives in the **Updates** submenu unless an update is waiting. The Deck's
  submenu shows its real shortcuts and groups its layouts.
- **Shorter dock menus.** Right-click an app in the Workspace Dock for Show and Quit; hold ⌥ and
  Quit becomes Force Quit, as in the macOS Dock. A tile offers Go to and Move Front Window Here.
  Position and Turn Off sit in one **Dock** submenu, and the menu no longer repeats the dock's
  own buttons.
- **See every app on a full tile.** Rest on a tile's "+2" (or click it) and the apps it stands
  for open in a list over the tile; click one to go straight to it.
- **A lighter dock.** The launcher and overview buttons share one tile's room, so the workspaces
  carry the bar, and the hover label says only what the icon can't.
- **BaneySpaces stops crashing while the Workspace Dock is up.** When the dock's label or window
  strip made it wider, SwiftUI and the dock both resized its window inside one layout pass, and
  macOS gave up and quit the app. The dock now resizes itself just after the layout settles.
- **The Deck: every terminal, browser tab and agent window in one sidebar.** Ghostdeck is now
  part of BaneySpaces. Ghostty splits and tabs, Helium and other Chromium tabs, Terminal and
  iTerm2 sessions, and the Claude, ChatGPT, T3 Code and Grok Bot windows each get a row with
  their folder and whether an agent there is working, waiting or done. ⌃⌘K finds any of them,
  ⌃⌘[ and ⌃⌘] go back and forth, and Deck rows show up in the launcher. Stack, Split and Free
  arrange the window you pick next to the sidebar. Ghostdeck.app goes to the Trash on install.
- **Agents tell you when they're done.** `baneyspaces hooks install` adds Claude Code and Grok
  hooks. A finished or waiting agent gets a toast and a badge on its Workspace Dock tile, and
  the row it ran in lights up.
- **An agent workspace.** `baneyspaces agent on 9` gives agents and Cua a workspace of their own.
  Its apps are parked instead of hidden so background clicks still land, nothing on it ever pulls
  you there, and a window an agent opens from behind joins it instead of yours. `agent run`
  starts a command there in a Terminal window of its own; `agent open` opens a file or app there.
- **Phones in the Deck.** Android over adb (`baneyspaces phone tap|type|swipe|ui|shot`) and
  iPhones through devicectl and iPhone Mirroring.
- **Remote machines, off by default.** `baneyspaces remote on` lets another Mac on your tailnet
  give this one's agent workspace work, with a token. It listens only on the tailnet address and
  can't focus, type into or move anything you see.
- `baneyspaces` is a command-line tool too (`ls`, `focus`, `send`, `notify`, `agent`, `phone`,
  `remote`, `doctor`), and a Claude Code skill teaches agents to use it.

- **Apps come forward again.** Ghostty, and some other apps, keep a window alive after you
  close it, and a tab behind another tab looks the same. BaneySpaces kept those on their
  workspace for good, so ⌘Tab, the Dock and the launcher sent you to a workspace (Ghostty "on
  workspace 2") and picked a window that couldn't come forward. They leave the workspaces now,
  and a tab that comes forward again lands where its window is.
- **Quit and Force Quit from the Workspace Dock.** Right-click an app's icon.
- **Windows no longer slide to the corner.** An app split across workspaces (Ghostty with
  windows on two) had its other windows glide across the screen on every switch, because apps
  with the accessibility setting AXEnhancedUserInterface on animate every move. It's off for
  the moment of each move now, and the move is instant. Switches with one went from about 300 ms
  to under 100.
- Going to an empty workspace no longer bounces you back. macOS hands focus to some other app
  when the one in front hides, and BaneySpaces had been following it.
- Opening an app here that's open on another workspace opens it here. The launcher opens a new
  window of it on the workspace you're on (a row still goes to its other workspace), and a new
  window an app makes right after coming forward (Ghostty's global New Window key) stays here.
- **Start Claude Code or Codex from the launcher.** Type `claude` or `codex` and Return opens it
  in your terminal (Ghostty, iTerm2, WezTerm or Warp before Terminal), in your home folder.
  Only agents installed on this Mac are offered.
- The Workspace Dock's ring around the hovered icon now traces the icon itself instead of a box
  around it, so it no longer runs into the tile's edge.
- **Drag windows between workspaces in the Workspace Dock.** Drag an app's icon onto another
  tile and its windows on that workspace move there; drag a window out of the strip to move just
  that one. The tile it will land on lights up in its color, and dropping on the dashed tile
  sends it to the first empty workspace. You stay on the workspace you're on.
- **The Workspace Dock can sit on any side:** bottom, left, right or top, from setup, the menu
  bar menu, or a tile's right-click menu. It opens when the pointer rests on that edge under it,
  the label and window strip open on its inner side, and a dock too long for the screen shrinks
  to fit. At the top it sits under the menu bar and waits half a second, and never opens from
  the corners, so reaching for a menu doesn't bring it up.
- Holding Tab in ⌘Tab now takes 0.6 s; a slow tap in the window bar no longer drops back to
  the apps.
- Holding Tab stays on the highlighted app and opens its windows. A Tab press now steps when
  you let it go, so a hold never jumps to the next app and back.

- **Bangs, web search and agents in the launcher.** `!yt cats`, `!i sunsets`, `cats !yt`, and
  about 35 more built in; any other bang goes to DuckDuckGo. Plain words offer your search
  engine, images and your agent; `?` asks your agent (Claude, ChatGPT, Perplexity, Grok,
  Copilot or Le Chat, picked in setup) in a new browser tab with the question filled in.
  Add your own bangs in setup, or from a script or agent with `BaneySpaces --bangs add`.

- **Pick a window, not just an app.** In ⌘Tab, hold Tab on an app with more than one window to
  open its window bar: every window of that app, on any workspace, labeled with its title (a
  browser's tab, a player's video) and its workspace color. Tab through it and let go of ⌘ to go
  to that window; hold Tab again to go back to the apps.
- The switch HUD is redrawn: solid glass, the workspace you went to filled in its color with its
  number, workspaces with windows lit, and its apps underneath.
- The Workspace Dock appears only when the pointer rests on the bottom edge under it, and a
  pointer parked on the edge beside it no longer makes it pop up and down.
- In the Workspace Dock, rest the pointer on an app with more than one window and a strip of its
  windows opens over it, each labeled with its title. Click one to go to it.

- **Launcher** (menu bar menu, the Workspace Dock, or ⌘Space if you choose): one box to open,
  find, install, update and remove apps. Type to search apps, commands and workspaces at once,
  or Tab into a menu: Apps, Install, Remove, Update, System, Workspaces. Install searches
  Homebrew's full app list and the Mac App Store, installs a Homebrew app in the background and
  says when it's done; an installer that wants your password finishes in Terminal. Picking an app
  that's already open goes to the workspace it's on. Setup's **⌘Space opens the BaneySpaces
  launcher** switch takes ⌘Space from Spotlight and gives it back when turned off, when
  BaneySpaces quits, and in the uninstaller.
- **⌘Tab across workspaces.** Setup's ⌘Tab choice is now macOS, Apps on every workspace, or
  Workspaces. Apps steps through every app with a window, most recently used first, each marked
  with its workspace number; let go and you land on that app's window wherever it is.
- **Apps open on more than one workspace.** Every workspace has its own color, used the same in
  the dock, ⌘Tab and the launcher. An app with windows on two workspaces shows once for each in
  ⌘Tab, tinted in that workspace's color; hovering it in the dock rings its copy on the other
  workspace and says where else it is; the launcher lists a row for each workspace. Clicking an
  app with several windows in a dock tile steps through them, one dot per window.
- Picking an app on the workspace you're on (dock, ⌘Tab, launcher) brings it forward. Before,
  focus went back to the app you were in.
- Installing from the launcher asks first, the same as removing. A launcher opened by a link
  doesn't take the keyboard until clicked.
- **Workspace Dock, redrawn.** Click any app icon in a tile to go straight to that app; click
  the tile around it to go to the workspace. Numbers sit under the tiles, the current one lit,
  and a dashed tile goes to the first empty workspace. A search button opens the launcher.

- **Workspace Dock** (optional, in setup and the menu bar menu): a dock of your workspaces in
  place of the macOS Dock. It slides up when the pointer rests on the bottom edge, shows each
  workspace in use with its apps, and switches with a click; right-click sends the front window
  there. The macOS Dock's own settings are saved and restored exactly when it's turned off or
  BaneySpaces quits, and after a crash by the next launch or the uninstaller.

## 0.2.2 (2026-10-11)

- **Updates from the menu bar, Stable or Nightly.** BaneySpaces checks once a day (or on
  request) and offers a newer build with its release notes; it installs only when you press
  Update Now, keeps running if the build fails, and shows what changed after it restarts.
  Nightly builds are published automatically each night `main` changed, and stable releases
  when a version is tagged, with notes written from this changelog and the commit history.
- **Keep Usable by Automation** (menu bar menu): apps on this list are never hidden whole.
  Their windows on other workspaces are parked out of view instead, because macOS refuses
  background clicks and keys to a hidden app, which cut off tools like Cua. Cua Spaces is on the
  list by default, so its picture-in-picture window no longer disappears on a switch. A window
  automation opens in a parked app joins that app's workspace instead of yours.
- Nothing slides across the screen when windows are parked. Parking happens behind the windows
  of the workspace you go to, and windows come back behind the ones you leave. An app that
  animates its window moves (Chromium browsers like Helium take a quarter second) is noticed
  once and hidden instead, even on the Keep Usable by Automation list; its menu entry says so.
- Switching workspaces no longer jumps to a parked app's workspace. Hiding the app you left made
  macOS bring the parked app forward, its window sliding out of the corner, and BaneySpaces took
  that as you picking it.
- A full-screen window that refuses to leave full screen no longer takes focus on every switch.
- `trace.log` records each ⌘Tab gesture (shown, committed, cancelled, passed to macOS) to help
  diagnose the switcher. It never records other keys.

## 0.2.1 (2026-10-11)

Full screen that stays put, and fixes from a second adversarial review, focused on apps that
are slow to answer.

- **Full screen stays full screen.** YouTube, slideshows and anything else you put in full screen
  stay there; BaneySpaces used to pull every window back out within a second. Switching
  workspaces takes it out of full screen first, however you switch (keys, ⌘Tab, the Dock, the
  overview), and macOS puts it back where it was. Works with the full screen below a camera notch.
- **Two windows of one app on different workspaces work.** Clicking the app in the Dock or ⌘Tab
  keeps you on the workspace you're on when it has a window there; picking its other window
  yourself (Window menu, ⌘`) takes you to that window's workspace.
- **A window that's slow to answer keeps its workspace** across a restart instead of being
  forgotten; its app comes back when you go to its workspace.
- **A busy app no longer stalls a switch.** Raising a window waits at most 0.1 s per call and
  stops at the first timeout, instead of up to 0.75 s; a missed raise is retried a moment later.
- **Closing or minimizing a window keeps you where you are,** even when the app's next window
  lives on another workspace, and even when the app only hid the window it "closed".
- **⌘Q and ⌘W can't reach the app in front while the ⌘Tab switcher is open.**
- An app that comes forward late after a switch no longer bounces you to its other workspace.
- **No window is left parked off screen** after a permission hiccup; Bring Every Window Back also
  rescues windows another tool stranded.
- Saved windows only come back to the app that owned them, a late window doesn't steal a
  workspace's remembered focus, and frozen apps aren't asked again on every scan.
- `state.json` lists apps that aren't answering (`unsure`) and saved windows still waiting for
  theirs (`waiting`).

## 0.2.0 (2026-10-10)

Faster switching, an easier first run, and fixes from an adversarial review.

- **Switching is about six times faster.** A switch that changes nothing on screen dropped from a
  91 ms median to about 15 ms; a real switch takes 20–50 ms. Background apps hide at once, only
  the app in front waits for focus to move (checked every 10 ms), the window scan is skipped when
  no window opened or closed, apps are asked in parallel, and apps with no windows aren't asked
  at all. `make bench` fails if the median goes over 40 ms.
- **Workspaces survive restarts.** Which window lives on which workspace is saved on every
  change and restored when BaneySpaces starts again (an update, a crash, logging back in), so
  nothing gets sent back to workspace 1.
- **⌘Tab can switch workspaces** (optional, in setup): hold ⌘ and tap Tab to step through the
  workspaces that have windows, most recent first; release to go there.
- **A small HUD** shows the workspace grid for half a second on every keyboard switch, and the
  menu bar number changes the moment you press the key.
- **Setup is one button.** Allow BaneySpaces puts it in the Accessibility list and opens the
  right page; setup notices the switch within a quarter second, confirms, and closes itself.
  Fix Permission repairs a permission macOS kept from an older copy.
- **Losing permission is safe.** BaneySpaces gives your keys back, shows every window and app,
  and starts again when permission returns.
- Typing can no longer land in a hidden window after ⌘W or ⌘` moves focus inside an app.
- Rapid presses land on the last workspace pressed instead of replaying each one.
- A hung app is skipped for 5 seconds instead of stalling every switch; a window that refuses to
  leave full screen is no longer asked again on every desktop change.
- Display changes keep focus where it is. Restores move a window without resizing it.
- AeroSpace, Login Items approval and freed screenshot shortcuts are handled in setup, and the
  uninstaller turns the shortcuts back on and clears the permission.

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
