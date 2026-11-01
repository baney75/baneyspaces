#!/bin/bash
# Builds scripts/launcher-files-timing.swift with the Core files it uses and runs it. It reads your
# Spotlight index and nothing else.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
swiftc -O -parse-as-library -o "$OUT/timing" scripts/launcher-files-timing.swift \
  Sources/BaneySpacesCore/FileSearch.swift Sources/BaneySpacesCore/FileSearchFlow.swift Sources/BaneySpacesCore/Launcher.swift \
  Sources/BaneySpacesCore/Workspaces.swift Sources/BaneySpacesCore/Geometry.swift 2>&1 | grep -v warning || true
"$OUT/timing"
