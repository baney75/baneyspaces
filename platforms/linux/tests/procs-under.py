#!/usr/bin/python3 -I
"""List (scan) or kill (kill) every process whose command line, or XDG_RUNTIME_DIR, names a directory.

    procs-under.py <dir> scan|term|kill

nested.sh uses it so that nothing started inside its temp dir (the nested Hyprland, the per-agent
session buses, the accessibility stack) outlives the run. It never touches itself or its ancestors.
Prints "<pid> <command>" for each hit; exit status 1 when there were hits.
"""
import os
import signal
import sys

target, mode = sys.argv[1], sys.argv[2]
skip = set()
p = os.getpid()
while p > 1:
    skip.add(p)
    try:
        with open(f"/proc/{p}/stat") as f:
            p = int(f.read().rsplit(")", 1)[1].split()[1])
    except (OSError, ValueError, IndexError):
        break
hits = 0
for name in os.listdir("/proc"):
    if not name.isdigit() or int(name) in skip:
        continue
    pid = int(name)
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            cmd = f.read().replace(b"\0", b" ").decode("utf-8", "replace")
        env = b""
        try:
            with open(f"/proc/{pid}/environ", "rb") as f:
                env = f.read()
        except OSError:
            pass
    except OSError:
        continue
    in_env = any(kv.startswith(b"XDG_RUNTIME_DIR=") and target.encode() in kv for kv in env.split(b"\0"))
    if target in cmd or in_env:
        hits += 1
        print(pid, cmd[:110])
        if mode in ("kill", "term"):
            try:
                os.kill(pid, signal.SIGKILL if mode == "kill" else signal.SIGTERM)
            except OSError:
                pass
sys.exit(1 if hits else 0)  # 0: none, 1: hits (anything else: the scan itself failed)
