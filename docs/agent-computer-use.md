# BaneySpaces agent computer use

(For every platform BaneySpaces runs on, see "Every platform" below: Donovan, 2026-11-01, "Baney spaces is for all devices now including Mac, Windows and Linux.")

Decided 2026-10-31 (Donovan): BaneySpaces is the fleet's computer-use layer on the Mac. Cua's driver
and Cua Spaces are removed from every machine. Tabkyra stays the way agents read and act on pages in
Donovan's own Helium tabs. Everything else an agent does in a desktop app, any browser included, goes
through BaneySpaces.

## Why ours can beat both

Every other computer-use tool is a guest on the desktop, or hides from it inside a VM and gives up your
real apps. It has to guess which window is safe to touch,
and it fights whatever manages the windows. On 2026-10-31 that fight was visible: Cua's stock driver
(0.34.1) raised apps on Donovan's workspaces, BaneySpaces followed each activation, and the screen
jumped. BaneySpaces owns workspaces, window placement and focus following, so it can make guarantees
a guest can't:

1. **Agents never take your screen.** Agent windows live on the agent workspace, parked out of view
   but still drivable. No agent action activates an app, raises a window, posts global input or
   changes a Space. If an app activates itself as a side effect (some do on AXPress), BaneySpaces
   does not follow it, holds your keystrokes in a listen-and-hold event tap until your previous front
   app is back (target: within 50 ms), and the action's result reports it; the probe counts it as a
   failure. Apps seen to self-activate are put on a list and refused (`not_supported`) until a route
   that doesn't activate them exists. Nothing an agent does changes your workspace,
   your front app, your pointer or your keyboard focus.
2. **Your workspaces are off limits by default, and the line is drawn by process.** On your Mac an
   agent only acts on a process BaneySpaces started for it as a new instance (`open -n`, its own pid,
   checked against the pids you were already running), or on windows you lend (below). An app that
   can't run a second instance (Finder, Safari, Notes, Mail, Messages, Calendar, Photos, single-instance
   Electron apps such as Obsidian, Office apps you have open) is never driven by an agent on your Mac:
   that work goes to the sandbox, or uses files directly instead of Finder.
3. **Every action is checked.** Each action returns evidence read back from the exact element it
   targeted (its value, state or the accessibility change it caused). A capture of the element's
   region is secondary evidence only, never proof by itself, since a caret or a clock changes pixels
   too.
4. **It refuses instead of guessing.** If no safe route reaches the exact window, the action fails
   with a reason and a suggestion. There is no fallback to global keyboard or mouse input, no app
   activation and no Space change.

## What we take from whom

| From | What | License |
| --- | --- | --- |
| agent-desktop (Vercel Labs) | The observation and semantic-action engine through its C library (`libagent_desktop_ffi`): accessibility snapshots with refs, strict fail-closed ref resolution, the evidence tri-state, partial observation, web-wrapper collapsing, 56 commands. Built from source at a pinned commit with its `Cargo.lock`, never through npm's postinstall. | Apache-2.0, NOTICE kept |
| cua-driver (trycua) | The background-input rules from its `macos-background-input-v1-plan`: every action carries an exact `(pid, CGWindowID)`; routes in order semantic AX, exact browser target, window-local pointer, per-process keys with delivery proof; SkyLight per-process event posting for canvas apps; per-process AX enablement for Electron. Ported to Swift where we need them. | MIT, attributed |
| BaneySpaces | Workspaces, parking, the focus watcher, the agent workspace, the deck, remote (tailnet) and the dock. The part neither of them has. | MIT |

Before the engine goes in, `tools/vet_supply.py` from BaneyFleet runs on the pinned source. Its first
run (2026-10-31, commit 5261b52) came back `ask`: new to the fleet, no release attestations, and three
RustSec advisories with unknown severity in Linux D-Bus crates. Donovan's direction to build on it is
the decision. The build pins the source and runs `scripts/engine-advisories.py`, which checks
`cargo tree --target aarch64-apple-darwin` so a lockfile bump that links an advised crate on macOS
fails the build instead of passing silently.

