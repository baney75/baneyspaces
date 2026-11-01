# Sourced by nested.sh: the Omarchy shell plugin (dock, switcher, launcher, overview, settings) in the
# nested session. Needs the helpers and variables nested.sh defines ($TMP, $REPO, eq, check, H, M1, M2 ...).

PLUGIN="$REPO/platforms/linux/omarchy/plugins/io.github.baney75.baneyspaces"
QSD="$TMP/qs"; mkdir -p "$QSD" "$TMP/shots"
cat >"$QSD/shell.qml" <<QML
import QtQuick
import Quickshell
ShellRoot { Loader { source: "file://$PLUGIN/Service.qml" } }
QML
# the user's active Omarchy theme (read only), so the shots look like the real thing
THEME_SRC="${OMARCHY_THEME_DIR:-$(readlink -f "$(getent passwd "$(id -un)" | cut -d: -f6)/.local/state/omarchy/current/theme" 2>/dev/null)}"
mkdir -p "$TMP/theme"; [ -f "$THEME_SRC/colors.toml" ] && cp "$THEME_SRC/colors.toml" "$TMP/theme/colors.toml"
export BANEYSPACES_THEME_DIR="$TMP/theme"
export QT_QPA_PLATFORM=wayland QT_QUICK_BACKEND="${QT_QUICK_BACKEND:-software}" QS_NO_RELOAD_POPUP=1
guard_nested   # a GUI process starts below: only ever inside the nested session
quickshell -p "$QSD/shell.qml" >"$TMP/quickshell.log" 2>&1 & QSPID=$!; PIDS+=($QSPID)
for _ in $(seq 1 100); do qs ipc -p "$QSD/shell.qml" call baneyspaces ping 2>/dev/null | grep -q ok && break; sleep 0.2; done
QI() { qs ipc -p "$QSD/shell.qml" call "$@" 2>&1; }

