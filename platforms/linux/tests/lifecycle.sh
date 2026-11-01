# Sourced last by nested.sh: stopping the daemon, a reload with no daemon, uninstalling.
echo "== lifecycle: no daemon, a reload, an uninstall"
daemon_up() { baneyspaces state 2>/dev/null | jq -e .ok >/dev/null; }
daemon_down() { ! daemon_up; }
focused_ws() { H monitors | jq -r '.[]|select(.focused)|.activeWorkspace.id'; }
baneyspaces stop >/dev/null
check "baneyspaces stop stops the daemon" wait_for 4 daemon_down
eq "with no daemon the CLI says so" "$(baneyspaces state | jq -r .error.code)" "daemon_down"
for N in 4 5 6 7; do H monitors | jq -e "[.[].activeWorkspace.id]|index($N) == null" >/dev/null && break; done
press "BaneySpaces: workspace $N"; sleep 0.4
eq "the bound key still switches workspace with no daemon (Hyprland's own dispatch)" "$(focused_ws)" "$N"
eq "the CLI says it used the fallback" "$(baneyspaces switch $N | jq -r '.data.fallback // .error.code')" "hyprland"
# A reload starts the daemon when the install is there.
touch "$TMP/autostart-on"; mkdir -p "$HOME/.config/hypr"
printf '%s\n' '-- >>> baneyspaces (managed by baneyspaces install.sh) >>>' > "$HOME/.config/hypr/hyprland.lua"
hyprctl reload >/dev/null
check "a config reload starts the daemon" wait_for 6 daemon_up
# Remove the block: the next reload stops it and nothing starts it again.
printf '%s\n' '-- my config, nothing of BaneySpaces' > "$HOME/.config/hypr/hyprland.lua"
hyprctl reload >/dev/null
check "the daemon exits when the include is gone from hyprland.lua" wait_for 6 daemon_down
sleep 2
check "and stays down" daemon_down