## Two places for agent work

| | Agent workspace | Sandbox |
| --- | --- | --- |
| What | Workspace 9 on your Mac, with real apps | A throwaway macOS VM (Apple Virtualization, through Tart) |
| For | Apps BaneySpaces starts for the agent as a separate process (a browser with its own profile, `open -n TextEdit` on a temp file), plus windows you lend | Untrusted sites, throwaway logins, long unattended jobs, the once-per-user apps above, anything that installs software, and benchmark runs that need a clean machine |
| Speed | Instant, no VM | Boots in seconds from a warm suspended state; resets to clean by APFS clone |
| Your data | The agent's apps run as your macOS user, so they can open your files: window rules don't protect files. That's why remote callers, untrusted content and anything that installs go to the sandbox | Not there at all: no iCloud, no keychain, no shared folders except one handoff folder per task |
| Network | Yours | Internet only: no LAN, no tailnet, no access to the Mac itself |
| Screen | Its windows live on workspace 9 | Its window lives on workspace 9; you can watch it or never look |

Apple Virtualization allows two macOS guests at once. BaneySpaces runs one sandbox per task; a third
request gets `busy` with `retry: after` and its place in the queue.

The host talks to the guest's hands daemon over a host-initiated vsock channel. Everything that comes
back is untrusted: schema-validated, size-capped, never passed to a shell or AppleScript, and labeled
`guest-asserted` in results. The guest's network is Tart softnet with the host, its gateway, the LAN,
the tailnet and link-local blocked.

`baneyspaces agent` takes `--in sandbox` (or `--in host`, the default), and the router picks the
sandbox by itself for the app classes above. The same commands, refs, evidence and agent cursor work
in both, because the sandbox runs a headless BaneySpaces hands daemon inside the guest. That is what
the VM-only setups (agent-desktop in a VM, posted 2026-10-31) can't do: they give up your real apps
entirely, and you manage the VM window yourself.

## What each place protects against

The agent workspace protects Donovan from accidents: an agent acting on the wrong window, stealing focus, switching his workspace, touching an app he is using, or opening his documents by mistake. It is not a security boundary. Every agent on the Mac runs as his macOS user and can already read his files and run commands, so nothing BaneySpaces does on the host can stop a hostile same-user process (for example one that rewrites BaneySpaces' files under ~/Library or drives an Open panel on purpose). Anything untrusted (web content, downloads, remote callers, code that isn't ours) runs in the sandbox, which is the security boundary.

## Lending

Lending is the only way an agent touches a window you were already using, and only you can do it:

- `lend` and `return` are not agent verbs and not MCP tools. An agent that needs a window gets
  `needs_lend` naming what it wants and why.
- You lend from the menu or the Deck, or a CLI request raises an on-screen confirmation that only real
  input accepts (BaneySpaces checks the click's source pid, so a synthetic click can't accept it).
- A lend names one agent (the requester shown in the confirmation) and the specific windows you
  picked, not the whole app. Windows the app opens later aren't included. Another agent gets
  `needs_lend`.
- It refuses agent actions while the window is in front or you used it in the last 30 s (`in_use`),
  shows a lend badge, and returns when that agent's session ends (its MCP connection closes or its
  `agent run` exits) or after 30 minutes.

## Interface

One command family and one MCP server, the same verbs either way:

```sh
baneyspaces agent snapshot --app TextEdit -i        # refs for what an agent can act on
baneyspaces agent click @s1:e8                      # act on a ref; prints the evidence
baneyspaces agent type @s1:e3 "Hello"               # AX value or insertion
baneyspaces agent press @s1:e3 "cmd+a"              # keys to that one process, window not in front (phase 4)
baneyspaces agent drag --window 4211 --x 60 --y 90 --x2 320 --y2 230   # window-local pointer (phase 4)
baneyspaces agent open TextEdit ~/tmp/notes.txt     # on the agent workspace, you stay put
baneyspaces agent open Safari https://example.com   # routed to the sandbox (once-per-user app)
baneyspaces agent shot --window 4211                # one window, even while parked
baneyspaces agent lend Excel / agent return Excel   # Donovan lends an app (see Lending)
baneyspaces sandbox up | reset | down | status      # the sandbox VM
baneyspaces mcp                                     # stdio MCP server with the same tools
```

