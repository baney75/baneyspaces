# BaneySpaces agent computer use

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
   does not follow it, puts your previous front app back before the next frame, and the action's
   result reports it; the probe counts it as a failure. Nothing an agent does changes your workspace,
   your front app, your pointer or your keyboard focus.
2. **Your workspaces and your data are off limits by default.** An agent acts only on windows on the
   agent workspace or in the sandbox, or on an app you lend (below). Apps that exist once per user
   and hold your data (Safari, Notes, Mail, Messages, Calendar, Photos, Excel and Word documents you
   have open) are never opened by an agent on your Mac: that work goes to the sandbox unless you lend
   the app.
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
| For | Apps an agent can run its own copy of: a separate browser profile, TextEdit or Pages on a temp file, Finder in a temp folder, Xcode on a scratch checkout, any app you lend | Untrusted sites, throwaway logins, long unattended jobs, the once-per-user apps above, anything that installs software, and benchmark runs that need a clean machine |
| Speed | Instant, no VM | Boots in seconds from a warm suspended state; resets to clean by APFS clone |
| Your data | Never touched unless you lend an app | Not there at all: no iCloud, no keychain, no shared folders except one handoff folder per task |
| Network | Yours | Internet only: no LAN, no tailnet, no access to the Mac itself |
| Screen | Its windows live on workspace 9 | Its window lives on workspace 9; you can watch it or never look |

`baneyspaces agent` takes `--in sandbox` (or `--in host`, the default), and the router picks the
sandbox by itself for the app classes above. The same commands, refs, evidence and agent cursor work
in both, because the sandbox runs a headless BaneySpaces hands daemon inside the guest. That is what
the VM-only setups (agent-desktop in a VM, posted 2026-10-31) can't do: they give up your real apps
entirely, and you manage the VM window yourself.

## Lending

`agent lend <app>` is a command only Donovan runs (from the menu, the Deck, or a terminal he types
in); an agent can ask for a lend and gets `needs_lend` with a suggestion. A lent app:

- is named by pid and window ids at lend time, not by name, so a second instance can't be confused
  with it;
- refuses agent actions while it is your front app or you used it in the last 30 s, with code
  `in_use`;
- shows a small lend badge on its Dock tile and in the menu, and returns by itself when the agent's
  session ends or after 30 minutes, whichever is first.

## Interface

One command family and one MCP server, the same verbs either way:

```sh
baneyspaces agent snapshot --app TextEdit -i        # refs for what an agent can act on
baneyspaces agent click @s1:e8                      # act on a ref; prints the evidence
baneyspaces agent type @s1:e3 "Hello"               # AX value or insertion; keys only from phase 3
baneyspaces agent open TextEdit ~/tmp/notes.txt     # on the agent workspace, you stay put
baneyspaces agent open Safari https://example.com   # routed to the sandbox (once-per-user app)
baneyspaces agent shot --window 4211                # one window, even while parked
baneyspaces agent lend Excel / agent return Excel   # Donovan lends an app (see Lending)
baneyspaces sandbox up | reset | down | status      # the sandbox VM
baneyspaces mcp                                     # stdio MCP server with the same tools
```

Output is one JSON envelope per command: `ok`, `data` or `error` with `code`, `retry` (`safe`,
`after_snapshot`, `never`) and a `suggestion`. `remote` (tailnet, token) exposes the same tools to
other machines, look-and-act on the agent workspace and the sandbox only.

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
- `baneyspaces agent cursor on|off|theme <name>` and a Settings switch. It's on by default.

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
| 1 | Engine linked in; `agent windows/snapshot/find/get/click/type/set-value/press/scroll/select/toggle/shot/open/lend/return`; MCP server; focus guard; `type` through AX only (keys refuse with `not_supported` until phase 3). | `scripts/agent-hands-probe.swift`: 200 actions in TextEdit on temp documents and Finder inside a temp folder on the agent workspace, sampling every 50 ms the front app, the current workspace, the pointer, the key window and any window appearing on another workspace; zero changes. Never Notes or any once-per-user app. Plus `swift test`. |
| 1b | The agent cursor. | Visible on the agent workspace during the probe, zero changes to the real pointer, under 5 ms added per action. |
| 2 | The sandbox: `sandbox up/reset/down/status`, the guest hands daemon, routing of once-per-user and untrusted work, the handoff folder, network limited to the internet. | The probe passes inside the sandbox; a sandbox job can't reach the Mac, the LAN or the tailnet (checked from inside); reset returns a clean guest in under 10 s; the sandbox window never appears on your workspaces. |
| 3 | Browsers and Electron: agent browser profiles over the debugging pipe, Safari and Firefox in the sandbox. | A page form filled and read back in Helium (agent profile), Chrome, Firefox and Safari (sandbox) and in Obsidian, with zero screen changes. |
| 4 | Window-local pointer and per-process keys (SkyLight) for apps without a usable tree; the refusal contract. | A canvas app drawn on from behind with zero changes; every refused route returns a suggestion. |
| 5 | Head-to-head (`bench/`): the same 30 tasks through BaneySpaces, agent-desktop and ChatGPT's computer use, each run in the same place (all on the agent workspace where the task allows it, all in the sandbox otherwise), scored on success, screen changes, time and turns. Cua's driver is a column only inside the sandbox. Fleet routing switches to BaneySpaces' MCP. | BaneySpaces is best or tied on every column; the numbers and the tool versions are committed under `bench/results/`, and the ratchet blocks any regression. |

## Rules that do not bend

- No global HID events from agent actions, ever.
- No `activate`, `SetFrontProcess` or Space change on behalf of an agent.
- No action on a window outside the agent workspace unless that app is lent.
- Snapshots and captures can hold private content, and an MCP caller is a model whose provider sees
  every result. So results only ever come from the agent workspace, the sandbox or a lent app, never
  from your workspaces; captures are returned only when the caller asks for one; and nothing goes
  into logs.
