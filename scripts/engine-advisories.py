#!/usr/bin/env python3
"""Fails the engine build when a known advisory (osv.dev) touches a crate the macOS build links.

The pinned engine's Cargo.lock lists crates for every platform. Its first vet (2026-10-31) found
three RustSec advisories, all in Linux-only D-Bus crates the macOS build never compiles. So only
the crates `cargo tree` reports for the macOS target count here; an advisory on any other crate in
the lockfile is printed and ignored. Run from engine/.src with the target triple as the argument.
Without network access the check says so and fails: a build that can't check isn't checked.
"""
import json
import subprocess
import sys
import urllib.request

target = sys.argv[1]
tree = subprocess.run(
    ["cargo", "tree", "--locked", "--target", target, "-p", "agent-desktop-ffi", "-e", "normal,build",
     "--prefix", "none", "--format", "{p}"],
    check=True, capture_output=True, text=True).stdout.split("\n")
linked = {}
for line in tree:
    parts = line.replace(" (*)", "").split(" ")
    if len(parts) >= 2 and parts[1].startswith("v") and "(" not in parts[0]:
        linked[parts[0]] = parts[1][1:]

lock = {}
name = None
for raw in open("Cargo.lock"):
    raw = raw.strip()
    if raw.startswith('name = "'):
        name = raw.split('"')[1]
    elif raw.startswith('version = "') and name:
        lock.setdefault(name, []).append(raw.split('"')[1])
        name = None

queries = [{"package": {"name": n, "ecosystem": "crates.io"}, "version": v}
           for n, vs in sorted(lock.items()) for v in vs]
hits = {}
try:
    for i in range(0, len(queries), 500):
        body = json.dumps({"queries": queries[i:i + 500]}).encode()
        req = urllib.request.Request("https://api.osv.dev/v1/querybatch", body, {"Content-Type": "application/json"})
        results = json.load(urllib.request.urlopen(req, timeout=60))["results"]
        for q, r in zip(queries[i:i + 500], results):
            for v in r.get("vulns", []):
                hits.setdefault(q["package"]["name"], []).append((q["version"], v["id"]))
except OSError as e:
    sys.exit(f"engine: couldn't reach osv.dev for the advisory check ({e}). Build again with a network.")

bad = {n: h for n, h in hits.items() if n in linked and any(v == linked[n] for v, _ in h)}
for n, h in sorted(hits.items()):
    where = "LINKED on macOS" if n in bad else "not linked on macOS, ignored"
    print(f"engine: advisory on {n}: {', '.join(sorted({i for _, i in h}))} ({where})")
if bad:
    sys.exit("engine: an advisory touches a crate the macOS build links; not building.")
print(f"engine: advisory check ok ({len(linked)} crates linked on {target}, {len(lock)} in the lockfile)")
