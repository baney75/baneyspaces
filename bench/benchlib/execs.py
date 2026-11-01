"""Running commands: one place, so tests can swap it and the abort can stop it."""
import os
import signal
import subprocess
import threading
import time

GRACE_S = 5.0     # a process group stays on the sampler's allow list this long after its command ended


class Aborted(RuntimeError):
    """Raised when the run was stopped because real input was seen, the monitor was lost or the screen locked."""


class PgidRegistry:
    """The process groups of the commands the harness is running right now, written to a file the sampler reads.

    The sampler counts an event posted by a program as that column's own input only when the poster is in one of
    these groups (or is the harness). Any other poster, such as a remapper or a scroll tool of Donovan's, is treated
    as real input. A group stays listed for GRACE_S after its command ends, so an event a program posted just before
    it exited (delivered to the sampler after the process is gone, when its group can no longer be looked up) is still
    recognised. `add` is synchronous: when `waiter` is set it blocks (bounded) until the sampler has acknowledged the
    new version of the file, so a child never starts posting before the sampler knows its group.
    """

    def __init__(self, path=None, clock=time.monotonic, waiter=None):
        self.path = path
        self.clock = clock
        self.waiter = waiter            # waiter(version, timeout) -> bool, set once the monitor is up
        self.version = 0
        self._live = set()
        self._grace = {}                # pgid -> expiry
        self._lock = threading.Lock()
        self._write()

    def add(self, pgid):
        with self._lock:
            self._live.add(int(pgid))
        v = self._write()
        if self.waiter:
            self.waiter(v, 0.5)

    def discard(self, pgid):
        with self._lock:
            self._live.discard(int(pgid))
            self._grace[int(pgid)] = self.clock() + GRACE_S
        self._write()

    def snapshot(self):
        with self._lock:
            now = self.clock()
            self._grace = {g: t for g, t in self._grace.items() if t > now}
            return sorted(self._live | set(self._grace))

    def _write(self):
        with self._lock:
            self.version += 1
            v = self.version
        if not self.path:
            return v
        tmp = f"{self.path}.{os.getpid()}.tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write('{"version": %d, "pgids": %s, "pids": [%d]}' % (v, self.snapshot(), os.getpid()))
        os.replace(tmp, self.path)
        return v


class Exec:
    """exec(argv, timeout=60, env=None, stdin=None, cwd=None) -> (returncode, stdout, stderr, ms).

    `abort` is a threading.Event; when it is set the child's process group is killed and Aborted is
    raised, so a run never keeps acting once Donovan is back. On a timeout the child is killed and
    whatever it printed so far is returned with rc 124: an agent that made tool calls before its
    time ran out must still be scored on them.
    """

    def __init__(self, abort=None, cwd=None, registry=None):
        self.abort = abort or threading.Event()
        self.cwd = cwd
        self.registry = registry
        self._live_procs = set()
        self._live_lock = threading.Lock()

    def __call__(self, argv, timeout=60, env=None, stdin=None, cwd=None):
        if self.abort.is_set():
            raise Aborted("stopped: input was seen on this Mac")
        t0 = time.monotonic()
        full_env = dict(os.environ)
        if env:
            full_env.update(env)
        proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                stdin=subprocess.PIPE if stdin is not None else subprocess.DEVNULL,
                                env=full_env, cwd=cwd or self.cwd, start_new_session=True)
        with self._live_lock:
            self._live_procs.add(proc)
        if self.registry:
            self.registry.add(proc.pid)          # start_new_session: the group id is the child's pid
        try:
            return self._wait(proc, stdin, timeout, t0)
        finally:
            with self._live_lock:
                self._live_procs.discard(proc)
            if self.registry:
                self.registry.discard(proc.pid)

    def kill_all(self):
        """Kill every command still running (the run is ending: Ctrl-C, SIGTERM, an exception)."""
        with self._live_lock:
            procs = list(self._live_procs)
        for p in procs:
            self._kill(p)
        return len(procs)

    def _wait(self, proc, stdin, timeout, t0):
        out = {}

        def talk():
            out["r"] = proc.communicate(stdin)

        th = threading.Thread(target=talk, daemon=True)
        th.start()
        deadline = t0 + timeout
        try:
            while th.is_alive():
                th.join(0.05)
                if self.abort.is_set():
                    self._kill(proc)
                    th.join(2)
                    raise Aborted("stopped: input was seen on this Mac")
                if time.monotonic() > deadline:
                    self._kill(proc)
                    th.join(5)
                    so, se = out.get("r", ("", ""))
                    return 124, so or "", (se or "") + f"\ntimeout after {timeout}s", int((time.monotonic() - t0) * 1000)
        except BaseException:
            # Ctrl-C, SIGTERM turned into an exception, anything: the child lives in its own session and would
            # otherwise keep acting on the Mac with the monitor and the guards gone.
            self._kill(proc)
            raise
        so, se = out.get("r", ("", ""))
        return proc.returncode, so, se, int((time.monotonic() - t0) * 1000)

    @staticmethod
    def _kill(proc):
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
