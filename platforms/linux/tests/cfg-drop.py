#!/usr/bin/python3
"""Removes a table and its sub-tables from a TOML file by hand, as a person editing the file would.
    cfg-drop.py <file> <table>      e.g. cfg-drop.py config.toml theme.override"""
import sys
path, table = sys.argv[1], sys.argv[2]
out, skip = [], False
for line in open(path).read().split("\n"):
    t = line.strip()
    if t.startswith("["):
        name = t.strip("[]").strip()
        skip = name == table or name.startswith(table + ".")
    if not skip:
        out.append(line)
open(path, "w").write("\n".join(out))
