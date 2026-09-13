local screens = require("core.screens")
local Rect = require("core.rect")
local snap = require("core.snap")
local anchors = require("core.anchors")
local GuiScreen = require("gui_screen")
local Panel = require("panel")
local apply = require("core.apply")

local SCREEN_SCALE = 4
local CONFIRM_DELAY = 20
local SCREENSHOT_INTERVAL = 10
local gui_screens = {}
local selected = nil
local dragging = false
local drag_moved = false
local drag_offset = { 0, 0 }
local status_msg = ""
local status_timer = 0
local panel = Panel.new()
local panel_w = 280
local confirm_start = 0
local original_cmd = nil
local anchor_data = {}
local shot_thread = nil
local shot_channel = nil
local shot_timer = 0
local shot_images = {}

local function get_screen_size(screen)
  if not screen.mode then
    return 100, 100
  end
  local w = math.floor(screen.mode.width / SCREEN_SCALE / screen.scale)
  local h = math.floor(screen.mode.height / SCREEN_SCALE / screen.scale)
  if screen.transform % 2 == 1 then
    w, h = h, w
  end
  return w, h
end

local function canvas_w()
  return love.graphics.getWidth() - panel_w - 20
end

local function center_layout(immediate)
  if #gui_screens == 0 then return end

  local min_x, min_y = math.huge, math.huge
  local max_x, max_y = -math.huge, -math.huge
  for _, gs in ipairs(gui_screens) do
    local r = gs.target_rect
    min_x = math.min(min_x, r.x)
    min_y = math.min(min_y, r.y)
    max_x = math.max(max_x, r.x + r.width)
    max_y = math.max(max_y, r.y + r.height)
  end

  local avg_x = (min_x + max_x) / 2
  local avg_y = (min_y + max_y) / 2
  local cw = canvas_w()
  local win_h = love.graphics.getHeight()
  local off_x = math.floor(cw / 2) - avg_x
  local off_y = math.floor(win_h / 2) - avg_y

  for _, gs in ipairs(gui_screens) do
    if immediate then
      gs:set_position(gs.target_rect.x + off_x, gs.target_rect.y + off_y)
    else
      gs.target_rect.x = gs.target_rect.x + off_x
      gs.target_rect.y = gs.target_rect.y + off_y
    end
  end
end

local function on_release_snap()
  snap.snap_active_screen(gui_screens)
  if panel.attract_enabled then
    snap.attract_screens(gui_screens)
  end
  center_layout()
  anchor_data = anchors.detect(gui_screens)
end

local function on_screen_changed()
  center_layout()
  anchor_data = anchors.detect(gui_screens)
end

local function on_screen_resized(gs, old_w, old_h)
  anchors.propagate(gui_screens, anchor_data, gs, old_w, old_h)
  center_layout()
  anchor_data = anchors.detect(gui_screens)
end

local function set_current_modes_as_ref()
  original_cmd = apply.make_commands(gui_screens, SCREEN_SCALE)
end

local function action_apply()
  local cmds = apply.make_commands(gui_screens, SCREEN_SCALE)
  if #cmds > 0 then
    apply.run_commands(cmds)
    confirm_start = os.clock()
    status_msg = "Layout applied! Press ENTER to confirm or ESC to revert (" .. CONFIRM_DELAY .. "s)"
    status_timer = CONFIRM_DELAY
  end
end

local function load_screens()
  gui_screens = {}
  shot_images = {}
  local ok = screens.load()

  if not ok or #screens.displayInfo == 0 then
    print("No screens found! " .. tostring(screens.error))
    return
  end

  local info = screens.displayInfo

  for _, screen in ipairs(info) do
    local x, y = screen.position[1], screen.position[2]
    local w, h
    if screen.mode then
      w, h = get_screen_size(screen)
    else
      local max_w, max_h = 1920, 1080
      for _, m in ipairs(screen.available) do
        max_w = math.max(max_w, m.width)
        max_h = math.max(max_h, m.height)
      end
      w = math.floor(max_w / SCREEN_SCALE / screen.scale)
      h = math.floor(max_h / SCREEN_SCALE / screen.scale)
    end
    local rect = Rect.new(
      math.floor(x / SCREEN_SCALE),
      -math.floor(y / SCREEN_SCALE) - h,
      w, h
    )
    local gs = GuiScreen.new(screen, rect)
    gs:genColor()
    table.insert(gui_screens, gs)
  end

  center_layout(true)
  anchor_data = anchors.detect(gui_screens)
