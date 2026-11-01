# The sandbox

A throwaway macOS VM for agent work (agent computer use, phase 2; see `agent-computer-use.md`). Apple
Virtualization through Tart, pinned in `sandbox/PIN`. Code: `Sources/BaneySpacesCore/Sandbox/`.

```sh
baneyspaces sandbox up [--task NAME]   # clean guest, headless, network checked from inside, handoff folder mounted
baneyspaces sandbox reset              # a clean guest in place of this one (about 6 s)
baneyspaces sandbox down               # stop and delete the VM
baneyspaces sandbox status             # JSON
baneyspaces sandbox view [--off]       # show the VM's display on the agent workspace (needs the app)
baneyspaces sandbox guest status       # ask the guest hands daemon (today: the stub)
baneyspaces sandbox --local probe      # up, reset x3, down, timed; no app needed (scripts/sandbox-probe.swift)
```

The commands go to the running app over the deck socket and are answered off the main thread, so a VM
booting never stalls the dock or the hotkeys. They are local only: `Remote.allows` refuses the sandbox
from another machine. The sandbox is off until Settings > Agents turns it on.

## How a guest gets made

1. `up` clones the base image (pinned by digest; Tart pulls it into its store the first time) with an
   APFS clone, sizes it (`tart set`), and runs it `--no-graphics --suspendable` on Softnet.
2. It waits for the Tart guest agent and for the handoff folder to mount.
3. The self-check runs inside the guest (below). Any failure stops and deletes the VM.
4. A **warm clone** is then built in the background: another clone, booted, checked and cleaned.
   Where it waits depends on use (`SandboxWarmPolicy`):
   - **In memory** while the sandbox is in use (a sandbox command, `status` excepted, in the last 15
     minutes) and the Mac has the VM's memory plus 4 GB free: it is left running, already holding the
     slot of its own (below). `reset` kills the working VM and
     promotes the warm one: nothing to restore from disk. (Tart has no in-memory pause, so "paused" means
     booted and idle.) It counts as the second of the two guests.
   - **On disk** (`tart suspend`) after 15 idle minutes, when memory gets tight, when it is built while
     idle or tight, and on `down`. `tick()` moves a running warm clone to disk when its conditions stop
     holding, and when another tool has a VM that may need the second guest slot (up to one tick, 5 s; a third-party VM
     is otherwise blocked from that slot for as long as the clone runs, at most the 15 idle minutes). A reset from disk restores the saved state: 4.8 to 12 s depending on how busy the Mac is.
   `reset` keeps the 10 s budget for the p90 of the run; `status` (`reset_stats`) and the probe report
   count, p50 and p90, and each reset says whether it came `from` memory or disk. With no warm clone
   ready `reset` waits for the build (`swap_after_wait`) or boots cold (`cold`); a cold boot never counts
   as meeting the budget. Agent calls routed to the sandbox later (`agent --in sandbox`) must call
   `SandboxManager.touch()` so they count as use.
5. Everything is deleted on every failure path (`deleteVerified`: stop, delete, then check `tart list`;
   a delete that doesn't take is retried by `tick()`), when the app quits, and at the next start (every
   `bsx-*` VM the previous run left). VMs that aren't ours are never touched. One manager per Mac owns
   them (an exclusive lock), so `--local` refuses to run beside the app.

Closing the VM's window ends the VM (it is `tart run`'s own window); the next `tick()` deletes it.

## Two guests at most

Apple Virtualization runs two macOS guests at once, whoever started them. Before any clone or
resume, `tart list` is read: with two running, `up` gets `busy` with `retry: after` and nothing is
made. The warm build is skipped when another guest is running, and is cancelled if `up` needs the
room. One sandbox per task: `up` for a second task while one is up is `busy` too.

## Network: the internet and nothing else

`tart run --net-softnet` with, copied from BaneyFleet's fleet-ci node and extended:

- block: `10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16` (RFC 1918), `100.64.0.0/10` (tailnet),
  `169.254.0.0/16` (link-local), each of this Mac's own addresses as a /32, and `out @host` (every
  connection to the vmnet gateway, which is this Mac);
- allow: the gateway's DNS only (`out proto udp|tcp @host port 53`), because DHCP hands the gateway out
  as the guest's resolver.

`SandboxNetwork.problems` refuses to start a VM whose rules lack any of that. The vmnet bridge's own
address is left out of the /32 list (it only exists while a guest runs, and `out @host` covers it), so
the rules and their stamp are the same before and after a boot.

