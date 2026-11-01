-- Starts the BaneySpaces daemon with Hyprland, and again after every config reload: a reload does
-- not fire hyprland.start, and the workspace keys the include binds need the daemon (they fall back
-- to Hyprland's own dispatch while it is down). Nothing starts if the install is gone from
-- hyprland.lua. The daemon refuses to run twice and exits when the include is removed.
local function installed()
  local f = io.open((os.getenv("HOME") or "") .. "/.config/hypr/hyprland.lua", "r")
  if not f then return true end
  local text = f:read("*a")
  f:close()
  return text:find(">>> baneyspaces", 1, true) ~= nil or text:find("baneyspaces/baneyspaces.lua", 1, true) ~= nil
end

local function start()
  if installed() then
    hl.exec_cmd("baneyspaces daemon")
  end
end

hl.on("hyprland.start", start)
hl.on("config.reloaded", start)
