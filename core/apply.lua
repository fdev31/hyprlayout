local M = {}

local SCREEN_SCALE = 8

local function trim_rects_flip_y(rects)
  local min_x = math.huge
  local max_y = -math.huge
  for _, r in ipairs(rects) do
    if r then
      min_x = math.min(min_x, r.x)
      max_y = math.max(max_y, r.y + r.height)
    end
  end
  for _, r in ipairs(rects) do
    if r then
      r.x = r.x - min_x
      r.y = max_y - (r.y + r.height)
    end
  end
end

function M.make_commands(gui_screens)
  local rects = {}
  for _, gs in ipairs(gui_screens) do
    local r = gs.target_rect
    table.insert(rects, {
      x = r.x * SCREEN_SCALE,
      y = r.y * SCREEN_SCALE,
      width = r.width * SCREEN_SCALE,
      height = r.height * SCREEN_SCALE,
    })
  end
  trim_rects_flip_y(rects)

  local cmds = {}
  for i, gs in ipairs(gui_screens) do
    local screen = gs.screen
    local r = rects[i]
    if screen.active then
      local mode_str
      if screen.mode then
        mode_str = string.format("%dx%d@%.2f", screen.mode.width, screen.mode.height, screen.mode.freq)
      else
        mode_str = "preferred"
      end
      local pos = string.format("%dx%d", math.floor(r.x), math.floor(r.y))
      local cmd = string.format(
        "hl.monitor({output='%s', mode='%s', position='%s', scale=%.6f, transform=%d})",
        screen.uid, mode_str, pos, screen.scale, screen.transform
      )
      table.insert(cmds, cmd)
    else
      local cmd = string.format("hl.monitor({output='%s', disabled=true})", screen.uid)
      table.insert(cmds, cmd)
    end
  end

  local joined = table.concat(cmds, " ; ")
  return { 'hyprctl eval "' .. joined .. '"' }
end

function M.run_commands(cmds)
  for _, cmd in ipairs(cmds) do
    print("Running: " .. cmd)
    local f = io.popen(cmd .. " 2>&1")
    local out = f:read("*a") or ""
    f:close()
    if out ~= "" then
      print(out)
    end
  end
end

function M.apply(gui_screens)
  local cmds = M.make_commands(gui_screens)
  M.run_commands(cmds)
  return true
end

return M