Output is one JSON envelope per command: `ok`, `data` or `error` with `code`, `retry` (`safe`,
`after_snapshot`, `never`) and a `suggestion`. `remote` (tailnet, token) exposes the same tools to
other machines, look-and-act in the sandbox only: a remote caller never drives a process on your Mac.

Targets are a ref, a window id, or a pid. An app name resolves only when exactly one matching process
has windows in scope; otherwise the command fails with `ambiguous` and lists the candidates.

## The agent cursor

Donovan asked for it on 2026-10-31: you should see an agent work. Each agent gets a small cursor
of its own, drawn by BaneySpaces in a click-through overlay. It is never the real pointer, and it
never moves yours.

- It glides from its last spot to the target element's center (about 150 ms, eased; instant when
  Reduce Motion is on) while the action runs, and shows what happened: a ripple for a click, a
  caret pulse while typing, a short scroll trail. The action never waits for the glide.
- It carries the agent's name and its status color from the Deck, so two agents on the same
  workspace are told apart.
- It shows on the agent workspace when you look at it, and over a lent app while the agent uses
  it. Anywhere else it stays hidden, and the action still runs.
- It never takes focus, clicks or keys. Screenshots and recordings of the agent workspace can
  include it or leave it out (`agent shot --cursor`), so the evidence in a result is the app
  itself.
- `baneyspaces agent cursor on|theme <name>|status` and a Settings switch. It's on by default. Only Donovan turns it
  off, in Settings: the cursor is how he sees agents work, so the socket refuses `agent cursor off` (and logs it) and
  a `behavior.cursor.enabled = false` line in `config.toml` is ignored. Agents may change its theme.
  This guards the socket and the config file, not the user's other files: BaneySpaces' saved settings (its defaults
  domain) are the user's, and any process of the same user can edit them, as it can any other file of his. That is
  out of scope under the host threat model above (nothing on the host stops a hostile same-user process; the sandbox is
  the boundary). It is not silent: BaneySpaces writes a line to `trace.log` at launch when the saved setting is off.

The bench measures it too: drawing the cursor must add under 5 ms to the median action.

## Browsers

All of them, without taking the screen:

- **Chromium family** (Helium, Chrome, Edge, Brave, Arc, Electron apps): per-process
  `AXManualAccessibility` so the page tree is real, refs into page content. A browser BaneySpaces
  starts for an agent is its own process with its own profile (`--user-data-dir` under BaneySpaces'
  agent folder), so it never shares a process with yours, and page actions go over
  `--remote-debugging-pipe`, never a TCP port another local process could reach. Donovan's
  signed-in profiles are never opened with DevTools.
- **Safari**: one process per user, so agent Safari work runs in the sandbox.
- **Firefox**: `accessibility.force_enabled` in the agent profile, then the same tree.
- **Helium tabs Donovan is using**: Tabkyra, as today.

## Phases