end

local function layout_panel()
  local win_w = love.graphics.getWidth()
  local win_h = love.graphics.getHeight()
  panel:layout(win_w, win_h)
  panel.get_all_screens = function() return gui_screens end
  panel.on_screen_changed = on_screen_changed
  panel.on_screen_resized = on_screen_resized
  panel.on_center = function() center_layout(true) end
  panel.on_apply_callback = function() action_apply() end
  panel.on_screen_scale_change = function(val)
    if type(val) ~= "number" then return end
    local old_scale = SCREEN_SCALE
    SCREEN_SCALE = val
    local ratio = old_scale / val
    for _, gs in ipairs(gui_screens) do
      local r = gs.target_rect
      r.x = math.floor(r.x * ratio)
      r.y = math.floor(r.y * ratio)
      r.width = math.floor(r.width * ratio)
      r.height = math.floor(r.height * ratio)
    end
    center_layout(true)
    anchor_data = anchors.detect(gui_screens)
  end
  panel.on_ui_scale_change = function(val)
    if type(val) ~= "number" then return end
    panel.ui_scale_factor = val
    panel_w = math.floor(280 * val)
    layout_panel()
  end
  panel.on_visibility_changed = function()
    layout_panel()
  end
  panel.on_reload = function()
    load_screens()
    layout_panel()
    set_current_modes_as_ref()
  end
  panel.on_attract_toggle = function(val)
    panel.attract_enabled = val
  end
  panel:update_profiles()
  if selected then
    panel:set_screen(selected)
  end
end

local shot_dir = nil

local function start_screenshot_thread()
  if not next(gui_screens) then return end
  local info = {}
  for _, gs in ipairs(gui_screens) do
    table.insert(info, { uid = gs.screen.uid, active = gs.screen.active })
  end
  shot_thread = love.thread.newThread("core/screenshot_thread.lua")
  shot_thread:start(info, shot_dir)
end

local function poll_screenshots()
  if shot_thread then
    local ok, err = pcall(function() return shot_thread:getError() end)
    if ok and err then
      print("[screenshot thread error] " .. err)
    end
  end
  if not shot_channel then return end
  while true do
    local msg = shot_channel:pop()
    if not msg then break end
    if msg.type == "screenshot" then
      local rel_path = "shots/" .. msg.file
      local ok, img = pcall(love.graphics.newImage, rel_path)
      if ok and img then
        shot_images[msg.uid] = img
        for _, gs in ipairs(gui_screens) do
          if gs.screen.uid == msg.uid then
            gs:set_preview(img)
          end
        end
      end
    end
  end
end

function love.threaderror(msg)
  print("[THREAD ERROR] " .. tostring(msg))
end

function love.load()
  math.randomseed(os.time())
  shot_channel = love.thread.getChannel("screenshots")
  local cwd = love.filesystem.getWorkingDirectory()
  shot_dir = cwd .. "/shots"
  load_screens()
  layout_panel()
  set_current_modes_as_ref()
  start_screenshot_thread()
  shot_timer = SCREENSHOT_INTERVAL
end

function love.quit()
  if shot_thread then
    shot_thread:wait()
  end
end

function love.resize(w, h)
  layout_panel()
  center_layout(true)
end

function love.update(dt)
  for _, gs in ipairs(gui_screens) do
    gs:update(dt)
  end
  poll_screenshots()
  shot_timer = shot_timer - dt
  if shot_timer <= 0 then
    shot_timer = SCREENSHOT_INTERVAL
    start_screenshot_thread()
  end
  if status_timer > 0 then
    status_timer = status_timer - dt
    if status_timer <= 0 then
      status_msg = ""
    end
  end
  if confirm_start > 0 then
    local elapsed = os.clock() - confirm_start
    if elapsed >= CONFIRM_DELAY then
      if original_cmd and #original_cmd > 0 then
        apply.run_commands(original_cmd)
      end
      confirm_start = 0
      load_screens()
      center_layout(true)
      panel:set_screen(nil)
      set_current_modes_as_ref()
      status_msg = "Timed out - reverted"
      status_timer = 3
    end
  end
