-- Starts the BaneySpaces daemon with Hyprland. Included by install.sh next to baneyspaces.lua.
-- The daemon exits when Hyprland does, and refuses to start twice.
hl.on("hyprland.start", function()
  hl.exec_cmd("baneyspaces daemon")
end)