| Phase | Ships | Done when |
| --- | --- | --- |
| 1 | Engine linked in; `agent windows/snapshot/find/get/click/type/set-value/press/scroll/select/toggle/shot/open/lend/return`; MCP server; focus guard; `type` through AX only (keys refuse with `not_supported` until phase 3). | `scripts/agent-hands-probe.swift`: 200 actions in TextEdit on temp documents and Finder inside a temp folder on the agent workspace, watching events for the whole run (app activation, Space and workspace changes, focused-window changes, any window appearing on another workspace) with a 50 ms sampler as a second check; zero events. Every driven pid is one BaneySpaces started (`open -n`). Fleet routing points desktop work at `baneyspaces mcp` when phase 1 merges; until then desktop tasks report "not available". Never Notes or any once-per-user app. Plus `swift test`. |
| 1b | The agent cursor. | Visible on the agent workspace during the probe, zero changes to the real pointer, under 5 ms added per action. |
| 2 | The sandbox (two at most; `busy` beyond that): `sandbox up/reset/down/status`, the guest hands daemon, routing of once-per-user and untrusted work, the handoff folder, network limited to the internet. | The probe passes inside the sandbox; a sandbox job can't reach the Mac, the LAN or the tailnet (checked from inside); reset returns a clean guest in under 10 s; a malformed or oversized daemon reply is rejected; the guest can't reach the host gateway; the sandbox window never appears on your workspaces. |
| 3 | Browsers and Electron: agent browser profiles over the debugging pipe, Safari and Firefox in the sandbox. | A page form filled and read back in Helium and Chrome (agent profiles on the host), and in Firefox, Safari and Obsidian with a scratch vault (all three in the sandbox), with zero screen-change events. |
| 4 | Window-local pointer and per-process keys (SkyLight) for apps without a usable tree; the refusal contract. See "Phase 4: keys and pointer" below. | A canvas app drawn on from behind with zero changes; every refused route returns a suggestion. `scripts/agent-keys-probe.swift`: TextEdit keys (⌘A, ⌘B, Return, menu-free keys) with another app in front, the bench tasks marked phase 4 that the routes can run, and a canvas stroke checked by pixels; 50 ms sampler on the front app, workspace, real pointer and key window; zero changes. Plus `swift test`. |
| 5 | Head-to-head (`bench/`): the same 30 tasks through BaneySpaces, agent-desktop and ChatGPT's computer use, each run in the same place (all on the agent workspace where the task allows it, all in the sandbox otherwise), scored on success, screen changes, time and turns. Cua's driver is a column only inside the sandbox. Fleet routing switches to BaneySpaces' MCP. | BaneySpaces is best or tied on every column; the numbers and the tool versions are committed under `bench/results/`, and the ratchet blocks any regression. |

## Every platform

Donovan, 2026-11-01: BaneySpaces runs on the Mac, Windows and Linux; on Omarchy it is the default
window manager layer (Hyprland stays the compositor, BaneySpaces owns everything you interact with);
nightly builds ship for every platform; it gets tested on every platform before it's called done.

