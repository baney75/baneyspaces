#!/usr/bin/python3
"""Checks what the shell plugin's surfaces drew against spec/themes.json and spec/palettes.json.

    theme-check.py <frames.json> <theme> <palette-name | auto:<colors.toml>>

`frames.json` is the plugin's `baneyspaces.theme frames` answer: every PanelFrame of every surface (dock,
dock tile, +N list, switcher, launcher, overview, settings) with the radius, border and fill it drew. Prints
one line per mismatch and exits 1 if there is any. Exit 2: the check could not run."""
import json, os, sys, tomllib

spec_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "spec")
themes = json.load(open(os.path.join(spec_dir, "themes.json")))
palettes = json.load(open(os.path.join(spec_dir, "palettes.json")))
ROLES = {"background": ["background"], "surface": ["lighter_background", "background"], "sunken": ["dark_background", "background"],
         "foreground": ["foreground"], "strong": ["bright_foreground", "light_foreground", "foreground"],
         "muted": ["dark_foreground", "muted"], "border": ["muted", "dark_foreground"], "accent": ["accent", "blue"],
         "selection": ["selection", "lighter_background"], "urgent": ["red"], "working": ["yellow"], "done": ["green"]}

def palette_of(arg):
    if arg.startswith("auto:"):
        c = tomllib.load(open(arg[5:], "rb"))
        return {r: next(c[k] for k in ks if isinstance(c.get(k), str)).lower() for r, ks in ROLES.items()}
    return palettes["palettes"][arg]

def rgb(h): return [int(h[i:i + 2], 16) for i in (1, 3, 5)]
def argb(h):  # "#aarrggbb" -> (alpha 0..255, "#rrggbb")
    return (int(h[1:3], 16), "#" + h[3:9]) if len(h) == 9 else (255, h[:7])
def mix(a, b, t): return "#" + "".join("%02x" % round(x + (y - x) * t) for x, y in zip(rgb(a), rgb(b)))

def main():
    frames = json.load(open(sys.argv[1]))
    theme, pal = sys.argv[2], palette_of(sys.argv[3])
    t = themes["themes"][theme]
    bad = []
    def role(name): return "#ffffff" if name == "light" else pal[name]
    if frames["theme"] != theme: bad.append(f"the plugin runs theme {frames['theme']}, not {theme}")
    for r in pal:
        if r != "mode" and frames["roles"].get(r) != pal[r]: bad.append(f"palette role {r}: {frames['roles'].get(r)} != {pal[r]}")
    if frames["indicator"] != t["indicator"]: bad.append(f"indicator {frames['indicator']} != {t['indicator']}")
    for k, v in t["motion"].items():
        pass
    seen = set()
    for item in frames["frames"]:
        s, f = item["surface"], item["frame"]
        seen.add(s)
        where = f"{s}/{f['kind']}"
        if f["radiusToken"] != t["radius"][f["kind"]]: bad.append(f"{where}: radius token {f['radiusToken']} != {t['radius'][f['kind']]}")
        if f["radius"] > f["radiusToken"] + 1e-6: bad.append(f"{where}: drew radius {f['radius']} over the token {f['radiusToken']}")
        b = t["border"]
        want_w = (b["focused_width"] if f["focused"] else b["width"]) if f["framed"] else 0
        if abs(f["borderWidth"] - want_w) > 1e-6: bad.append(f"{where}: border width {f['borderWidth']} != {want_w}")
        if f["framed"] and not f["focused"]:
            if f["borderColor"] != role(b["role"]): bad.append(f"{where}: border color {f['borderColor']} != {role(b['role'])}")
            if "gradient" in b:
                if f["gradient"] != {"top": b["gradient"][0], "bottom": b["gradient"][1]}: bad.append(f"{where}: border gradient {f['gradient']} != {b['gradient']}")
            elif f["borderOpacity"] is None or abs(f["borderOpacity"] - b["opacity"]) > 1e-6: bad.append(f"{where}: border opacity {f['borderOpacity']} != {b['opacity']}")
        if f["framed"] and f["focused"] and b["focused_role"] != "workspace" and f["borderColor"] != role(b["focused_role"]):
            bad.append(f"{where}: focused border {f['borderColor']} != {role(b['focused_role'])}")
        if not f["customFill"]:   # a panel: the theme's own fill
            a, c = argb(f["fill"])
            fl = t["fill"]
            op = fl["opacity"]
            if not fl["adjustable"] and abs(a / 255 - op) > 1 / 255 + 1e-6: bad.append(f"{where}: fill opacity {a / 255:.3f} != {op}")
            want = role(fl["tint_role"]) if fl["material"] is None else mix(pal["background"], role(fl["tint_role"]), fl["tint_opacity"])
            if max(abs(x - y) for x, y in zip(rgb(c), rgb(want))) > 1: bad.append(f"{where}: fill {c} != {want}")   # one step of rounding between JS and Python
        sh = f["shadow"]
        if sh is not None and t["shadow"] is None: bad.append(f"{where}: drew a shadow the theme does not have")
        if sh is not None and t["shadow"] is not None and sh != t["shadow"]: bad.append(f"{where}: shadow {sh} != {t['shadow']}")
    need = {"dock", "dock-tile", "switcher", "launcher", "overview", "settings"}
    for m in sorted(need - seen): bad.append(f"surface {m} drew nothing the check could read")
    for line in bad: print("MISMATCH", line)
    sys.exit(1 if bad else 0)

try:
    main()
except SystemExit: raise
except Exception as e:
    print("theme-check could not run:", e); sys.exit(2)
