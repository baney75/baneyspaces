"""The screen-change monitor shared by every runner.

A Swift sampler (lib/sampler.swift, compiled to .tools/bench-sample) reads every 50 ms the frontmost
app, BaneySpaces' current workspace (state.json), the pointer position and the front-most normal
window, and prints a line when one of them changes. This module collects those lines, and counts the
changes that fall inside a time window: each one counts against the tool being run.

Window changes: `user_window` (a window newly listed on a workspace other than the agent workspace) and
`unplaced_window` (a new on-screen window listed on no workspace for over a second). A sheet is part of
its parent window (the sampler decides). Each carries the owner app of the window, so a change can be
attributed: only a window owned by an app the task opened, or by the tool under test, is charged to the
tool; one from Donovan's own background apps is recorded as ambient and never scored.

Input: the sampler listens (listen-only tap) to keyboard and mouse events and reads each event's source
process id. Pid 0 is real hardware. A program's posted event is the column's own input only when the poster is in a
process group the harness started (or is the referee/cleanup); an event from any other pid is counted as real input,
because a remapper or scroll tool of Donovan's looks exactly like that. Only real input aborts the run. If the tap cannot be created
(no Input Monitoring permission) the sampler falls back to HID idle time, which cannot tell them apart; then
the monitor reports `tap_ok = False` and the harness skips the tools that post input.

Integrity: the sampler prints a beat on every sample. No beat for 200 ms, a beat reporting a longer gap,
or the process exiting is LOST: the run aborts and a task that ran then is `monitor_lost`.
Session: the sampler reports whether the screen is locked, the display asleep, loginwindow in front, or secure
keyboard input on (typing then never reaches the tap, so it counts as the user being there). A tap the system
disables is a lost monitor. HID activity the tap cannot explain (no posted events behind it) is real input.
"""
import json
import os
import subprocess
import threading
import time

SETTLE_S = 0.25          # a change this soon after a window ends is still the window's (teardown only)
HID_ABORT_IDLE_S = 5.0   # real idle below this means someone is at the machine
STALL_S = 0.2            # no beat for this long: the monitor is lost
WATCH_S = 0.02
WINDOW_FIELDS = ("user_window", "unplaced_window")
# Each column's own processes. A window owned by ANOTHER tool's process is ambient, not charged to this one.
TOOL_OWNERS = {
    "baneyspaces": {"BaneySpaces"},
    "agent-desktop": {"agent-desktop"},
    "agent-desktop-headed": {"agent-desktop"},
    "chatgpt": {"ChatGPT", "Codex Computer Use", "SkyComputerUseService", "SkyComputerUseClient", "codex"},
}


class Event:
    __slots__ = ("t", "kind", "fields", "raw")

    def __init__(self, t, kind, fields, raw):
        self.t, self.kind, self.fields, self.raw = t, kind, fields, raw


def parse_line(line):
    """One sampler line -> Event, or None for noise."""
    try:
        obj = json.loads(line)
    except (json.JSONDecodeError, TypeError):
        return None
    if not isinstance(obj, dict) or "event" not in obj or "t" not in obj:
        return None
    return Event(float(obj["t"]), obj["event"], list(obj.get("fields", [])), obj)


def changes_between(events, t0, t1, settle=0.0):
    """The screen changes in the half-open window [t0, t1+settle): each is {t, fields, from, to[, windows]}.
    Half-open so two consecutive windows never both claim one event."""
    out = []
    for e in events:
        if e.kind == "change" and t0 <= e.t < t1 + settle:
            item = {"t": round(e.t - t0, 3), "fields": e.fields, "from": e.raw.get("from"), "to": e.raw.get("to")}
            if e.raw.get("windows"):
                item["windows"] = e.raw["windows"]      # [{id, pid, owner}] that newly appeared
            out.append(item)
    return out


