#!/usr/bin/env bash
# The `agent shot` speed ratchet, in a nested headless Hyprland (nested.sh), on a release build.
# It times `baneyspaces agent shot` end to end (the CLI's own run included, as an agent sees it) on a
# still foot window, and fails when the median is over `linuxAgentShot.medianMs` in spec/speed.json
# times its `regressionLimit`. It also fails when a shot stops meaning what `evidence.settled` says:
# the still window must settle, and a window that keeps drawing (foot printing without pause, and mpv
# playing a test pattern when mpv is installed) must not. The PNG must decode to grim's own raw
# frame of the window. CI cannot run it (no Hyprland on Ubuntu runners): run it on an Omarchy seat.
#
#   platforms/linux/tests/shot-speed.sh                 # check against spec/speed.json
#   platforms/linux/tests/shot-speed.sh --runs 30       # more shots
#   platforms/linux/tests/shot-speed.sh --measure       # print the numbers, compare nothing
#   platforms/linux/tests/shot-speed.sh --write         # record this run's numbers as the target
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"

if [ -z "${NESTED_TMP:-}" ]; then
  # Outside: nested.sh builds the release binary, starts the nested session and runs this file in it.
  NESTED_PROFILE=release NESTED_ONLY="$HERE/shot-speed.sh" NESTED_ARGS="$*" exec "$HERE/nested.sh"
fi

RUNS=15; MODE=check
while [ $# -gt 0 ]; do
  case "$1" in
    --runs) RUNS="$2"; shift 2;;
    --measure) MODE=measure; shift;;
    --write) MODE=write; shift;;
    *) echo "FAIL: unknown argument $1"; exit 2;;
  esac
