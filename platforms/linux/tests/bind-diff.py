#!/usr/bin/python3
"""Compares `hyprctl -j binds` before and after BaneySpaces' include is loaded.

    bind-diff.py before.json after.json spec/keys.json

Every binding Omarchy (or you) had must still be there, untouched, unless spec/keys.json says BaneySpaces replaces
that key. Prints one MISMATCH line per violation and a summary; exit 1 on any violation."""
import json, sys

MODS = {"SUPER": 64, "SHIFT": 1, "ALT": 8, "CTRL": 4}

# Hyprland reports a `code:N` binding with key "" and keycode 0, so such a binding is told apart by its description:
# Omarchy's "Switch to workspace N" (SUPER), "Move window to workspace N" (SUPER SHIFT), "... silently ..." (SUPER SHIFT ALT).
CODE_DESC = {64: "Switch to workspace {n}", 65: "Move window to workspace {n}", 73: "Move window silently to workspace {n}"}

def ident(b):
    if b.get("key", "") == "" and not b.get("keycode") and not b.get("mouse"):
        return (b["modmask"], "code", b.get("description", ""), bool(b.get("release")), b.get("submap", ""))
    return (b["modmask"], b["key"].upper(), b.get("keycode", 0), bool(b.get("release")), bool(b.get("mouse")), b.get("submap", ""))

def parse(k):
    mods, key, code = 0, "", 0
    for part in [p.strip() for p in k.split("+")]:
        if part in MODS: mods |= MODS[part]
        elif part.startswith("code:"): code = int(part[5:])
        else: key = part.upper()
    if code:
        # Omarchy's workspace 1 to 9 keys; the others are not replaced
        return (mods, "code", CODE_DESC[mods].format(n=code - 9), False, "")
    return (mods, key, 0, False, False, "")

def main():
    before, after = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
    replaced = {parse(k) for k in json.load(open(sys.argv[3]))["platforms"]["linux"]["replaces"]}
    bad, kept, gone = [], 0, 0
    # A Lua callback's `arg` is a counter that changes on every config load, so it is not compared.
    def sig(b): return (b.get("dispatcher"), None if b.get("dispatcher") == "__lua" else b.get("arg"), b.get("description"), b.get("locked"), b.get("repeat"), b.get("non_consuming"))
    by_after = {}
    for b in after: by_after.setdefault(ident(b), []).append(sig(b))
    for b in before:
        i = ident(b)
        if i in replaced:
            gone += 1
            if any(not str(x[2] or "").startswith("BaneySpaces") for x in by_after.get(i, [])):
                bad.append(f"{b.get('description')}: {i} is meant to be replaced but Omarchy's binding is still there")
            continue
        if sig(b) in by_after.get(i, []): kept += 1
        else: bad.append(f"{b.get('description')} {i}: changed or gone ({by_after.get(i)})")
    before_ids = {ident(b) for b in before}
    new = [b for b in after if ident(b) not in before_ids or (ident(b) in replaced)]
    foreign = [b for b in new if not str(b.get("description", "")).startswith("BaneySpaces")]
    for b in foreign: bad.append(f"after: a binding that is not BaneySpaces' appeared: {b.get('description')} {ident(b)}")
    print(f"before {len(before)} bindings, after {len(after)}: {kept} untouched, {gone} replaced by BaneySpaces, {len(new)} BaneySpaces bindings added")
    for line in bad: print("MISMATCH", line)
    sys.exit(1 if bad else 0)

main()
