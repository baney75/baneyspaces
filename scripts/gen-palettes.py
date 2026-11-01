#!/usr/bin/env python3
"""Regenerate spec/palettes.json from Omarchy's bundled themes (MIT, github.com/basecamp/omarchy).

    python3 -I scripts/gen-palettes.py /usr/share/omarchy/themes > spec/palettes.json
"""
import json, os, sys, tomllib

ROLES = {  # BaneySpaces role: Omarchy colors.toml key, in order of preference
    "background": ["background"],
    "surface": ["lighter_background", "background"],
    "sunken": ["dark_background", "background"],
    "foreground": ["foreground"],
    "strong": ["bright_foreground", "light_foreground", "foreground"],
    "muted": ["dark_foreground", "muted"],
    "border": ["muted", "dark_foreground"],
    "accent": ["accent", "blue"],
    "selection": ["selection", "lighter_background"],
    "urgent": ["red"],
    "working": ["yellow"],
    "done": ["green"],
}

def palette(path):
    with open(path, "rb") as f:
        c = tomllib.load(f)
    out = {"mode": c.get("mode", "dark")}
    for role, keys in ROLES.items():
        v = next((c[k] for k in keys if isinstance(c.get(k), str)), None)
        if v is None:
            raise SystemExit(f"{path}: no color for {role}")
        out[role] = v.lower()
    return out

root = sys.argv[1]
pal = {n: palette(os.path.join(root, n, "colors.toml"))
       for n in sorted(os.listdir(root)) if os.path.isfile(os.path.join(root, n, "colors.toml"))}
json.dump({"source": "Omarchy themes (MIT), github.com/basecamp/omarchy, colors.toml",
           "roles": list(ROLES), "palettes": pal}, sys.stdout, indent=1)
print()
