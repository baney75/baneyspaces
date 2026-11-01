"""Running commands: one place, so tests can swap it and the abort can stop it."""
import os
import shutil
import signal
import subprocess
import sys
import threading
import time

GRACE_S = 2.0     # a process group stays on the sampler's allow list this long after its command ended


class Aborted(RuntimeError):
    """Raised when the run was stopped because real input was seen, the monitor was lost or the screen locked."""


class RegistrationFailed(RuntimeError):
    """The sampler did not acknowledge a child's process group in time. The child is never started unregistered:
    its first posted event would be taken for Donovan's, and nothing could tell the difference afterwards."""


# The gate every registered command starts behind: a python shim that blocks on a pipe the parent releases only after
# the sampler has acknowledged the child's process group, then execs the real command in place (same pid, same group).
_GATE_SHIM = ("import os,sys\n"
              "fd=int(sys.argv[1])\n"
              "os.read(fd,1)\n"
              "os.close(fd)\n"
              "os.execvp(sys.argv[2], sys.argv[2:])\n")


class PgidRegistry:
    """The process groups of the commands the harness is running right now, written to a file the sampler reads.

    The sampler counts an event posted by a program as that column's own input only when the poster is in one of
    these groups (or is the harness). Any other poster, such as a remapper or a scroll tool of Donovan's, is treated
    as real input. A group stays listed for GRACE_S after its command ends, so an event a program posted just before
    it exited (delivered to the sampler after the process is gone, when its group can no longer be looked up) is still
    recognised. `add` is synchronous: when `waiter` is set it blocks (bounded) until the sampler has acknowledged the
    new version of the file, so a child never starts posting before the sampler knows its group.
    """

    def __init__(self, path=None, clock=time.monotonic, waiter=None, ack_timeout=2.0, on_failure=None):
        self.path = path
        self.clock = clock
        self.waiter = waiter            # waiter(version, timeout) -> bool, set once the monitor is up
        self.ack_timeout = ack_timeout
        self.on_failure = on_failure    # called (version) before RegistrationFailed is raised: the harness aborts the run
        self.version = 0
        self._live = set()
        self._grace = {}                # pgid -> expiry
        self._lock = threading.Lock()
        self._write()

    def add(self, pgid):
        with self._lock:
            self._live.add(int(pgid))
        v = self._write()
        if self.waiter and not self.waiter(v, self.ack_timeout):
            with self._lock:
                self._live.discard(int(pgid))
            if self.on_failure:
                self.on_failure(v)
            raise RegistrationFailed(f"the sampler did not acknowledge allow-file version {v} within {self.ack_timeout} s")

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
        full_env = dict(os.environ)
        if env:
            full_env.update(env)
        if self.registry is None:
            t0 = time.monotonic()
            proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                    stdin=subprocess.PIPE if stdin is not None else subprocess.DEVNULL,
                                    env=full_env, cwd=cwd or self.cwd, start_new_session=True)
            return self._run(proc, stdin, timeout, t0)
        # Registered: start the child behind a gate, register its group, wait for the sampler's acknowledgement, and only
        # then let it go. Timing and the timeout start at the release, not at the spawn.
        if shutil.which(argv[0], path=full_env.get("PATH")) is None:
            raise FileNotFoundError(argv[0])
        gate_r, gate_w = os.pipe()
        try:
            proc = subprocess.Popen([sys.executable, "-I", "-S", "-c", _GATE_SHIM, str(gate_r), *argv],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                    stdin=subprocess.PIPE if stdin is not None else subprocess.DEVNULL,
                                    env=full_env, cwd=cwd or self.cwd, start_new_session=True, pass_fds=(gate_r,))
        finally:
            os.close(gate_r)
        with self._live_lock:
            self._live_procs.add(proc)
        try:
            try:
                self.registry.add(proc.pid)          # start_new_session: the group id is the child's pid
                if self.abort.is_set():
                    raise Aborted("stopped: input was seen on this Mac")
            except BaseException:
                self._kill(proc)
                raise
            os.write(gate_w, b"1")                    # release: the child now execs the real command
            os.close(gate_w)
            gate_w = None
            t0 = time.monotonic()
            return self._run(proc, stdin, timeout, t0)
        finally:
            if gate_w is not None:
                os.close(gate_w)
            with self._live_lock:
                self._live_procs.discard(proc)
            self.registry.discard(proc.pid)

    def _run(self, proc, stdin, timeout, t0):
        if self.registry is None:
            with self._live_lock:
                self._live_procs.add(proc)
        try:
            return self._wait(proc, stdin, timeout, t0)
        finally:
            if self.registry is None:
                with self._live_lock:
                    self._live_procs.discard(proc)

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
