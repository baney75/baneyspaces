#!/usr/bin/python3
"""Key-to-compositor latency of a workspace switch, native versus BaneySpaces, inside the nested Hyprland.

    latency.py <n-samples> <command-for-native|ours> ...

Native is what Omarchy's own bind runs: Hyprland's `hl.dsp.focus({ workspace = N })`, in the compositor, no process.
Ours is what the BaneySpaces bind runs: `baneyspaces_switch(N)` (a Lua function in the include: Hyprland's own focus when
that is exactly what the daemon would do, which is the usual switch). `ours_daemon` is the other path, for a workspace the
function hands to the daemon: `hl.dsp.exec_raw("baneyspaces switch N")`, so a shell, the CLI, the daemon and its dispatches. Both are sent over Hyprland's own socket (the moment a key bind fires) and timed until Hyprland reports
`workspacev2` for that workspace (the compositor has switched; the next frame shows it, the same for both).
Prints JSON: {native:{p50,p90,max}, ours:{...}, samples}."""
import json, os, socket, sys, time, select

run = os.environ["XDG_RUNTIME_DIR"]; sig = os.environ["HYPRLAND_INSTANCE_SIGNATURE"]
d = f"{run}/hypr/{sig}"
if not run.startswith("/tmp/bs-nested."): sys.exit("refusing: not the nested session")

def events():
    s = socket.socket(socket.AF_UNIX); s.connect(f"{d}/.socket2.sock"); s.setblocking(False); return s

def send(cmd):
    c = socket.socket(socket.AF_UNIX); c.connect(f"{d}/.socket.sock"); c.sendall(cmd.encode()); c.shutdown(socket.SHUT_WR); c.recv(64); c.close()

def wait_ws(ev, n, buf, timeout=3.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        r, _, _ = select.select([ev], [], [], 0.05)
        if r:
            buf[0] += ev.recv(65536).decode(errors="replace")
        while "\n" in buf[0]:
            line, buf[0] = buf[0].split("\n", 1)
            if line.startswith("workspacev2>>") and line.split(">>")[1].split(",")[0] == str(n):
                return time.monotonic()
    return None

def stats(v):
    v = sorted(v); return {"p50": round(v[len(v) // 2] * 1000, 2), "p90": round(v[int(len(v) * 0.9)] * 1000, 2), "max": round(v[-1] * 1000, 2), "n": len(v)}

def main():
    samples = int(sys.argv[1]); ours_bin = sys.argv[2] if len(sys.argv) > 2 else "baneyspaces"
    ev = events(); buf = [""]
    cycle = [3, 4, 5, 6, 7, 8, 9, 4, 6, 8, 3, 5, 7, 9]
    nat, our, slow = [], [], []
    for i in range(samples * 3):
        n = cycle[(i // 3) % len(cycle)]
        kind = i % 3          # 0 native, 1 the bind's function, 2 the daemon path
        # go back to a known workspace first so the next one is always a real switch
        send('/dispatch hl.dsp.focus({ workspace = "1" })'); wait_ws(ev, 1, buf); time.sleep(0.05)
        buf[0] = ""
        t0 = time.monotonic()
        if kind == 0: send(f'/dispatch hl.dsp.focus({{ workspace = "{n}" }})')
        elif kind == 1: send(f'/eval baneyspaces_switch({n})')
        else: send(f'/dispatch hl.dsp.exec_raw("{ours_bin} switch {n}")')
        t1 = wait_ws(ev, n, buf)
        if t1 is None: continue
        (nat, our, slow)[kind].append(t1 - t0)
        time.sleep(0.04)
    print(json.dumps({"native": stats(nat), "ours": stats(our), "ours_daemon": stats(slow), "samples": samples}))
main()