echo "== shell plugin: connected, themed, quiet"
client_ws() { H clients | jq -r ".[]|select(.address==\"$1\")|.workspace.name"; }
# An agent window the daemon accepts: a terminal it starts for an agent.
open_agent_window() { baneyspaces agent run -- sleep 600 | jq -r '.data.window // empty'; }
wait_for() { local t="$1"; shift; for _ in $(seq 1 $((t*10))); do "$@" >/dev/null 2>&1 && return 0; sleep 0.1; done; return 1; }
qs_state() { QI baneyspaces state | jq -r "$1"; }
check "the plugin reached the daemon's socket" wait_for 8 sh -c "qs ipc -p '$QSD/shell.qml' call baneyspaces state | jq -e .connected"
eq "it reads the Omarchy theme file" "$(qs_state .theme.accent)" "$(sed -n 's/^accent *= *"\(#[0-9a-fA-F]*\)".*/\1/p' "$TMP/theme/colors.toml" | head -1)"
check "the daemon counts a subscriber (state pushes work)" sh -c "baneyspaces ui | jq -e '.data.version==1 and (.data.workspaces|length)==9'"

# A clean, known set of windows: close yours, then open one workspace at a time the way a launcher does.
for a in $(H clients | jq -r '.[]|select(.workspace.name!="special:agent")|.address'); do hyprctl dispatch "hl.dsp.window.close({ window = \"address:$a\" })" >/dev/null; done; sleep 0.5
baneyspaces focus-monitor $M1 >/dev/null
goto() { # goto <monitor> <n>: be on that monitor, showing n, and wait until Hyprland agrees
  baneyspaces focus-monitor "$1" >/dev/null; baneyspaces switch "$2" >/dev/null
  for _ in $(seq 1 40); do [ "$(mon_ws "$1")" = "$2" ] && [ "$(H monitors | jq -r '.[]|select(.focused)|.name')" = "$1" ] && break; sleep 0.1; done; sleep 0.15
}
mkwin() { # mkwin <app-id> <title>: a window of an app, opened where you are
  hyprctl dispatch "hl.dsp.exec_cmd(\"foot -a '$1' -T '$2' sleep 600\")" >/dev/null
  for _ in $(seq 1 60); do H clients | jq -e ".[]|select(.title==\"$2\")" >/dev/null && break; sleep 0.1; done; sleep 0.15
}
addr_of() { H clients | jq -r ".[]|select(.title==\"$1\")|.address"; }
goto $M1 1
mkwin foot "claude — baneyspaces"; mkwin foot "build log"; mkwin chromium "Docs"; mkwin obsidian "Notes"; mkwin libreoffice-writer "Letter"; mkwin libreoffice-calc "Budget"
goto $M2 2
mkwin blender "Scene"; mkwin mpv "Video"
goto $M1 4
mkwin foot "⠂ Fix the dock"
goto $M1 6
mkwin foot "agent question"
goto $M1 1; sleep 0.3
eq "the snapshot has a tile for 1, 2, 4 and 6 and offers 3 as the new one" "$(baneyspaces ui | jq -c '[.data.dock.tiles,.data.dock.new_target]')" "[[1,2,4,6],3]"
eq "workspace 1 has five apps: three shown and a +2" "$(baneyspaces ui | jq -c '.data.workspaces[0]|[(.apps|length),(.shown_apps|length),(.more|length)]')" "[5,3,2]"
eq "two foot windows are one app on a tile" "$(baneyspaces ui | jq '.data.workspaces[0].apps[0].count')" "2"

echo "== agent status badges"
eq "a terminal title with Claude's spinner shows as working" "$(baneyspaces ui | jq -r '.data.workspaces[3].badge')" "working"
AQ="$(addr_of 'agent question')"
eq "a hook can say an agent is asking" "$(baneyspaces agent-status set asking --window "$AQ" | jq -r .data.state)" "asking"
eq "it reaches the tile" "$(baneyspaces ui | jq -r '.data.workspaces[5].badge')" "asking"
eq "an unknown state is refused" "$(baneyspaces agent-status set sleepy --window "$AQ" | jq -r .error.code)" "invalid_args"
eq "a window that is not there is not_found" "$(baneyspaces agent-status set working --window 0xdead | jq -r .error.code)" "not_found"
CL="$(addr_of 'claude — baneyspaces')"
baneyspaces agent-status set finished --window "$CL" >/dev/null
eq "finished shows on the app and counts" "$(baneyspaces ui | jq -c '[.data.workspaces[0].apps[0].badge,.data.agent.finished]')" '["finished",1]'
hyprctl dispatch "hl.dsp.focus({ window = \"address:$CL\" })" >/dev/null; sleep 0.3
eq "looking at it clears finished" "$(baneyspaces ui | jq -r '.data.workspaces[0].apps[0].badge')" "null"
baneyspaces agent-status set asking --window "$CL" >/dev/null; sleep 0.2
eq "hooks print is valid JSON with four hooks" "$(baneyspaces hooks print | jq '.hooks|length')" "4"

echo "== workspace dock"
D() { QI baneyspaces.dock "$@"; }
eq "auto-hide: the dock is down until the pointer rests on the edge" "$(D state | jq -r .wanted)" "false"
baneyspaces dock show >/dev/null; sleep 0.8
eq "dock show brings it up on the display you are on" "$(D state | jq -r '[.wanted,.screen]|join(",")')" "true,$M1"
eq "tiles: 1, 2, 4, 6 and the dashed one" "$(D state | jq -c '[.tiles[]|.n]|sort')" "[0,1,2,4,6]"
eq "each tile has its own apps" "$(D state | jq -c '[.tiles[]|select(.n==1)|.apps[]]')" '["foot","chromium","obsidian","libreoffice-writer","libreoffice-calc"]'
check "the tiles sit inside the bar and the bar on screen" sh -c "qs ipc -p '$QSD/shell.qml' call baneyspaces.dock state | jq -e '.bar as \$b | .tiles | all(.x >= \$b.x and .x + .w <= \$b.x + \$b.w and .y >= \$b.y and .y + .h <= \$b.y + \$b.h)'"
grim -g "$((960-480)),$((1080-170)) 960x170" "$TMP/shots/dock.png"
eq "clicking tile 4 goes there" "$(D clickTile 4 >/dev/null; sleep 0.3; mon_ws $M1)" "4"
D clickTile 1 >/dev/null; sleep 0.3
eq "clicking the dashed tile goes to the first empty workspace" "$(D clickTile 0 >/dev/null; sleep 0.3; mon_ws $M1)" "3"
D clickTile 1 >/dev/null; sleep 0.3
D clickApp 1 chromium >/dev/null; sleep 0.3
eq "clicking an app puts its window in front" "$(active)" "$(addr_of Docs)"
D clickApp 1 foot >/dev/null; sleep 0.3; F1="$(active)"; D clickApp 1 foot >/dev/null; sleep 0.3
check "clicking the app again goes to its next window" test "$(active)" != "$F1"

echo "== dock: the +N list, drag to a tile, the dashed tile"
eq "the +2 list holds the apps the tile cannot show (by their names)" "$(D openList 1 more >/dev/null; sleep 0.5; D state | jq -c '.list|[.kind,.rows]')" '["more",["LibreOffice Writer","LibreOffice Calc"]]'
eq "an open list is part of the dock's keep zone (the daemon knows its rect)" "$(sleep 0.3; baneyspaces ui | jq -r '.data.dock.list_open')" "true"
grim -g "$((960-480)),$((1080-350)) 960x350" "$TMP/shots/dock-overflow.png"
LW="$(addr_of Letter)"
eq "dragging a row from the list onto tile 2 moves that window there" "$(D dragRow 0 2 >/dev/null; sleep 0.4; client_ws $LW)" "2"
eq "and you stay where you are" "$(mon_ws $M1)" "1"
D closeList >/dev/null; sleep 0.3
eq "the list is gone" "$(D state | jq -r '.list')" "null"
OB="$(addr_of Notes)"
eq "dragging an app's icon onto tile 4 moves its windows there" "$(D dragApp 1 obsidian 4 >/dev/null; sleep 0.4; client_ws $OB)" "4"
eq "dropping on the dashed tile starts a new workspace (3) with it" "$(D dragApp 2 mpv 0 >/dev/null; sleep 0.4; client_ws "$(addr_of Video)")" "3"
eq "move-windows refuses a workspace number outside 1-9" "$(baneyspaces move-windows 12 $OB | jq -r .error.code)" "invalid_args"
eq "the model agrees with Hyprland" "$(baneyspaces state | jq -r ".data.windows[\"$OB\"].home")" "$(client_ws $OB)"

echo "== dock: the pointer decides when it is up (a real pointer in the nested session)"
baneyspaces dock hide >/dev/null; sleep 0.5
warp() { hyprctl dispatch "hl.dsp.cursor.move({ x = $1, y = $2 })" >/dev/null; }
warp 400 500; sleep 0.3
eq "pointer in the middle of the screen: the dock is down" "$(baneyspaces ui | jq -r .data.dock.up)" "false"
warp 960 1079; sleep 0.6
eq "pointer resting on the bottom edge: it comes up on that display" "$(baneyspaces ui | jq -r '[.data.dock.up,.data.dock.monitor]|join(",")')" "true,$M1"
sleep 0.8
eq "still resting where it opened it: it stays up" "$(baneyspaces ui | jq -r .data.dock.up)" "true"
BAR="$(D state | jq -c .bar)"; BY="$(echo "$BAR" | jq '.y|floor')"; BX="$(echo "$BAR" | jq '(.x+.w/2)|floor')"
warp "$BX" "$((BY + 20))"; sleep 0.9
eq "pointer on the bar: it stays up" "$(baneyspaces ui | jq -r .data.dock.up)" "true"
warp "$BX" "$((BY - 8))"; sleep 0.9
eq "8 pt above the bar (inside the 12 pt zone): it stays up" "$(baneyspaces ui | jq -r .data.dock.up)" "true"
warp "$BX" "$((BY - 30))"; sleep 0.9
eq "30 pt above the bar (outside the zone): it goes down" "$(baneyspaces ui | jq -r .data.dock.up)" "false"
check "the bar is invisible again after its fade" wait_for 2 sh -c "[ \"\$(qs ipc -p '$QSD/shell.qml' call baneyspaces.dock state | jq -r .visible)\" = false ]"
warp 960 1079; sleep 0.6; warp "$BX" "$((BY + 20))"; sleep 0.3
BAR="$(D state | jq -c .bar)"; BY="$(echo "$BAR" | jq '.y|floor')"; BARX="$(echo "$BAR" | jq '.x|floor')"   # the bar grew when tiles moved
warp "$((BARX + 4))" "$((BY + 20))"; sleep 0.3
D openList 1 foot >/dev/null; sleep 0.15
LRECT="$(D state | jq -c .list.rect)"; LX="$(echo "$LRECT" | jq '(.x+.w/2)|floor')"; LY="$(echo "$LRECT" | jq '(.y+.h/2)|floor')"; LW2="$(echo "$LRECT" | jq '(.w/2)|floor')"
warp "$LX" "$LY"; sleep 1.0
eq "with a list open, the pointer on the list keeps the dock up (and the list open)" "$(baneyspaces ui | jq -r '[.data.dock.up,.data.dock.list_open]|join(",")')" "true,true"
warp "$((LX + LW2 + 100))" "$LY"; sleep 1.2
eq "100 pt beside the list does not hold it: the list closes, then the dock goes down" "$(baneyspaces ui | jq -r '[.data.dock.up,.data.dock.list_open]|join(",")')" "false,false"
D closeList >/dev/null; warp 400 500; sleep 0.9
eq "everything goes down once the pointer leaves" "$(baneyspaces ui | jq -r .data.dock.up)" "false"
baneyspaces focus-monitor $M1 >/dev/null

echo "== Alt+Tab switcher"
SWI() { QI baneyspaces.switcher state; }
baneyspaces switch 1 >/dev/null; sleep 0.3; D clickApp 1 chromium >/dev/null; sleep 0.3
eq "the switcher is closed" "$(SWI | jq -r .open)" "false"
SW="$(baneyspaces switcher next)"
eq "the first press selects the window you used before" "$(echo "$SW" | jq -r '.data.index')" "1"
sleep 0.5
eq "the plugin shows it" "$(SWI | jq -r .open)" "true"
check "it lists windows from every workspace" test "$(echo "$SW" | jq '[.data.items[].workspace]|unique|length')" -ge 4
SWA="$(open_agent_window)"
check "an agent window is open" test -n "$SWA"
eq "an agent's window cannot be sent anywhere by a drag" "$(baneyspaces move-windows 5 "$SWA" | jq -r .error.code)" "agent_window"
eq "the agent workspace is never offered by the switcher" "$(baneyspaces switcher cancel >/dev/null; baneyspaces switcher next | jq --arg w "$SWA" '[.data.items[].window]|index($w)')" "null"
grim -o $M1 "$TMP/shots/switcher-full.png"; grim -g "$((960-800)),$((540-110)) 1600x220" "$TMP/shots/switcher.png"; rm -f "$TMP/shots/switcher-full.png"
baneyspaces switcher next >/dev/null; WANT="$(baneyspaces ui | jq -r '.data.switcher.items[.data.switcher.index].window')"; WANTWS="$(baneyspaces ui | jq -r '.data.switcher.items[.data.switcher.index].workspace')"
CM="$(baneyspaces switcher commit)"
eq "letting go goes to the selected window" "$(echo "$CM" | jq -r .data.window)" "$WANT"
sleep 0.4
sleep 0.3
eq "wherever it is: its workspace is now on the display you are on" "$(mon_ws $M1)" "$WANTWS"
eq "it is in front" "$(active)" "$WANT"
eq "the switcher is closed again" "$(baneyspaces ui | jq -r .data.switcher.open)" "false"
eq "Shift+Alt+Tab opens on the oldest window" "$(baneyspaces switcher prev | jq -r '.data.index == (.data.items|length-1)')" "true"
baneyspaces switcher cancel >/dev/null
eq "cancel changes nothing" "$(active)" "$WANT"

echo "== launcher"
LQ() { QI baneyspaces.launcher "$@"; }
baneyspaces launcher show >/dev/null; sleep 0.5
LQ type "foot" >/dev/null; sleep 0.6
check "typing finds the app" sh -c "qs ipc -p '$QSD/shell.qml' call baneyspaces.launcher state | jq -e '.titles|index(\"Foot\") != null'"
LQ type "libre" >/dev/null; sleep 0.7; grim -g "$((960-360)),150 720x480" "$TMP/shots/launcher.png"
baneyspaces launcher hide >/dev/null; sleep 0.4
eq "an app that is open takes you to its window (workspace shown in the row)" "$(baneyspaces launcher search chromium | jq -r '.data.results[0]|[.title,.section]|join(",")')" "Chromium,Apps"
check "the open app's row says which workspace it is on" sh -c "baneyspaces launcher search chromium | jq -e '.data.results[0].subtitle|test(\"workspace\")'"
R="$(baneyspaces launcher search chromium | jq -r '.data.results[0].id')"
baneyspaces switch 4 >/dev/null; sleep 0.2
baneyspaces launcher search chromium >/dev/null; baneyspaces launcher run "$R" >/dev/null; sleep 0.4
eq "Return on an open app goes to its window, on the display you are on" "$(active)" "$(addr_of Docs)"
eq "workspaces are searchable by number" "$(baneyspaces launcher search 5 | jq -r '.data.results[0].id')" "ws:5"
eq "a bang goes to its site" "$(baneyspaces launcher search '!yt lofi & chill' | jq -r '.data.results[0].id')" "bang:yt"
baneyspaces launcher search '!yt lofi & chill' >/dev/null
eq "…as a web address, words encoded" "$(baneyspaces launcher run bang:yt --dry-run | jq -r '.data.would_run[1]')" "https://www.youtube.com/results?search_query=lofi%20%26%20chill"
baneyspaces launcher search '?why is the sky blue' >/dev/null
eq "? asks your agent in a new chat" "$(baneyspaces launcher run ask:claude --dry-run | jq -r '.data.would_run[1]')" "https://claude.ai/new?q=why%20is%20the%20sky%20blue"
baneyspaces launcher search "Pinta" >/dev/null
eq "an app that is not open is started with its Exec line, field codes dropped" "$(baneyspaces launcher run app:com.github.PintaProject.Pinta --dry-run | jq -r '.data.would_run|join(" ")')" "pinta"
mkdir -p "$HOME/Documents"; : > "$HOME/Documents/2025 Tax Return.pdf"; : > "$HOME/Documents/taxidermy.txt"
eq "files: every word must start a word of the name" "$(baneyspaces launcher search 'tax 2025' | jq -r '[.data.results[]|select(.section=="Files")|.title]|join(",")')" "2025 Tax Return.pdf"
eq "install searches the package database" "$(baneyspaces launcher search firefox --mode install | jq -r '[.data.results[]|select(.title=="firefox")]|length')" "1"
baneyspaces launcher search firefox --mode install >/dev/null
INST="$(baneyspaces launcher run pkg:firefox)"
eq "install asks first" "$(echo "$INST" | jq -r '.data.needs_confirm')" "true"
eq "…and says what will run" "$(echo "$INST" | jq -r '.data.command')" "omarchy pkg add firefox"
eq "confirmed, it would run omarchy pkg add in a terminal (dry run: nothing installed)" "$(baneyspaces launcher run pkg:firefox --confirm --dry-run | jq -r '.data.would_run[1]')" "omarchy pkg add firefox"
eq "a package name with shell characters is never offered" "$(baneyspaces launcher search 'x;touch' --mode install | jq '[.data.results[]|select(.id|test(";"))]|length')" "0"
eq "remove lists what you installed and asks first" "$(baneyspaces launcher search '' --mode remove | jq -r '.data.results[0].confirm')" "true"
eq "an unknown result id is not_found" "$(baneyspaces launcher run nonsense | jq -r .error.code)" "not_found"

echo "== overview"
OQ() { QI baneyspaces.overview "$@"; }
baneyspaces overview show >/dev/null; sleep 0.9
eq "all nine workspaces are drawn" "$(OQ describe | jq '.cards|length')" "9"
eq "workspace 1 shows its windows" "$(OQ describe | jq '.cards[0].windows|length')" "$(baneyspaces ui | jq '.data.workspaces[0].windows|length')"
grim -o $M1 "$TMP/shots/overview.png"
CW="$(addr_of Budget)"
eq "dragging a window card onto workspace 7 moves it" "$(OQ dragWindow "$CW" 7 >/dev/null; sleep 0.5; client_ws $CW)" "7"
eq "the overview stays open while you tidy" "$(baneyspaces ui | jq -r .data.overview.shown)" "true"
OQ clickCard 6 >/dev/null; sleep 0.5
eq "clicking a workspace goes there and closes the overview" "$(mon_ws $M1)-$(baneyspaces ui | jq -r .data.overview.shown)" "6-false"
baneyspaces switch 1 >/dev/null
eq "Super+Tab again closes it (toggle)" "$(baneyspaces overview >/dev/null; baneyspaces overview | jq -r .data.shown)" "false"

echo "== settings and config"
CFG="$XDG_CONFIG_HOME/baneyspaces/config.toml"
baneyspaces settings show >/dev/null; sleep 0.8; grim -g "$((960-290)),0 580x1080" "$TMP/shots/settings.png"
baneyspaces settings hide >/dev/null
eq "a bad value is refused" "$(baneyspaces config set behavior.dock.size huge | jq -r .error.code)" "invalid_args"
eq "an unknown key is refused" "$(baneyspaces config set behavior.dock.nope 1 | jq -r .error.code)" "invalid_args"
eq "a good value is stored" "$(baneyspaces config set behavior.dock.size large | jq -r .data.value)" "large"
check "…in config.toml" grep -q 'size = "large"' "$CFG"
sleep 0.5
eq "…and the dock changed at once (tiles are bigger)" "$(baneyspaces dock show >/dev/null; sleep 0.6; D state | jq '.tiles[0].h > 69')" "true"
baneyspaces config set behavior.dock.size medium >/dev/null; baneyspaces dock hide >/dev/null
echo '# hand edit' >> "$CFG"; printf '[behavior.switcher]\nmode = "apps"\n' >> "$CFG"; sleep 1.6
eq "a hand edit of the file is picked up" "$(baneyspaces config | jq -r .data.settings.switcher.items)" "apps"
eq "…and keeps your comment" "$(grep -c '# hand edit' "$CFG")" "1"
baneyspaces config set behavior.switcher.mode windows >/dev/null
baneyspaces set animation.preset off >/dev/null; sleep 0.5
eq "animation.preset off makes every surface instant" "$(qs_state '[.motion.dockIn,.motion.dockOut,.motion.listIn,.motion.listOut,.motion.row]|join(",")')" "0,0,0,0,0"
baneyspaces set animation.preset omarchy >/dev/null; sleep 0.5
eq "the omarchy preset is Omarchy's own curves in ms (pop-in 410, pop-out 149, layers 400 and 150)" "$(qs_state '[.motion.dockIn,.motion.dockOut,.motion.listIn,.motion.listOut]|join(",")')" "410,149,400,150"
baneyspaces set animation.preset baneyspaces >/dev/null; baneyspaces set animation.dock.in.duration_ms 90 >/dev/null; sleep 0.5
eq "a time of your own for one surface wins" "$(qs_state .motion.dockIn)" "90"
eq "…and the others keep the theme's (the omarchy theme: 100)" "$(qs_state .motion.dockOut)" "100"
eq "over 1000 ms is refused with the path" "$(baneyspaces set animation.dock.in.duration_ms 5000 | jq -r .error.message | grep -c 'animation.dock.in.duration_ms')" "1"
baneyspaces set animation.speed 0.5 >/dev/null; sleep 0.5
eq "speed multiplies every duration" "$(qs_state .motion.dockOut)" "50"
baneyspaces set animation.speed 1.0 >/dev/null; baneyspaces set animation.dock.in.duration_ms -1 >/dev/null
baneyspaces set theme.override.fill.opacity 0.5 >/dev/null; sleep 0.5
QI baneyspaces.theme frames > "$TMP/frames.json"
eq "a theme.override token reaches the surfaces (panels drew opacity 0.5 under the omarchy theme)" "$(jq -r '[.frames[]|select(.frame.customFill==false)|.frame.fill[1:3]]|unique|join(",")' "$TMP/frames.json")" "80"
/usr/bin/python3 -I "$HERE/cfg-drop.py" "$CFG" theme.override; sleep 1.6
eq "taking the override out of the file puts the theme's own value back" "$(baneyspaces config | jq -c '.data.settings.appearance.override')" "{}"
baneyspaces config set behavior.launcher.enabled false >/dev/null
eq "a switched-off launcher says so" "$(baneyspaces launcher show | jq -r .error.code)" "not_supported"
baneyspaces config set behavior.launcher.enabled true >/dev/null
baneyspaces config set behavior.switcher.enabled false >/dev/null
eq "a switched-off switcher says so" "$(baneyspaces switcher next | jq -r .error.code)" "not_supported"
baneyspaces config set behavior.switcher.enabled true >/dev/null

echo "== dock off (dock.enabled = false): no dock surface, no edge reveal, everything else keeps working"
layer_dock() { H layers | grep -c '"namespace": *"baneyspaces-dock"'; }
baneyspaces dock hide >/dev/null; baneyspaces set behavior.dock.enabled false | jq -e .ok >/dev/null; sleep 0.8
check "no dock layer surface exists in the compositor" wait_for 3 sh -c "[ \"\$(hyprctl -j layers | grep -c 'baneyspaces-dock')\" = 0 ]"
eq "dock show is refused" "$(baneyspaces dock show | jq -r .error.code)" "not_supported"
warp 960 1079; sleep 1.0
eq "the pointer resting on the edge reveals nothing" "$(baneyspaces ui | jq -r .data.dock.up)" "false"
eq "…and still no layer surface" "$(hyprctl -j layers | grep -c 'baneyspaces-dock')" "0"
eq "the settings say so" "$(baneyspaces config | jq -r .data.settings.dock.enabled)" "false"
warp 400 500
eq "the switcher still works" "$(baneyspaces switcher next | jq -r .ok)" "true"
baneyspaces switcher cancel >/dev/null
eq "the launcher still works" "$(baneyspaces launcher show | jq -r .ok)" "true"
baneyspaces launcher hide >/dev/null
eq "the overview still works" "$(baneyspaces overview show | jq -r .data.shown)" "true"
baneyspaces overview hide >/dev/null
eq "switching workspaces still works" "$(baneyspaces switch 3 >/dev/null; sleep 0.3; mon_ws $M1)" "3"
baneyspaces switch 1 >/dev/null
baneyspaces set behavior.dock.enabled true >/dev/null; sleep 0.5
warp 960 1079; sleep 0.8
eq "turned back on, the next edge reveal brings the dock back (no restart)" "$(baneyspaces ui | jq -r .data.dock.up)" "true"
check "…and its surface exists again" wait_for 3 sh -c "[ \"\$(hyprctl -j layers | grep -c 'baneyspaces-dock')\" -ge 1 ]"
warp 400 500; sleep 0.8

echo "== themes: every surface in every theme and palette matches spec/themes.json"
baneyspaces dock hide >/dev/null
for theme in omarchy baneyspaces minimal; do
  baneyspaces set theme.name $theme >/dev/null
  for pal in auto $(jq -r '.palettes|keys[]' "$REPO/spec/palettes.json"); do
    baneyspaces set theme.palette $pal >/dev/null; sleep 0.3
    QI baneyspaces.theme frames > "$TMP/frames.json"
    arg="$pal"; [ "$pal" = auto ] && arg="auto:$TMP/theme/colors.toml"
    OUT="$(/usr/bin/python3 -I "$HERE/theme-check.py" "$TMP/frames.json" "$theme" "$arg" 2>&1)"
    eq "theme $theme, palette $pal: every surface drew the spec's tokens" "$OUT" ""
  done
done
# the look of each theme, for the record
baneyspaces set theme.palette auto >/dev/null
for theme in omarchy baneyspaces minimal; do
  baneyspaces set theme.name $theme >/dev/null; baneyspaces dock show >/dev/null; sleep 0.9
  grim -g "$((960-480)),$((1080-170)) 960x170" "$TMP/shots/dock-$theme.png"; baneyspaces dock hide >/dev/null; sleep 0.3
done
baneyspaces set theme.name baneyspaces >/dev/null; sleep 0.4
baneyspaces launcher show >/dev/null; sleep 0.5; LQ type "libre" >/dev/null; sleep 0.7; grim -g "$((960-360)),150 720x480" "$TMP/shots/launcher-baneyspaces.png"; baneyspaces launcher hide >/dev/null; sleep 0.3
baneyspaces set theme.palette nord >/dev/null; sleep 0.4
baneyspaces overview show >/dev/null; sleep 0.9; grim -o $M1 "$TMP/shots/overview-baneyspaces-nord.png"; baneyspaces overview hide >/dev/null
baneyspaces set theme.name omarchy >/dev/null; baneyspaces set theme.palette auto >/dev/null; sleep 0.3
eq "the theme can be switched without a restart (the plugin reports it)" "$(qs_state .theme.name)" "omarchy"
eq "a bad theme is refused" "$(baneyspaces set theme.name glass | jq -r .error.code)" "invalid_args"
eq "a bad palette is refused" "$(baneyspaces set theme.palette nonsense | jq -r .error.code)" "invalid_args"

echo "== theme: live Omarchy colors, no restart"
cp "$TMP/theme/colors.toml" "$TMP/theme/colors.toml.bak"
sed -i 's/^accent = .*/accent = "#12ab34"/' "$TMP/theme/colors.toml"
check "a theme switch reaches the plugin without a restart" wait_for 6 sh -c "[ \"\$(qs ipc -p '$QSD/shell.qml' call baneyspaces state | jq -r .theme.accent)\" = '#12ab34' ]"
mv "$TMP/theme/colors.toml.bak" "$TMP/theme/colors.toml"
check "and back" wait_for 6 sh -c "[ \"\$(qs ipc -p '$QSD/shell.qml' call baneyspaces state | jq -r .theme.accent)\" != '#12ab34' ]"

echo "== agents may change anything in config.toml (and are logged); pressing your keys stays yours"
AOUT="$TMP/agent-set.out"; rm -f "$AOUT"
AR="$(baneyspaces agent run --agent-id looks -- sh -c "for kv in 'theme.name minimal' 'theme.palette nord' 'behavior.dock.enabled false' 'behavior.dock.enabled true' 'behavior.launcher.files false' 'animation.preset snappy'; do baneyspaces set \$kv; done > '$AOUT' 2>&1; baneyspaces switch 3 >> '$AOUT' 2>&1; sleep 600")"
check "an agent process started" test -n "$(echo "$AR" | jq -r '.data.pid // empty')"
wait_for 8 test "$(wc -l < "$AOUT" 2>/dev/null || echo 0)" -ge 7
eq "an agent may set the theme, the palette, the dock switch, behavior and animation" "$(head -6 "$AOUT" | jq -r '.ok' | tr '\n' ' ')" "true true true true true true "
eq "…and workspace operations stay yours" "$(sed -n 7p "$AOUT" | jq -r '.error.code')" "not_in_scope"
eq "the settings it made are in use" "$(baneyspaces config | jq -r '.data.settings.appearance.theme + "/" + .data.settings.appearance.palette + "/" + (.data.settings.launcher.files|tostring) + "/" + .data.settings.motion.preset')" "minimal/nord/false/snappy"
eq "the action log has a record for each change, with the caller's process" "$(baneyspaces agent log | jq '[.data.records[]|select(.verb=="config_set" and .pid != null)]|length')" "6"
baneyspaces set theme.name omarchy >/dev/null; baneyspaces set theme.palette auto >/dev/null; baneyspaces set behavior.launcher.files true >/dev/null; baneyspaces set animation.preset baneyspaces >/dev/null; baneyspaces agent-workspace hide >/dev/null

echo "== frame timing: the scene graph's own frameSwapped, 12 transitions per surface (spec/config.md quality bar)"
PQ() { QI baneyspaces.probe "$@"; }
probe_surface() { # probe_surface <name> <show command> <hide command>
  PQ start "$1" >/dev/null
  for _ in $(seq 1 12); do eval "$2" >/dev/null; sleep 0.35; eval "$3" >/dev/null; sleep 0.3; done
  PQ stop
}
FP="{}"
baneyspaces set animation.preset baneyspaces >/dev/null; baneyspaces set theme.name baneyspaces >/dev/null; sleep 0.3
for spec in "dock|baneyspaces dock show|baneyspaces dock hide" "overview|baneyspaces overview show|baneyspaces overview hide" "launcher|baneyspaces launcher show|baneyspaces launcher hide" "switcher|baneyspaces switcher next|baneyspaces switcher cancel"; do
  IFS='|' read -r nm sh hd <<<"$spec"
  R="$(probe_surface "$nm" "$sh" "$hd")"; echo "  $R"
  check "the probe saw frames of the $nm (a frameSwapped per frame drawn)" test "$(echo "$R" | jq -r '.intervals // 0')" -ge 10
  FP="$(jq -c --arg n "$nm" --argjson r "$R" '.[$n]=$r' <<<"$FP")"
done
baneyspaces set theme.name omarchy >/dev/null
echo "  (the nested session draws with Qt's software renderer on a headless 60 Hz output, so these numbers are the probe working, not a verdict on a GPU: untested live)"
echo "$FP" > "$TMP/frame-probe.json"

echo "== the shell stayed healthy"
check "quickshell is still running" kill -0 $QSPID
check "no QML errors in its log" sh -c "! sed 's/\x1b\[[0-9;]*m//g' '$TMP/quickshell.log' | grep -E 'ReferenceError|TypeError|is not a type|unavailable|Binding loop|Cannot ' "
check "the daemon logged no panic" sh -c "! grep -q panicked '$TMP/daemon.log'"
if [ -n "${SAVE_SHOTS:-}" ]; then mkdir -p "$HERE/shots"; cp "$TMP"/shots/*.png "$HERE/shots/"; echo "  shots saved to platforms/linux/tests/shots/"; fi

# put the session back: close the windows, one workspace on each display
for a in $(H clients | jq -r '.[]|select(.workspace.name!="special:agent")|.address'); do hyprctl dispatch "hl.dsp.window.close({ window = \"address:$a\" })" >/dev/null; done
baneyspaces focus-monitor $M1 >/dev/null; baneyspaces switch 1 >/dev/null; baneyspaces focus-monitor $M2 >/dev/null; baneyspaces switch 2 >/dev/null; baneyspaces focus-monitor $M1 >/dev/null; sleep 0.3