**The self-check** (`SandboxSelfcheck`, ported from fleet-ci's `vm_selfcheck`) runs one script in the
guest through `tart exec`, all probes at once: the internet must work (HTTPS to Cloudflare, waiting for
the network to come back after a resume), `nc` to 1.1.1.1:443 must connect (a positive control: a silent
probe proves nothing), and `nc` to each IPv4 address of this Mac (on a port a throwaway
listener on the Mac really holds; IPv6 is the section below), the guest's own gateway, the LAN router and a tailnet address must
each positively time out. An error, an empty answer or an unrecognized message is a failure, so is a
listener on the Mac that saw a connection, and so is an Application Firewall that could be dropping the
probe silently. After a swap-reset the check runs again in the background (it takes longer than the
budget): the rules are the ones a full check already passed with, and a failure deletes the VM.

## Handoff folder

One per task, `~/Library/Application Support/BaneySpaces/sandbox/handoff/<task>` (mode 700; task names are plain
file names, anchored at both ends; a symlink is refused). In the guest it is `/Volumes/My Shared Files/handoff`,
read-write through Tart's directory sharing, and it is the only host path in the `tart run` command line. No home
folder, iCloud, keychain, clipboard (`--no-clipboard`), audio or USB. The sandbox never deletes a task's folder.

**No folder is ever shared by two guests.** A running VM can't gain a share, so every VM starts with a share of its
own: an empty slot, `sandbox/slots/<vm>`. That includes the warm clone, which therefore never sees any task's
files. The task's files are *moved* into the slot (renames, instant; the guest sees them at once, measured) only when
that VM takes over as the working guest, after the previous guest is dead. While a guest has them they are in its
slot (`status` shows `handoff.host_path`); `handoff.rests_at` is where they come back. A VM that has been bound to a
task is deleted at the end of that task, never reused. The live slots are recorded in `sandbox/live.json`, outside
what the guest can see.

**Nothing the guest made is ever followed or trusted on the host.** A guest that is compromised can make symlinks,
hard links, FIFOs and files with any mode in its share, and the host sees them as real. When a guest ends, its slot is
walked with `fstatat(AT_SYMLINK_NOFOLLOW)` and only regular files with one link, and folders, are *copied* out: opened
with `O_NOFOLLOW`, created `0600` / `0700` (never the guest's modes, so no setuid file), under names that don't exist
yet (a collision gets the stem cut to fit and a short id, so the name is always valid and nothing is overwritten).
Symlinks, hard-linked files, devices, FIFOs and sockets are skipped, listed in `SANDBOX-SKIPPED.txt` next to the
results, and reported as `skipped_on_release`. A tree deeper than 64 levels or with more than 200,000 entries, or more
than twice the cap, is a failure (below), not a partial copy. Any host program that reads a live slot, or the task folder
of a task that has run, must open files with `O_NOFOLLOW` too.

**A slot is never deleted before its files are safe.** It is removed only by a release that copied everything (or
deliberately skipped it), and only after its VM process is dead. If the process won't die, the VM can't be deleted, or
the release fails (disk full, unreadable record), the slot and its `live.json` entry stay, the next guest does not get
the files (`reset` stops with `handoff_pending`), `status` lists the slot under `pending_restores`, and `tick` retries
every 5 s once Tart confirms the VM is gone. An unreadable `live.json` moves and deletes nothing. At launch the files
come back from any slot a crash left bound, but only after every leftover `bsx-*` VM has been verified deleted: if one
won't stop, taking ownership is refused with `busy` and no slot is touched.

**A guest can't fill the disk.** `tick` measures each slot (apparent size, through no link) and stops a guest past the
cap (Settings > Agents, 1, 2, 5 or 10 GB, default 2): the VM is killed, its files are given back, and `status` says
`handoff_full`. Between ticks a guest can write for up to 5 s at disk speed; a hard quota would need a mounted disk image,
which is a follow-up.

## Guest hands: the interface (stub today)

`GuestHands.swift`. The real daemon is the phase 1 engine (#105) running headless in the guest; until it
lands, `baneyspaces sandbox guest status` runs a stub that answers `status` and refuses every other verb
with `not_implemented`, `retry: never` and a suggestion.

Transport: `tart exec -i <vm> /bin/bash -c <stub>`; the daemon will be `tart exec -i <vm>
/usr/local/bin/baneyspaces-hands --stdio`. Tart's guest agent is a channel the host opens (the VM's
control socket, over vsock): there is no ssh, no password and no network path into the guest. A
dedicated host-initiated vsock listener for long sessions replaces the one-shot exec when the daemon
lands; the request and reply below do not change.

```json
{"v":1,"id":"<uuid>","verb":"status","args":{}}
{"v":1,"id":"<same id>","ok":true,"data":{"daemon":"stub","protocol":"1","macos":"26.6.2","host":"…","user":"admin","handoff":"mounted","uptime_s":"41"}}
{"v":1,"id":"<same id>","ok":false,"error":{"code":"not_implemented","retry":"never","suggestion":"…"}}
```

Everything the guest says is untrusted. It is capped at 64 KB (the child is stopped at the cap, so a
guest can't fill the host's memory), parsed as data against a fixed schema and rejected whole if any rule
breaks: exactly one JSON line, `v` 1, the request's own `id`, `ok` with data xor failure with an error,
at most 32 fields with lowercase names of 32 bytes, values of 512 bytes without control characters, an
error `code` of lowercase letters and `retry` one of `safe`, `after_snapshot`, `after`, `never`. It is
never passed to a shell or AppleScript, and `status` labels it `"source": "guest-asserted"`.

## The window

`view` suspends the VM and resumes it with a window (the display is `tart run`'s own; it can't gain one
later), claims the new process's window for the agent workspace before it exists
(`Spaces.claimNextWindow`), and moves any window of that process that still lands elsewhere. With no
agent workspace, `view` refuses and starts nothing (`SandboxWindows.beforeLaunch`): the window never
opens on yours. `view --off` goes back to headless. Open the agent workspace to look.

## Installing the dependencies

`scripts/install-sandbox.sh [--dry-run] [--pull]`: Tart and Softnet at the pinned versions through the
local Homebrew tap, the setuid Softnet copy in `/usr/local/lib/baneyspaces/bin` (the one `sudo` step,
root:wheel 4755, repaired if its mode or contents drift), every download and formula checked against the
sha256s in the script and `sandbox/PIN`, and optionally the image. Idempotent; it never touches the app.

## What it does at quit, and when it is off

Quit never waits on a sandbox operation. Every VM process is recorded the moment it is spawned (a guest that is still
booting included), shutdown kills all of them at once and nothing can be spawned after it begins, then the deletes and
the files going back run on their own thread for at most a few seconds; what is left is cleaned up at the next launch.
Every wait loop (agent, share, warm build) stops when quit begins, and the window calls the sandbox makes into the app give
up after 1.5 s, so a `view` in progress can't hold up quit. Only the process holding the sandbox lock ever deletes
VMs, and only `bsx-*` ones. With the sandbox off in Settings the app still cleans up a crash at launch but gives the lock
up again straight after, so the probe can run; turning the sandbox off removes its VMs, the warm clone included.

**Probe and app.** `swift scripts/sandbox-probe.swift` uses the real sandbox lock. If the app holds it (the sandbox is on
in Settings) the probe prints `sandbox-probe SKIPPED` and exits 2 instead of reporting a failure: turn the sandbox off
or quit BaneySpaces first.

**The Mac's network changes.** Softnet's block list names this Mac's addresses, fixed when a VM starts. `tick` compares
today's addresses with the ones each running guest started with; if they differ the guest is stopped (files back) and
`status` says why. A warm clone running under the old list is saved to disk and resumed with the new one. A check on a
new clone that finds the isolation broken (not just "no internet") stops the working guest too: same image, same rules.

## IPv6

Softnet 0.25 forwards IPv4 only: measured on the host, `tcpdump -i bridge100` filtered to the guest's MAC saw 389
frames from a guest that had been given root, IPv6 switched back on, a static address in the bridge's prefix, and had
sent `ping6` to `ff02::1`, to the Mac's link-local and to its unique-local, and `nc -6` to both. All 389 were IPv4; none
was IPv6. So the guest's own IPv6 setting is not what keeps it out, and the host side enforces it. Because that is a
property of a pinned binary, the probe checks it every run from inside: as root the guest enables IPv6, adds an address,
and tries the Mac's bridge addresses (link-local with its scope, unique-local) on a port the Mac really holds; every
attempt must fail and the listener must see nothing. IPv6 is also switched off in the guest (`networksetup -setv6off`)
and the in-guest check fails on any IPv6 address or default route on a network interface, as defense in depth. An update
of Softnet that started forwarding IPv6 would fail the probe, and `sandbox/PIN` pins the version.

## Settings > Agents

On/off, memory (4 to 16 GB, macOS guests need 4; capped at a quarter of the Mac's; a Mac under 16 GB is refused with a message, not run with a smaller VM), CPUs (capped at half), the state and disk
used, Reset Now, Delete Images (the VMs and the pulled image, with a confirmation). Memory and CPUs apply
to the next VM.

## Not in this change

- The guest hands daemon (waits for #105); `agent --in sandbox` routing.
- A VNC/clipboard bridge; the cursor overlay inside the guest.
- Tart's guest agent is in the base image; a daemon install step comes with the daemon.