def attribute(changes, owners, ambient_pids=frozenset()):
    """-> (charged, ambient). A window change is ambient only when EVERY window in it belongs to a process that was
    already running and already had a window on one of Donovan's workspaces before the task began (`ambient_pids`,
    snapshotted at ts0: his own Mail, Messages, an updater, ...) and is not one of this task's or this column's apps
    (`owners`). Anything else is charged, so an app the tool itself caused to open (Safari, Notes, TextEdit from a
    double-click) on his workspace is never scored as clean."""
    owners, ambient_pids = set(owners), set(ambient_pids)
    charged, ambient = [], []
    for c in changes:
        wf = [f for f in c["fields"] if f in WINDOW_FIELDS]
        rest = [f for f in c["fields"] if f not in WINDOW_FIELDS]
        wins = c.get("windows") or []
        if wf and wins and all(w.get("pid") in ambient_pids and (w.get("owner") or "") not in owners for w in wins):
            if rest:
                charged.append(dict(c, fields=rest))
                ambient.append(dict(c, fields=wf))
            else:
                ambient.append(c)
        else:
            charged.append(c)
    return charged, ambient


def input_between(events, t0, t1, settle=0.0):
    """-> (real, posted, by_pid): hardware events, events posted by programs, and the posted ones per source pid."""
    real = posted = 0
    by_pid = {}
    for e in events:
        if (e.kind == "input" and t0 <= e.t < t1 + settle):
            real += int(e.raw.get("real", 0))
            for pid, n in (e.raw.get("posted") or {}).items():
                posted += int(n)
                by_pid[pid] = by_pid.get(pid, 0) + int(n)
        elif e.kind == "hid" and e.raw.get("real") and t0 <= e.t < t1 + settle:
            real += 1                  # HID activity the tap did not explain: someone typed under secure input
    return real, posted, by_pid


