local M = {}

local SETTINGS_DIR = os.getenv("HOME") .. "/.config/hyprlayout"
local SETTINGS_PATH = SETTINGS_DIR .. "/settings.lua"

function M.load()
  local f = io.open(SETTINGS_PATH, "r")
  if not f then
    return {}
  end
  f:close()
  local chunk, err = loadfile(SETTINGS_PATH)
  if not chunk then
    return {}
  end
  local ok, data = pcall(chunk)
  if not ok or type(data) ~= "table" then
    return {}
  end
  return data
end

function M.save(data)
  os.execute(string.format('mkdir -p "%s"', SETTINGS_DIR))
  local f = io.open(SETTINGS_PATH, "w")
  if not f then
    return false, "cannot write " .. SETTINGS_PATH
  end
  f:write("return {\n")
  f:write(string.format("  canvas_scale = %d,\n", data.canvas_scale or 4))
  f:write(string.format("  ui_scale = %s,\n", tostring(data.ui_scale or 1.0)))
  f:write(string.format("  attract_enabled = %s,\n", tostring(data.attract_enabled or false)))
  f:write(string.format("  shot_interval = %s,\n", tostring(data.shot_interval or 3)))
  f:write("}\n")
  f:close()
  return true
end

return M
