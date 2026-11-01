"""Running commands: one place, so tests can swap it and the abort can stop it."""
import os
import signal
import subprocess
import threading
import time


class Aborted(RuntimeError):
    """Raised when the run was stopped because real input was seen, the monitor was lost or the screen locked."""


class Exec:
    """exec(argv, timeout=60, env=None, stdin=None, cwd=None) -> (returncode, stdout, stderr, ms).

    `abort` is a threading.Event; when it is set the child's process group is killed and Aborted is
    raised, so a run never keeps acting once Donovan is back. On a timeout the child is killed and
    whatever it printed so far is returned with rc 124: an agent that made tool calls before its
    time ran out must still be scored on them.
    """

    def __init__(self, abort=None, cwd=None):
        self.abort = abort or threading.Event()
        self.cwd = cwd

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
