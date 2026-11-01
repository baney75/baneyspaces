"""The scripted drivers. They run the same task steps; only the command line differs.

baneyspaces           `baneyspaces agent <verb> ...`  (phase 1 interface, docs/agent-computer-use.md)
agent-desktop         the pinned agent-desktop CLI, default strict-headless delivery
agent-desktop-headed  the same binary with --headed: its best case for success, since it may take
                      focus and the pointer. Reported as its own column.

Both print one JSON envelope per command: {"ok":true,"data":...} or {"ok":false,"error":{code,
message,suggestion,...}}. Both refer to elements by refs like @s8f3k2p9:e5 taken from a snapshot.
"""
import json
import os
import time


class Result:
    def __init__(self, ok, data=None, error=None, ms=0, argv=None, raw=""):
        self.ok, self.data, self.error, self.ms, self.argv, self.raw = ok, data, error, ms, argv, raw

    @property
    def code(self):
        return (self.error or {}).get("code")

    @property
    def suggestion(self):
        return (self.error or {}).get("suggestion") or ""

    def brief(self):
        d = {"ok": self.ok, "ms": self.ms}
        if self.error:
            d.update(code=self.code, suggestion=self.suggestion, retry=self.error.get("retry"),
                     message=str(self.error.get("message", ""))[:200])
        return d


def normalize_error(err):
    """The two tools word errors alike enough to compare: code, message, suggestion, retry."""
    if not isinstance(err, dict):
        return {"code": "unparsed", "message": str(err)[:200], "suggestion": "", "retry": None}
    retry = err.get("retry")
    if retry is None:
        retry = (err.get("disposition") or {}).get("retry")
    return {"code": str(err.get("code", "")).lower() or "error", "message": err.get("message", ""),
            "suggestion": err.get("suggestion") or "", "retry": retry}


def parse_envelope(stdout):
    """The last JSON object on stdout carrying "ok", as (ok, data, error), or None."""
    for line in reversed([ln for ln in stdout.strip().splitlines() if ln.strip()]):
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(obj, dict) and "ok" in obj:
            if obj["ok"]:
                return True, obj.get("data"), None
            return False, None, normalize_error(obj.get("error"))
    return None


class Driver:
    name = "?"
    needs_ref_for_press = False

    def __init__(self, exec_fn):
        self.exec = exec_fn

    def resolve(self):
        raise NotImplementedError

    def build(self, verb, **kw):
        raise NotImplementedError

    def run(self, verb, timeout=60, **kw):
        argv = self.build(verb, **kw)
        rc, out, err, ms = self.exec(argv, timeout=timeout)
        env = parse_envelope(out)
        if env is None:
            msg = (err or out or "no output").strip()[:300]
            return Result(False, None, {"code": "no_envelope" if rc != 124 else "timeout", "message": msg,
                                        "suggestion": "", "retry": None}, ms, argv, out[:500])
        ok, data, error = env
        return Result(ok, data, error, ms, argv, "")

    def snapshot(self, wid, surface=None):
        return self.run("snapshot", wid=wid, surface=surface)

    def pid_windows(self, app, pid):
        """-> (ok, [window ids]) of every window the process `pid` owns, on every workspace (agent-desktop lists them
        all). ok is False when the listing failed, which a caller must treat as 'cannot tell', never as 'none'."""
        res = self.run("list-windows", app=app)
        if not res.ok or not isinstance(res.data, list):
            return False, []
        return True, [w.get("id") for w in res.data if w.get("pid") == pid]


class BaneySpacesDriver(Driver):
    name = "baneyspaces"
    needs_ref_for_press = True

    def __init__(self, exec_fn, binary="baneyspaces"):
        super().__init__(exec_fn)
        self.bin = binary

    def resolve(self):
        path = which(self.bin)
        return (path is not None, path or f"{self.bin}: not found on PATH (set BENCH_BANEYSPACES)")

    def build(self, verb, wid=None, surface=None, ref=None, text=None, key=None, direction=None,
              amount=None, option=None, prop=None):
        a = [self.bin, "agent"]
        if verb == "snapshot":
            a += ["snapshot", "--window", str(wid)]
            if surface and surface != "window":
                a += ["--surface", surface]
        elif verb in ("click", "toggle"):
            a += [verb, ref]
        elif verb in ("type", "set-value"):
            a += [verb, "--", ref, text]
        elif verb == "press":
            a += ["press", "--", ref, key]
        elif verb == "scroll":
            a += ["scroll", ref, direction, "--amount", str(amount or 3)]
        elif verb == "select":
            a += ["select", ref] + ([option] if option else [])
        elif verb == "get":
            a += ["get", ref, prop or "value"]
        else:
            raise ValueError(verb)
        return a


