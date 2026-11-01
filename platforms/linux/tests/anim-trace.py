#!/usr/bin/python3
"""Watches what the compositor shows while a command runs, with Omarchy's own workspace animation on.

    anim-trace.py '<hyprctl-socket command>' ...    e.g. '/dispatch hl.dsp.exec_cmd("baneyspaces switch 3")'

Polls `j/monitors` every ~2 ms for 1.4 s after each command and prints the distinct states in order as JSON:
[[active workspace id, special workspace name], ...] for the focused monitor. A glitch would be a state that is neither
where you were nor where you went (a third workspace flashing, the agent workspace coming back after it was hidden)."""
import json, os, socket, sys, time

run = os.environ["XDG_RUNTIME_DIR"]; sig = os.environ["HYPRLAND_INSTANCE_SIGNATURE"]
if not run.startswith("/tmp/bs-nested."): sys.exit("refusing: not the nested session")
d = f"{run}/hypr/{sig}"

def ask(cmd):
    c = socket.socket(socket.AF_UNIX); c.connect(f"{d}/.socket.sock"); c.sendall(cmd.encode()); c.shutdown(socket.SHUT_WR)
    out = b""
    while True:
        b = c.recv(65536)
        if not b: break
        out += b
    c.close(); return out.decode()

def state():
    m = json.loads(ask("j/monitors"))
    f = next((x for x in m if x["focused"]), m[0])
    return [f["activeWorkspace"]["id"], f["specialWorkspace"]["name"]]

out = []
for cmd in sys.argv[1:]:
    seq = [state()]
    ask(cmd); end = time.monotonic() + 1.4
    while time.monotonic() < end:
        s = state()
        if s != seq[-1]: seq.append(s)
        time.sleep(0.002)
    out.append(seq)
print(json.dumps(out))