done
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1${2:+ -- $2}"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
ctl() { echo "$1" | socat -t 60 - UNIX-CONNECT:"$XDG_RUNTIME_DIR/baneyspaces/ctl.sock"; }
test_open() { # like `agent open`, but with arguments (a test op)
  local argv; argv="$(printf '%s\0' "${@:2}" | jq -Rsc 'split("\u0000")[:-1]')"
  ctl "$(jq -nc --arg app "$1" --argjson argv "$argv" '{op:"test_open",args:{app:$app,args:$argv,private_bus:true}}')"
}
wait_title() { # wait_title <regex>: the address of the first window whose title matches
  for _ in $(seq 1 150); do
    local a; a="$(hyprctl -j clients | jq -r "[.[]|select(.title|test(\"$1\"))|.address]|first // empty")"
    [ -n "$a" ] && { echo "$a"; return; }; sleep 0.1
  done
}
shot() { baneyspaces agent shot --window "$1"; }
pct() { # pct <percent> <numbers...>: nearest-rank percentile
  local p="$1"; shift
  printf '%s\n' "$@" | sort -n | awk -v p="$p" '{ v[NR] = $1 } END { i = int((p * NR + 99) / 100); if (i < 1) i = 1; print v[i] }'
}

echo "== agent shot speed ($(baneyspaces --version 2>/dev/null | head -1), release build, $RUNS runs)"
W="$(baneyspaces agent open foot --wait 10 | jq -r '.data.window // empty')"
[ -n "$W" ] || { echo "FAIL: agent open foot"; exit 1; }
sleep 1
echo "  the still window: foot, $(hyprctl -j clients | jq -r ".[]|select(.address==\"$W\")|\"\\(.size[0])x\\(.size[1])\"")"
shot "$W" >/dev/null; shot "$W" >/dev/null   # the first shot after a window maps can show an older frame
MS=(); FRAMES=()
for _ in $(seq 1 "$RUNS"); do
  t0=$(date +%s%N); R="$(shot "$W")"; t1=$(date +%s%N)
  MS+=($(( (t1 - t0) / 1000000 ))); FRAMES+=("$(echo "$R" | jq -r '"\(.ok) \(.data.evidence.frames) \(.data.evidence.settled)"')")
done
MEDIAN="$(pct 50 "${MS[@]}")"; P90="$(pct 90 "${MS[@]}")"
echo "  shot ms: ${MS[*]}"
echo "  median $MEDIAN ms, p90 $P90 ms"
eq "every shot of the still window is ok and settled" "$(printf '%s\n' "${FRAMES[@]}" | awk '$1 != "true" || $3 != "true"' | wc -l)" "0"
grep -E "shot $W: " "$NESTED_TMP/daemon.log" | tail -1 | sed 's/^/  last trace: /'

echo "== what the picture is"
R="$(shot "$W")"; P="$(echo "$R" | jq -r .data.path)"
S="$(hyprctl -j clients | jq -r ".[]|select(.address==\"$W\")|.stableId")"
grim -t ppm -T "$S" "$NESTED_TMP/raw.ppm"
eq "the PNG decodes to grim's own raw frame of the window, pixel for pixel" "$(/usr/bin/python3 -I -c '
import sys, zlib
png, ppm = open(sys.argv[1], "rb").read(), open(sys.argv[2], "rb").read()
p, idat, ihdr = 8, b"", None
while True:
    n = int.from_bytes(png[p:p + 4], "big"); kind = png[p + 4:p + 8]; body = png[p + 8:p + 8 + n]
    assert zlib.crc32(kind + body) == int.from_bytes(png[p + 8 + n:p + 12 + n], "big"), "crc"
    if kind == b"IHDR": ihdr = body
    if kind == b"IDAT": idat += body
    if kind == b"IEND": break
    p += 12 + n
w, h, colour = int.from_bytes(ihdr[0:4], "big"), int.from_bytes(ihdr[4:8], "big"), ihdr[9]
bpp = {2: 3, 6: 4}[colour]; s = w * bpp; raw = zlib.decompress(idat); out = bytearray(); up = bytearray(s)
for i in range(h):
    f, r = raw[i * (s + 1)], bytearray(raw[i * (s + 1) + 1:(i + 1) * (s + 1)])
    for x in range(s):
        a = r[x - bpp] if x >= bpp else 0; b = up[x]; c = up[x - bpp] if x >= bpp else 0
        if f == 1: r[x] = (r[x] + a) & 255
        elif f == 2: r[x] = (r[x] + b) & 255
        elif f == 3: r[x] = (r[x] + (a + b) // 2) & 255
        elif f == 4:
            pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
            r[x] = (r[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
    out += r if bpp == 3 else bytes(v for k, v in enumerate(r) if k % 4 != 3); up = r
head = b"P6\n%d %d\n255\n" % (w, h)
print("same" if ppm == head + bytes(out) else "different")' "$P" "$NESTED_TMP/raw.ppm" 2>&1)" "same"
echo "  size: $(stat -c %s "$P") bytes here, $(grim -t png -T "$S" - | wc -c) bytes from grim's own PNG (colour type $(od -An -tu1 -j25 -N1 "$P" | tr -d ' '))"

echo "== a window that keeps drawing never settles"
test_open /usr/bin/foot -T busy sh -c 'while :; do date +%s%N; done' >/dev/null
B="$(wait_title '^busy$')"; sleep 1
for _ in 1 2 3; do
  eq "foot printing without pause: settled false after every capture" "$(shot "$B" | jq -c '[.ok, .data.evidence.settled, .data.evidence.frames]')" "[true,false,5]"
done
if command -v mpv >/dev/null; then
  test_open /usr/bin/mpv --loop=inf --no-audio --title=pattern "av://lavfi:testsrc=size=640x480:rate=60" >/dev/null
  V="$(wait_title '^pattern$')"; sleep 2
  for _ in 1 2 3; do
    eq "mpv playing a test pattern: settled false" "$(shot "$V" | jq -c '[.ok, (if .ok then .data.evidence.settled else .error.code end)]')" "[true,false]"
  done
else
  echo "  (mpv is not installed: a playing video is not checked)"
fi

SPEC="$REPO/spec/speed.json"
case "$MODE" in
  measure) ;;
  write)
    T="$(mktemp)"
    jq --argjson m "$MEDIAN" --argjson p "$P90" --argjson n "$RUNS" --arg on "$(date +%F), $(uname -n), Hyprland $(hyprctl version -j | jq -r .tag) nested" \
      '.linuxAgentShot = ((.linuxAgentShot // {}) + {medianMs: $m, p90Ms: $p, runs: $n, measuredOn: $on})' "$SPEC" >"$T" && mv "$T" "$SPEC"
    echo "  wrote medianMs $MEDIAN and p90Ms $P90 to spec/speed.json";;
  check)
    BASE="$(jq -r '.linuxAgentShot.medianMs // empty' "$SPEC")"; LIMIT="$(jq -r '.linuxAgentShot.regressionLimit // 1.25' "$SPEC")"
    if [ -z "$BASE" ]; then bad "spec/speed.json has a linuxAgentShot target"
    else
      MAX="$(awk -v b="$BASE" -v l="$LIMIT" 'BEGIN { printf "%d", b * l }')"
      if [ "$MEDIAN" -le "$MAX" ]; then ok "median $MEDIAN ms is within $LIMIT x the $BASE ms target ($MAX ms)"
      else bad "median $MEDIAN ms is over $LIMIT x the $BASE ms target ($MAX ms)"; fi
    fi;;
esac

echo
if [ "$FAIL" -eq 0 ]; then echo "PASS: shot-speed.sh ($PASS checks)"; exit 0; else echo "FAIL: shot-speed.sh ($FAIL of $((PASS+FAIL)) checks)"; exit 1; fi