end

function love.draw()
  love.graphics.clear(0.2, 0.2, 0.2)

  if #gui_screens == 0 then
    love.graphics.setColor(1, 0.4, 0.4)
    love.graphics.print("hyprlayout - no screens detected", 20, 20)
    if screens.error then
      love.graphics.setColor(0.8, 0.8, 0.8)
      love.graphics.print(screens.error:sub(1, 500), 20, 50)
    end
    panel:draw()
    return
  end

  for _, gs in ipairs(gui_screens) do
    gs:draw()
  end

  panel:draw()

  if confirm_start > 0 then
    local elapsed = os.clock() - confirm_start
    local remaining = CONFIRM_DELAY - elapsed
    local ratio = remaining / CONFIRM_DELAY
    local win_w = love.graphics.getWidth()
    local win_h = love.graphics.getHeight()

    local bar_color_r = 50 + math.floor(200 * (1.0 - ratio)) / 255
    local bar_color_g = math.floor(200 * ratio) / 255
    love.graphics.setColor(bar_color_r, bar_color_g, 0.4)
    love.graphics.rectangle("fill", 0, math.floor(win_h / 2) - 40, math.floor(win_w * ratio), 10)

    love.graphics.setColor(0.8, 0.8, 0.8)
    love.graphics.print("Press ENTER", 20, math.floor(win_h / 2) + 40)
    love.graphics.print("to confirm (or ESC to abort)", 20, math.floor(win_h / 2))
  else
    local info = string.format("hyprlayout | %d screens | drag to move | ENTER=apply R=reload TAB=profile ESC=quit",
      #gui_screens)
    love.graphics.setColor(0.8, 0.8, 0.8)
    love.graphics.print(info, 10, 10)

    if status_msg ~= "" then
      love.graphics.setColor(1, 0.9, 0.5)
      love.graphics.print(status_msg, 10, 30)
    end
  end
end

function love.mousemoved(x, y)
  if dragging and selected then
    local nx = x - drag_offset[1]
    local ny = y - drag_offset[2]
    if nx ~= selected.rect.x or ny ~= selected.rect.y then
      drag_moved = true
    end
    selected:set_position(nx, ny)
  else
    panel:on_move(x, y)
  end
end

function love.mousepressed(x, y, button)
  if button ~= 1 then return end

  -- Panel gets priority
  if panel:on_press(x, y) then
    return
  end

  for i = #gui_screens, 1, -1 do
    local gs = gui_screens[i]
    if gs.rect:contains(x, y) then
      selected = gs
      dragging = true
      drag_moved = false
      drag_offset[1] = x - gs.rect.x
      drag_offset[2] = y - gs.rect.y
      table.remove(gui_screens, i)
      table.insert(gui_screens, gs)
      panel:set_screen(gs)
      return
    end
  end
  selected = nil
  panel:set_screen(nil)
end

function love.mousereleased(x, y, button)
  if button ~= 1 then return end
  panel:on_release(x, y)
  if dragging and selected and drag_moved then
    on_release_snap()
  end
  dragging = false
end

function love.textinput(txt)
  if panel:text_input(txt) then
    return
  end
end

function love.keyreleased(key)
end

function love.keypressed(key)
  if panel:modal_keypressed(key) then
    return
  end
  if key == "return" or key == "kpenter" then
    if confirm_start > 0 then
      confirm_start = 0
      set_current_modes_as_ref()
      status_msg = ""
      status_timer = 0
    else
      action_apply()
    end
  elseif key == "escape" then
    if confirm_start > 0 then
      if original_cmd and #original_cmd > 0 then
        apply.run_commands(original_cmd)
      end
      confirm_start = 0
      load_screens()
      center_layout(true)
      panel:set_screen(nil)
      set_current_modes_as_ref()
      status_msg = "Reverted"
      status_timer = 3
    else
      love.event.quit()
    end
  elseif key == "tab" then
    if panel:cycle_profile() then
      panel:load_profile()
    end
  elseif key == "r" then
    load_screens()
    center_layout(true)
    panel:set_screen(nil)
    set_current_modes_as_ref()
  end
end