class AgentDesktopDriver(Driver):
    name = "agent-desktop"

    def __init__(self, exec_fn, binary, headed=False):
        super().__init__(exec_fn)
        self.bin = binary
        self.headed = headed
        if headed:
            self.name = "agent-desktop-headed"

    def resolve(self):
        ok = bool(self.bin) and os.access(self.bin, os.X_OK)
        return ok, self.bin if ok else "not built: run bench/build-agent-desktop.sh"

    @staticmethod
    def w(wid):
        return wid if str(wid).startswith("w-") else f"w-{wid}"

    def build(self, verb, wid=None, surface=None, ref=None, text=None, key=None, direction=None,
              amount=None, option=None, prop=None, app=None):
        head = ["--headed"] if self.headed else []
        a = [self.bin]
        if verb == "snapshot":
            a += ["snapshot", "--window-id", self.w(wid)]
            if surface and surface != "window":
                a += ["--surface", surface]
        elif verb == "list-windows":
            a += ["list-windows", "--app", app]
        elif verb in ("click", "toggle"):
            a += [verb] + head + ["--", ref]
        elif verb in ("type", "set-value"):
            a += [verb] + head + ["--", ref, text]
        elif verb == "press":
            a += ["press"] + head + ["--window-id", self.w(wid), "--", key]
        elif verb == "scroll":
            a += ["scroll"] + head + ["--direction", direction, "--amount", str(amount or 3), "--", ref]
        elif verb == "select":
            a += ["select"] + head + ["--", ref, option or ""]
        elif verb == "get":
            a += ["get", "--property", prop or "value", "--", ref]
        else:
            raise ValueError(verb)
        return a


def which(name):
    if os.path.isabs(name):
        return name if os.access(name, os.X_OK) else None
    for d in os.environ.get("PATH", "").split(os.pathsep):
        p = os.path.join(d, name)
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


class Opener:
    """`baneyspaces agent open`, used for every tool so all of them act on the same windows."""

    def __init__(self, exec_fn, binary="baneyspaces"):
        self.exec = exec_fn
        self.bin = binary

    def windows(self):
        """{id: (app, title)} on the agent workspace, from `agent status` (every build prints it)."""
        _, out, _, _ = self.exec([self.bin, "agent", "status"], timeout=15)
        found = {}
        for line in out.splitlines():
            parts = line.split("\t")
            if len(parts) >= 3 and parts[0].strip().isdigit():
                found[int(parts[0])] = (parts[1], parts[2])
        return found

    PROFILE_FLAG = "--user-data-dir"

    def supports_profile(self):
        """Does this build's `agent open` take --user-data-dir? Read from its usage text (a call with no app
        is refused before it does anything)."""
        if getattr(self, "_profile_ok", None) is None:
            _, out, err, _ = self.exec([self.bin, "agent", "open"], timeout=15)
            self._profile_ok = self.PROFILE_FLAG in (out + err)
        return self._profile_ok

    def pid_of(self, wid):
        _, out, _, _ = self.exec([self.bin, "agent", "windows"], timeout=15)
        env = parse_envelope(out)
        if env and env[0] and isinstance(env[1], dict):
            for w in env[1].get("windows", []):
                if w.get("id") == wid:
                    return w.get("pid")
        return None

    def open_isolated(self, app, targets, profile_dir):
        """Open `app` with a fresh profile under `profile_dir` and verify it: the window's process must really have
        --user-data-dir=<profile_dir> in its arguments. -> (window id or None, ms, verified)."""
        wid, ms = self.open(app, [self.PROFILE_FLAG, profile_dir, *targets])
        if wid is None:
            return None, ms, False
        pid = self.pid_of(wid)
        if not pid:
            return wid, ms, False
        _, out, _, _ = self.exec(["ps", "-o", "command=", "-p", str(pid)], timeout=10)
        ok = f"{self.PROFILE_FLAG}={profile_dir}" in out or f"{self.PROFILE_FLAG} {profile_dir}" in out
        return wid, ms, ok

    def open(self, app, targets=()):
        """Open `app` (with `targets`) on the agent workspace; return (window id or None, ms)."""
        before = set(self.windows())
        _, out, _, ms = self.exec([self.bin, "agent", "open", app, *targets], timeout=30)
        env = parse_envelope(out)
        if env and env[0] and isinstance(env[1], dict) and env[1].get("window"):
            return int(env[1]["window"]), ms
        if env and not env[0]:
            return None, ms
        for _ in range(40):  # plain-text build: the window arrives a moment later
            # only a new window OF THE APP WE OPENED; if several qualify we cannot tell which is ours, so none is
            new = [w for w, (a, _t) in self.windows().items() if w not in before and a == app]
            if len(new) == 1:
                return new[0], ms
            if len(new) > 1:
                return None, ms
            time.sleep(0.15)
        return None, ms