class Monitor:
    """Runs the sampler as a child process and keeps its events.

    `command` is the argv of the sampler (tests pass a fake). Callbacks run on background threads:
    on_hid(event) for REAL input, on_lost(loss) for a lost monitor, on_session(state) when the
    screen locks, the display sleeps or loginwindow comes to the front.
    """

    def __init__(self, command, on_hid=None, on_lost=None, on_session=None, stall_s=STALL_S, clock=time.time):
        self.command = command
        self.on_hid, self.on_lost, self.on_session = on_hid, on_lost, on_session
        self.stall_s = stall_s
        self.clock = clock
        self.events = []
        self.losses = []
        self.samples = 0
        self.max_gap_ms = 0
        self.interval_ms = None
        self.tap_ok = False
        self.session = {}
        self.user_pids = set()        # processes that own a window on one of Donovan's workspaces, as the sampler last said
        self.posted_total = 0
        self._start_t = None
        self._start_idle = 0.0
        self._real_last = None
        self._last_beat = None
        self._lock = threading.Lock()
        self._proc = None
        self._stopping = False
        self._started = threading.Event()

    def start(self, timeout=5.0):
        self._proc = subprocess.Popen(self.command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                      text=True, bufsize=1)
        threading.Thread(target=self._read, daemon=True).start()
        if not self._started.wait(timeout):
            self.stop()
            raise RuntimeError("the screen-change sampler printed nothing in %.0f s" % timeout)
        threading.Thread(target=self._watch, daemon=True).start()
        return self

    def _lose(self, why):
        with self._lock:
            if self.losses and self.losses[-1]["why"] == why:
                return
            loss = {"t": self.clock(), "why": why}
            self.losses.append(loss)
        if self.on_lost:
            self.on_lost(loss)

    @staticmethod
    def session_ok_of(s):
        # secure input (a password field, Terminal's Secure Keyboard Entry) hides keystrokes from the tap, so it
        # is treated as the user being present
        return not (s.get("locked") or s.get("asleep") or s.get("loginwindow") or s.get("secure_input")
                    or s.get("console") is False)

    def _read(self):
        for line in self._proc.stdout:
            ev = parse_line(line)
            if ev is None:
                continue
            stalled = gap = None
            real_in = False
            tap_dead = False
            bad_session = None
            with self._lock:
                if ev.kind == "start":
                    self.interval_ms = ev.raw.get("interval_ms")
                    self.tap_ok = bool(ev.raw.get("tap"))
                    self.session = dict(ev.raw.get("session") or {})
                    self._start_t = time.time()
                    self._start_idle = float(ev.raw.get("idle") or 0.0)
                    self._last_beat = time.monotonic()
                    self._started.set()
                elif ev.kind == "beat":
                    self._last_beat = time.monotonic()
                    self.samples = ev.raw.get("samples", self.samples)
                    gap = ev.raw.get("gap_ms", 0)
                    self.max_gap_ms = max(self.max_gap_ms, gap)
                    stalled = gap > self.stall_s * 1000
                elif ev.kind == "input":
                    self.posted_total += sum(int(v) for v in (ev.raw.get("posted") or {}).values())
                    if int(ev.raw.get("real", 0)) > 0:
                        real_in = True
                        self._real_last = time.time()
                elif ev.kind == "hid" and (not self.tap_ok or ev.raw.get("real")):
                    # without the tap every HID event has to be assumed real; with it, only one the tap
                    # could not explain (typing under secure input never reaches a tap)
                    real_in = True
                    self._real_last = time.time()
                elif ev.kind == "tap_disabled":
                    tap_dead = True
                elif ev.kind == "user_pids":
                    self.user_pids = set(int(p) for p in ev.raw.get("pids") or [])
                elif ev.kind == "session":
                    was_ok = self.session_ok_of(self.session)
                    self.session = dict(ev.raw.get("state") or {})
                    if was_ok and not self.session_ok_of(self.session):
                        bad_session = dict(self.session)
                self.events.append(ev)
            if stalled:
                self._lose(f"sampler stalled {gap} ms")
            if tap_dead:
                self._lose("the input tap was disabled by the system: real input can no longer be seen")
            if real_in and self.on_hid:
                self.on_hid(ev)
            if bad_session is not None and self.on_session:
                self.on_session(bad_session)
        if not self._stopping:
            self._lose("sampler exited")

    def _watch(self):
        while not self._stopping:
            time.sleep(WATCH_S)
            last = self._last_beat
            if last is not None and time.monotonic() - last > self.stall_s and not self._stopping:
                self._lose(f"no beat for {int((time.monotonic() - last) * 1000)} ms")
                return

    def real_idle(self, now=None):
        """Seconds since the last REAL input: from the tap while the monitor runs, from HIDIdleTime at its start."""
        now = now if now is not None else time.time()
        if self._real_last is not None:
            return now - self._real_last
        return self._start_idle + (now - (self._start_t or now))

    def user_pids_now(self):
        """Snapshot, taken at a task's ts0, of the processes that already have a window on Donovan's workspaces."""
        with self._lock:
            return frozenset(self.user_pids)

    def session_ok(self):
        return self.session_ok_of(self.session), dict(self.session)

    def healthy(self):
        """-> (ok, why). Not healthy once any loss happened or the process is gone."""
        if self.losses:
            return False, self.losses[-1]["why"]
        if self._proc is None or self._proc.poll() is not None:
            return False, "sampler is not running"
        return True, ""

    def lost_between(self, t0, t1, settle=SETTLE_S):
        return [l for l in self.losses if t0 <= l["t"] <= t1 + settle]

    def snapshot_events(self):
        with self._lock:
            return list(self.events)

    def changes(self, t0, t1, settle=0.0):
        return changes_between(self.snapshot_events(), t0, t1, settle)

    def input(self, t0, t1, settle=0.0):
        return input_between(self.snapshot_events(), t0, t1, settle)

    def health(self):
        return {"interval_ms": self.interval_ms, "samples": self.samples, "max_gap_ms": self.max_gap_ms,
                "losses": [l["why"] for l in self.losses], "tap_ok": self.tap_ok, "posted_input_events": self.posted_total}

    def stop(self):
        self._stopping = True
        if self._proc and self._proc.poll() is None:
            self._proc.terminate()
            try:
                self._proc.wait(2)
            except subprocess.TimeoutExpired:
                self._proc.kill()


def build_sampler(source, out):
    """Compile lib/sampler.swift to `out` if it is missing or older than the source."""
    if os.path.exists(out) and os.path.getmtime(out) >= os.path.getmtime(source):
        return out
    os.makedirs(os.path.dirname(out), exist_ok=True)
    subprocess.run(["swiftc", "-O", "-o", out, source], check=True, capture_output=True, text=True)
    return out
