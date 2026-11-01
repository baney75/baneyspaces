"""Running commands: one place, so tests can swap it and the abort can stop it."""
import os
import signal
import subprocess
import threading
import time


class Aborted(RuntimeError):
    """Raised when the run was stopped because real input was seen, the monitor was lost or the screen locked."""


class PgidRegistry:
    """The process groups of the commands the harness is running right now, written to a file the sampler reads.

    The sampler counts an event posted by a program as that column's own input only when the poster is in one of
    these groups (or is the referee/cleanup, which are Exec children too). Any other poster, such as a remapper or
    a scroll tool of Donovan's, is treated as real input.
    """

    def __init__(self, path=None):
        self.path = path
        self._pgids = set()
        self._lock = threading.Lock()
        self._write()

    def add(self, pgid):
        with self._lock:
            self._pgids.add(int(pgid))
        self._write()

    def discard(self, pgid):
        with self._lock:
            self._pgids.discard(int(pgid))
        self._write()

    def snapshot(self):
        with self._lock:
            return sorted(self._pgids)

    def _write(self):
        if not self.path:
            return
        tmp = f"{self.path}.{os.getpid()}.tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write('{"pgids": %s, "pids": [%d]}' % (self.snapshot(), os.getpid()))
        os.replace(tmp, self.path)


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
        if self.registry:
            self.registry.add(proc.pid)          # start_new_session: the group id is the child's pid
        try:
            return self._wait(proc, stdin, timeout, t0)
        finally:
            if self.registry:
                self.registry.discard(proc.pid)

    def _wait(self, proc, stdin, timeout, t0):
        out = {}

        def talk():
            out["r"] = proc.communicate(stdin)

        th = threading.Thread(target=talk, daemon=True)
        th.start()
        deadline = t0 + timeout
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
        so, se = out.get("r", ("", ""))
        return proc.returncode, so, se, int((time.monotonic() - t0) * 1000)

    @staticmethod
    def _kill(proc):
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
