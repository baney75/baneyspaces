# Head-to-head bench

Proves (or disproves) that BaneySpaces' agent computer use is the best: the same 30 tasks, the same
screen-change monitor, every tool, each in the same place. Design: [docs/agent-computer-use.md](../docs/agent-computer-use.md)
(phase 5, "Two places for agent work").

| Column | What it is |
| --- | --- |
| `baneyspaces` | `baneyspaces agent ...` |
| `agent-desktop` | vercel-labs/agent-desktop built from the pinned source (`bench/PIN`, the commit phase 1's engine uses), default strict-headless delivery |
| `agent-desktop-headed` | the same binary with `--headed`: its best case for success, since it may take focus and the pointer. **Runs only in the sandbox (#111), never on this Mac**: on the host it reports `unavailable: sandbox_only` for every task, like ChatGPT |
| `chatgpt` | ChatGPT/Codex computer use, driven by `codex exec` through ChatGPT.app's `cua_repl` server. **Runs only inside the sandbox VM, never on this Mac**: every task, at every level, is `unavailable: needs sandbox` until the sandbox exists |

On the host only the background columns run: BaneySpaces, and agent-desktop in its non-headed mode. Cua's driver is removed from the fleet. A Cua column is only meaningful inside the sandbox (phase 2) and is **pending**.

## Run it

```sh
bench/run.sh --dry-run --tool all            # lists the tasks, checks every runner resolves; touches nothing
bench/run.sh --tool baneyspaces              # all levels that apply to the tool
bench/run.sh --tool all --level scripted
bench/run.sh --tool chatgpt --level agent --only calculator-add
bench/run_tests.sh                           # the harness's own unit tests (fakes only)
python3 -I bench/ratchet.py                  # fail if BaneySpaces regressed (see Ratchet)
```

## It never touches Donovan's data or windows

- **Only while he is away.** `run.sh` reads `ioreg -c IOHIDSystem` HIDIdleTime and, under 600 s, prints
  `not run: user active ...` and exits 3 before it builds, opens or touches anything; `harness.py` checks the same
  itself. There is no flag or variable that lowers the bar. Once the sampler is up the harness checks again, and
  **before every task** it requires 600 s of *real* idle and an awake, unlocked screen. Real input at any moment kills
  the child tool and stops the run.
- **Real input versus a tool's own input.** The sampler listens (listen-only event tap) to keyboard, mouse and scroll
  events and reads each event's source process id: pid 0 is hardware, any other pid is a program posting events. Only
  pid 0 counts as Donovan. So `agent-desktop-headed` and ChatGPT (which may post input) are not stopped by their own
  events, and their posted-input counts are reported. Without Input Monitoring the tap cannot be created; the sampler
  then falls back to HID idle time, which cannot tell them apart, and those two columns are `unavailable` rather
  than run unprotected. A tap the system disables is a lost monitor, and HID activity no tapped event explains (typing under
  secure input) is real input. Idle is measured from the last real event, not from `HIDIdleTime`, once the sampler runs.
- **Awake and unlocked.** Before the run and before every task the sampler's session state must show an unlocked
  screen, an awake display, the console session, no `loginwindow` in front and **no secure keyboard input** (a password field
  or Secure Keyboard Entry hides keystrokes from the tap, so it counts as someone being there) (`not_run`, never a `fail`, otherwise).
  The run holds `caffeinate -dims -t <budget>` (display, idle, disk and system sleep) for ONE level at a time, with a budget
  sized to that level's work (at most six hours), released between levels; the run stops when the budget ends. Not `-u`: that
  declares user activity, which would reset the idle clock this whole guard depends on. **Exposure, so you opt in knowingly:**
  keeping the display awake also holds off the screensaver and the lock that would follow it, so for the length of a level
  the Mac stays unlocked and unattended. It is bounded by the budget, and the gate stops the run if the screen locks, but the
  desktop is open while it runs. Display and lock state are recorded in every result file.
- **Places.** A task has `place: host` (the agent workspace, 9) or `place: sandbox`. Once-per-user apps (Notes, Safari,
  Mail, Calendar, Messages, Photos, ...) hold his data and are always `sandbox`; so is Firefox. Until the phase 2 sandbox
  exists those tasks are `unavailable: needs sandbox (phase 2)` for every tool, so every tool always runs a task in the
  same place. A test fails if a task opens a once-per-user app on the host.
- **Host tasks use only what `baneyspaces agent open` starts on the host** (phase 1, `AgentAppPolicy`): TextEdit, Preview and
  Calculator, each a NEW instance started with `-ApplePersistenceIgnoreState YES` (so it restores nothing of Donovan's), on
  fixture files in the agent handoff folder (`~/Library/Application Support/BaneySpaces/hands/handoff`, where this run makes a
  directory of its own). Anything else (Finder, browsers, Electron apps, System Settings) answers `needs_sandbox` and the task
  is `unavailable`. After an open, if the app owns a window the bench did not create, or a window the bench did create is not
  on the agent workspace, the task is `infra_error` and the tool does not run. Calculator runs only if it is not already
  running, and its preferences (`com.apple.calculator`) are saved before and restored after every Calculator task, so a
  View > Scientific never reaches Donovan's Calculator. A browser or Electron app (sandbox only for now) is launched
  only with a fresh `--user-data-dir` under the bench temp dir (`baneyspaces agent open <app> --user-data-dir <dir>`),
  and the new window's process arguments are read back to verify it; a build whose `agent open` does not advertise that
  flag, or a launch that does not carry it, makes the task `unavailable` / `infra_error`. An environment flag alone never
  authorizes the normal profile, and a browser that is already running is never used. The availability check runs at
  **every level, micro included**, before anything opens: `exclusive` (no window of that app on one of his workspaces),
  `not_running`. An app he has open makes the task `unavailable`, not failed.
- **Teardown closes only windows the bench created**: their ids are recorded when `baneyspaces agent open` returns them;
  one is closed only if its id is still on the agent workspace, by pressing the window's own Close button (a direct
  child of the window, never matched by text elsewhere) and, on a sheet, "Don't Save". Never "Delete" or "Discard".
  An app (an exclusive one such as TextEdit included) is quit only if this task started it; a teardown that throws is recorded in `teardown_pending` and the accounting and temp-dir clean-up still run. Teardown shares the run's
  abort and checks it before every action: after an abort nothing more is done and `teardown_pending` in the result
  lists what was left on the agent workspace.
- **The agent columns are confined.** The BaneySpaces column reaches the Mac only through `baneyspaces mcp`, which
  refuses windows outside the agent workspace, and claude may call only the exact tools `windows snapshot find get click type
  set_value press scroll select toggle`: not `open`, `lend`, `return` or `shot`, so an agent that follows a refusal's
  suggestion cannot pull a window of Donovan's onto the agent workspace or start an app there (a test compares the list with
  the tools BaneySpaces ships). The agent-desktop column's Bash may run only `bench/agent-desktop-guard`,
  which is an allowlist: per verb, only listed flags and positionals; every act verb must carry exactly one ref from a
  snapshot of an allowed window (so nothing is aimed at "whatever is focused"); it refuses every other window id, `--app`,
  `--headed`, desktop-wide surfaces, and filters `list-windows`. Its own refusals are code `guard_refused`: they are recorded
  (`guard_refusals`) and never credited to the tool as a refusal, because its binary was not reached. ChatGPT's Sky, which
  cannot be confined this way, runs only in the sandbox (above).
- Browser fixture pages are `http://127.0.0.1:<port>/form` served by the harness. Nothing is written outside the temp
  directory, and `~/Desktop` is watched for stray files (`collateral`).

## Three levels

| Level | File | What it measures |
| --- | --- | --- |
| `agent` (end to end) | `results/<date>-<time>-<tool>.json` | The tool's own agent does each task from its goal: `claude -p` (one model for both, `BENCH_CLAUDE_MODEL`, default `sonnet`) with the BaneySpaces MCP server or Bash limited to the agent-desktop binary; `codex exec` with ChatGPT computer use. Success, screen changes, wall time, model turns. |
| `scripted` | `results/<date>-<time>-<tool>-scripted.json` | The same step script through each tool's command line. Isolates the tool from the model. |
| `micro` (driver level) | `results/<date>-<time>-<tool>-micro.json` | Per-action latency (snapshot, click, type, read-back), 20 repetitions for every tool (a measurement with a failed action, a failed read-back check or fewer samples is `invalid`: kept as a diagnostic, never a result). **Reported, never gated across tools**: a CLI tool is timed as one spawned process per action minus the median no-op spawn of the same binary, the Sky primitives in-process, so the numbers are comparable in kind only. BaneySpaces is compared with its own earlier numbers. |

Tools take turns task by task (rotating who goes first), so a quota running out or a warm cache cannot favor one
column. Each result file has a run id and is never overwritten. Only **full** runs (every task attempted, no `--only`,
not cut short) feed `results/latest.md` and the ratchet; partial runs are kept and listed.

`results/latest.md` has the comparison table per level, the per-task matrix, the gate, and the version and commit of every
tool: bench commit, BaneySpaces installed app version and the commit its bundle records, agent-desktop version and pinned
commit, ChatGPT.app, codex, `@oai/sky` and the `cua_repl` definition used, claude version and model.

### How ChatGPT computer use is run

**Never on Donovan's Mac.** Sky/`cua_repl` is a node REPL that can act on, and read files from, the whole desktop, so it
runs only inside the sandbox VM, which holds nothing but the task's fixture (phase 2). Until that exists the `chatgpt`
column is `unavailable: needs sandbox` for every task and for the micro level, and it is enforced in layers with no flag or
environment variable that lifts it: `host.availability()` refuses the tool for every task; `run_group` records those
without calling the runner; `agents.codex_command()` raises `SandboxOnly` unless it is handed a sandbox route (none exists);
the agent `doing` for the tool raises; `run_micro_level` returns `n/a` before it opens a window; `harness.py` contains no
call to `codex_command` or `chatgpt_micro.mjs` (tests check all of it). The dry run still lists and resolves the column.

How it will run once the sandbox exists: `codex exec` reads `~/.codex/config.toml`, where `cua_repl` is a disabled stub whose
command is the ChatGPT app itself, so `enabled=true` alone would start Electron. The real server is node plus `cua-repl.mjs` with
the computer surface on, defined in `~/.codex/plugins/cache/openai-bundled/unified-computer-use/<newest version>/.mcp.json`.
`agents.cua_repl_overrides` reads that file and passes every field as `-c mcp_servers.cua_repl.<key>=...` for the one invocation,
and switches the user's other MCP servers off the same way. The config file is never opened for writing (a test checks).
Shell use or any non-`cua_repl` tool is a `shortcut` and fails the task. Donovan's Codex sign-in is used; no key, no API billing.

## Scoring

Statuses: `pass`, `fail`, `refused_ok` are scored. Everything else is counted and listed but **never charged to a tool**:
`unavailable`, `infra_error` (the harness or the account failed: no result, `cua_repl` did not start, signed out, quota,
a setup that could not open the app), `monitor_lost`, `not_run`. A fatal infra error (cua_repl will not start, quota gone)
stops that column and leaves it `n/a` instead of scoring nothing 30 times.

- **Every query waits out the debounce.** A window that appears without a workspace is reported by the sampler a second
  later, stamped with when it first appeared on its own line (never merged into the current sample's changes), and BaneySpaces
  writes `state.json` a moment after a window exists. So the runner waits `drain_s` (1.5 s) before `t0`, before `tt0`, on every
  early-return setup path and before the final teardown query; a window raised by the last action or by a teardown step is
  counted in the window it belongs to. Real input from any process outside the column's own process groups (the sampler is
  given them through a file the harness keeps) counts as Donovan's, so his remapper or scroll tool still stops the run.
- **A window leaked by setup fails the task** (and the tool is not run). The runner waits out the sampler's one-second
  debounce before it takes `t0`, events are stamped with when the window first appeared, and a leak found in the setup window
  is `fail` with `setup_leak`, never a change the tool made. The "missing window" task uses a bench window that existed and was
  closed, so the tool's own binary (not the guard) is the one that says it is gone.
- **Hangs are the tool's.** A computer-use call that was issued but never returned before the timeout counts as attempted:
  the task is a `fail`, not an `infra_error`. Account, quota and start-up errors are read only from stderr and the stream's
  own error events, never from the agent's words.
- **Screen changes** are reported for the task, setup (a window dropped on Donovan's workspace by `agent open`, even if setup then
  failed) and teardown, in non-overlapping windows. The ratchet and the cross-tool gate use the **in-task** count: setup and
  teardown run the same harness code for every tool. A window that appears from one of Donovan's own background apps is
  `ambient` only when the window belongs to a process that was already running **with a window on one of his workspaces before the
  task began** (snapshotted at the task's start) and is not the task's app or this column's own process. A window from an app the
  tool itself made open (Safari from a double-click) is charged.
- **Monitor integrity.** The sampler prints a beat on every 50 ms sample. No beat for 200 ms, a beat reporting a longer
  gap, or the process exiting is a lost monitor: the run aborts and any task that ran then is `monitor_lost`, never a pass.
  A sheet or alert is part of its parent window (same process, inside its frame), not a new window.
- **Reads must be observed.** `preview-read-open-pdf` and `electron-cursor-read-editor` use a random per-run value in the
  document's *content* (`{nonce}`, never in a title, file name, goal or prompt, which a test enforces); the agent's answer (or
  the scripted read) must contain it and the agent must have made a computer-use call that came back (counted from claude's
  stream and codex's JSONL, only calls to the computer-use tool). A shell command or any other tool that ran is a
  `shortcut` and fails the task: that is how the ChatGPT column is kept honest, since codex's read-only sandbox still
  lets its shell read files. Refusal tasks need the tool's own refusal (its code and suggestion from the tool's envelope
  for the claude columns), and their goals no longer say the answer.
- **A refusal is good** only with a suggestion, **and** with no screen change, no real input, **no input posted by a program
  (counted from the tap per source pid)** and no stray file, and the app state unchanged (the stale-ref task checks its intended close explicitly).
- **The referee** never asks the tool: it reads a file, the fixture server's log (what the browser really submitted), or a
  window through agent-desktop's read-only `snapshot`, the same for every column.

## Ratchet

`python3 -I bench/ratchet.py` fails (exit 1) when, over the tasks **both runs completed**:

- BaneySpaces regresses against `bench/baseline/baneyspaces-<level>.json` on success, screen changes, tasks with a change,
  median or p90 (25% + 0.25 s of slack), good refusals or collateral, or a task that passed there fails now; or
- BaneySpaces is behind any other tool at the same level: success must be `>=`; screen changes, tasks with a change,
  median and p90 must be `<=`.

**There is no seeded baseline.** A run that scored nothing is never `full`, and one that completed under half the baseline's scored
tasks is a ratchet problem. `bench/baseline/` is empty until `ratchet.py --update` is run on a measured, full,
un-aborted BaneySpaces run. `--update` refuses a partial run, a run that scored no task, an invalid micro measurement, refuses a run that regresses, and keeps the old entry for
any task the new run did not complete, so a smaller run never shrinks the ratchet. `--require` makes "no result to compare"
an error (exit 2).

## Adding a task

Drop `bench/tasks/<id>.json` (the file name is the id). Fields:

```json
{
  "id": "textedit-type", "app": "TextEdit", "category": "textedit", "place": "host",
  "goal": "what an agent is told, in plain words; names windows by title",
  "setup": {
    "requires": {"installed": ["TextEdit"], "exclusive": ["TextEdit"], "not_running": [], "env": []},
    "files": {"empty.txt": "", "long.txt": {"lines": 400}, "reading.pdf": {"pdf_pages": 3, "text": "Access code {nonce}"}, "r.rtf": {"rtf": true}, "dir": {"dir": true}},
    "open": [{"app": "TextEdit", "as": "doc", "targets": ["{tmp}/empty.txt"], "title": "empty.txt"}],
    "hide": "Calculator", "quit_after": ["Calculator"], "settle_s": 0.8
  },
  "steps": [{"do": "type", "window": "doc", "target": {"role": "textfield"}, "text": "Hello"}],
  "check": {"kind": "ax", "window": "doc", "target": {"role": "textfield"}, "equals": "Hello"},
  "expected_fail": {"baneyspaces": {"phase": 3, "why": "..."}}
}
```

- Every app a host task opens needs `exclusive` or `not_running` for it; `hide` and `quit_after` need `not_running`; a host
  browser or Electron app needs `setup.profile` and `not_running` (Cursor restores the previous session's windows without one); a once-per-user app needs `"place": "sandbox"`. `bench/run_tests.sh` enforces all of it.
- `{tmp}`, `{base}` (fixture server URL), `{port}` and `{nonce}` (random per run) are filled in per run, in dict keys (file paths) as well as values. A fixture that is not at the path the task opens is an `infra_error`.
- Step verbs: `snapshot click type set-value press scroll select toggle menu wait get`. A target is a selector (`role`, `name`,
  `value`, `text`, `exact`, `state`, `not_state`, `within`, `nth`); `surfaces` (`window`, `sheet`, `menubar`) say where to look;
  `save_ref` / `ref` reuse a ref; `expect_refusal: true` marks the step the tool should refuse; `optional: true` lets a step fail;
  `answer_from: "title"` on a snapshot, or a `get`, makes the value the scripted answer.
- `setup.profile: "user-data-dir"` (required for host browsers and Electron apps) launches with a fresh profile; `setup.close_before_run: [alias]` closes a window the bench opened before the run, for the "missing window" case.
- Check kinds: `file` (`equals contains regex is_dir absent`), `ax` (`equals contains gt exists`, `property`, `surface`),
  `window_title`, `window_gone`, `answer` (`contains`), `form`, `nothing`, `all`. `allowed_change_fields` (`front`, `key_window`) names the changes a task's own intended action causes (closing its own window); they are recorded as `intended_changes`, not charged. A task with `requires_tool_call` needs an `answer` check.
- `expected_fail` marks a task a tool cannot do yet. It still runs and counts as a failure. Phase 1 types through the
  accessibility tree only, so every task that presses a key is an expected failure for BaneySpaces (phase 4).
- Impossible tasks use `category: "refusal"` and `impossible: true`.

## Status of this build

Prepared and unit-tested (`bench/run_tests.sh`, 344 tests, fakes only). `bench/run.sh --dry-run --tool all` lists the 30 tasks
and resolves every runner. agent-desktop builds from the pinned source. **No column has been measured and nothing has
run live since the 2026-10-31 incident** (a Calculator and a TextEdit window landed on Donovan's workspace); the monitor's
`user_window` and `unplaced_window` fields exist to catch that.

Known gaps to read before trusting a number:

- Selectors (button and field names) were written from the apps' accessibility trees and the documented interface; the first
  idle run will show which need adjusting. A task that fails on its own selector fails for every tool alike.
- `agent-desktop` headless cannot send keys to a window that is not frontmost (`STALE_REF`, `exact_window_focus_unconfirmed`),
  so key tasks fail for it unless `--headed`, which is why that is its own column.
- ChatGPT is not measured at all until the phase 2 sandbox can run it.
- The installed BaneySpaces app bundle may not record its commit; the result then says so (read with `plutil -extract`, absent key = not recorded).
- The sampler needs Input Monitoring for the tap; the first run will say whether it has it.