| | macOS | Linux (Omarchy, Hyprland) | Windows 11 |
| --- | --- | --- | --- |
| One shared set of nine workspaces, each display shows one, instant | This app (parking, AX) | Hyprland workspaces 1–9 driven over its IPC socket: one shared set, each display shows one (a workspace another display shows takes you to that display), no animations | Our own workspace model: windows of other workspaces are cloaked or minimized without animation; Windows' virtual desktops are not used (they animate and are tied to one display) |
| Agent workspace | Workspace 9, parked | A Hyprland special workspace, never shown unless you open it | Workspace 9, cloaked |
| Focus following and its guard | FocusWatcher | Hyprland `activewindow` events | `SetWinEventHook(EVENT_SYSTEM_FOREGROUND)` |
| Workspace Dock, launcher, ⌘Tab bar, overview | SwiftUI/AppKit | Omarchy shell (Quickshell) plugins, so they match Omarchy's look | Native overlay windows (Rust, `windows` crate) |
| Agent hands | agent-desktop engine through its C library | agent-desktop's Linux adapter (AT-SPI) linked as a Rust crate | agent-desktop's Windows adapter (UI Automation) linked as a Rust crate |
| Sandbox | Tart macOS VM | A KVM VM (libvirt) | Hyper-V or Windows Sandbox |
| Keys | ⌘1–9, ⌘⇧1–9 | Super+1–9, Super+Shift+1–9 (Omarchy's own bindings are rebound to BaneySpaces) | Win+1–9 is taken by the taskbar; Alt+1–9 and Alt+Shift+1–9 by default, changeable |

One contract keeps them the same product: `spec/` in this repo holds the workspace rules, the key map,
the CLI and MCP schemas (one JSON envelope everywhere) and conformance cases as JSON. Every platform's
test suite runs the same cases. A behavior that isn't in `spec/` doesn't ship on one platform alone.

Code layout: `Sources/` stays the macOS app; `crates/baneyspaces-core` (Rust) holds the shared
workspace model, CLI/MCP and hands routing for Linux and Windows; `platforms/linux` and
`platforms/windows` hold each shell; `spec/` is shared.

Testing on every platform: Linux runs in a nested Hyprland session (`Hyprland` inside a headless
output) in CI and on Parish1, then live on Chapel1 and Parish1; Windows runs in a Windows 11 VM on
Parish1 (KVM, resettable, never on GIGAPC); macOS on the Mac (and the Mac mini node when it has a
key). Each platform runs the hands probe and the bench in the same shape.

Nightly: one workflow builds all three every night from `main` into a `nightly` prerelease (signed
where the platform has signing), and each app's updater offers the nightly channel.

## Phase 4: keys and pointer

Verbs: `press <ref> <keys>` (several keys separated by spaces), `click-at` and `drag` (window id and window-local
points, from the window's top-left corner). They reach one process that is not in front. They never activate,
raise, switch a Space, move the real pointer or post to the session or a HID tap. Source tests read the one file
that makes events (`BackgroundPoster.swift`) and fail if it names any of those.

| Order | Route | Used for | Needs |
| --- | --- | --- | --- |
| 1 | Semantic accessibility (`click`, `type`, `set-value`, `toggle`, `select`) | everything with an element | the tree; phase 1 |
| 2 | Exact browser target | page content | phase 3 |
| 3 | Window-local pointer (`click-at`, `drag`): mouse events to the pid, the window number in fields 51, 91 and 92, the pid in field 40, one gesture id, the point in window-local screen terms | surfaces with no tree (a canvas) | the pid is the agent's; the window is not minimized or hidden; the point is inside it; a verifier (the tree or the window's pixels) |
| 4 | Per-process keys (`press`): key down and up with exactly the chord's flags, to the pid | shortcuts and keys no element exposes | the pid is the agent's; no other window of that process could take the key; the app's focused window and focused element are this window; the tree is readable |
| 5 | SkyLight per-process posting | the transport under 3 and 4 | `SLEventPostToPid` found by name at run time; if the name does not resolve the public `CGEventPostToPid` carries the event, and with neither the route is unavailable (a refusal, never a crash) |
| 6 | Per-process AX enablement for Electron | Electron apps | phase 3 |

One transport per action, chosen before the post; there is no second route after a post whose proof failed.

Who receives events, checked at execution time on the process's queue, not when the request is parsed:
a window on the agent workspace of a process BaneySpaces started (pid and start time, so a reused pid
fails), or a window Donovan lent, and only while he is not using the app. The window server must still say
the window belongs to that pid. Any other pid is never posted to.

One action per process at a time: the whole action (readings before, the post, the readings after) is one
transaction on the target process's queue, the one the engine's calls use, so another action's change can
never prove this one. The engine's reads inside it are inline calls that refuse to run off the queue.

Balanced events: a stop (the caller gave up, the front app changed, an event could not be made) means "post
nothing new", and every key-down and mouse-down already posted gets its matching up, newest first, before the
action returns. A release is never subject to the stop. `EventRunner` does this for keys and the pointer alike,
and its tests stop a chord, a click and a drag at every step.

Delivery proof: the same window is read before and after (the window's tree twice before, a moment apart; an
element that changes by itself between them, found by its place in the tree and not by its text, is noise for good,
whatever it reads later). A key press is proved step by step: consecutive printable keys are one typed segment whose
own text must appear in the element it was typed into, and every other chord is a step of its own. Each step passes
only when what it predicts changed, in the target window: typed text changes the value of the targeted or focused
element, a movement or select-all changes its selected range, Tab moves focus, cmd+b changes the text's attributes
(compared as normalized runs of font and color components, never object descriptions), Return changes the value or
the window, a save changes the window (title, edited flag, sheet), and in an app with no text element in focus
(Calculator) the window's content changes beyond the noise. The first step that shows nothing stops the press and the
answer says how many landed (`unverified`, "2 of 3 steps landed"); the steps after it are not sent. An unrelated
change does not count. A reading from another window of the same process never counts. Pixels never
prove keys. A pointer is proved by a change on an element of the target window, or, for a surface that exposes
nothing, by pixels: the pointer arrives first (a move), the picture before is taken after that, the pixels around
the start point are left out of a drag, and the stroke needs changed pixels in proportion to its length (never
under 24) while at most 2% of the rest of the window changes. No proof is `unverified` with retry `never`: the
events may have landed.

Guards while posting: every app the workspace activates is recorded (`didActivateApplicationNotification`) from
planning until a second after the last post, and the front app is looked at synchronously before every step; either
seeing a change stops posting (releases still balanced). Any activation in the span, the target's or another's, fails
the action. If the target came forward and a hardware event was heard in the span it was Donovan (`user_activated`,
`in_use`): the action stops and the route is not blamed. If a tap was listening and heard no hardware, the app is shut
out of the route for the run; if nothing was listening, only that process is. BaneySpaces does not follow any of
them. A front app that cannot be read is not a pass. The real pointer is Donovan's: a listen-only session tap runs
during the action, and the check fails only when the pointer ends where an event was aimed, or moved with no hardware
event to explain it, or one of BaneySpaces' own events reached the session. His hand moving the mouse is ignored
(`pointer: user_moved`). The tap is made only when Input Monitoring is already granted (checked without asking);
otherwise the pointer's own position and the system's idle clock stand in, and the result says `pointer_check:
idle_fallback`. BaneySpaces never puts a permission prompt on the screen for an agent action.

Refusals, each with a suggestion: not our process (`needs_lend`), window moved to another process
(`stale_ref`), Donovan is in the app (`in_use`), minimized or hidden window, a sheet or file panel, other windows
in the process (windows accessibility cannot map count too), window is not where the app's keys go, a focused element
that cannot be placed in any window, no accessibility window for it, no transport, a pointer recipe with any setter missing, a point outside the window or
in its title bar, nothing readable to prove it (all `not_supported` except as named). Coordinates start at the
window's top-left corner, title bar included.

The probe's test app ships inside the bundle (Resources/probe), signed with the app's own identity, with its code
hash recorded in the sealed Resources at build time. BaneySpaces starts it for an agent only from there and only
when the signature is valid, the team matches (when there is one) and the hash matches.

Ported from cua-driver (MIT, trycua/cua, attributed in NOTICE): the event field recipe for background mouse
events, key events with explicit flags posted without an authentication envelope (the path AppKit's menu key
equivalents see), the dlsym-with-fallback shape of the SkyLight bridge, and the rule that a key can only be
proved against the target window, never the process's focused element. Not ported: the in-app key-window
records (`SLPSPostEventRecordTo`) and no-raise activation, because they change which window is key or front;
here a window that is not already where the app's keys go is refused.

Not proved live yet: see the pull request. The unit tests prove the decisions; only the probe proves events land.

## Rules that do not bend

- No global HID events from agent actions, ever. The only synthetic input on Donovan's Mac comes from
  BaneySpaces' own probes (`scripts/*-probe.swift`), only after 10 idle minutes, and each probe aborts
  the moment a listen-only event tap sees an event whose source isn't the probe's own pid.
- No `activate`, `SetFrontProcess` or Space change on behalf of an agent.
- No action on a window outside the agent workspace unless that app is lent.
- Snapshots and captures can hold private content, and an MCP caller is a model whose provider sees
  every result. So results only ever come from the agent workspace, the sandbox or a lent app, never
  from your workspaces; captures are returned only when the caller asks for one; and no snapshot text
  or capture goes into a log. Every action does leave a record without content (agent id, verb, pid,
  window id, ref, route, result code, refusal reason), kept 30 days, so you can see who did what.
