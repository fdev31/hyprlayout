local screens = require("core.screens")
local Rect = require("core.rect")
local snap = require("core.snap")
local anchors = require("core.anchors")
local GuiScreen = require("gui_screen")
local Panel = require("panel")
local apply = require("core.apply")
local settings = require("core.settings")

local SCREEN_SCALE = Panel.DEFAULT_CANVAS_SCALE
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
local panel_w = Panel.PANEL_W
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
  return Rect.screen_size(screen.mode.width, screen.mode.height, screen.scale, SCREEN_SCALE, screen.transform)
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

local function save_settings()
  settings.save({
    canvas_scale = SCREEN_SCALE,
    ui_scale = panel.ui_scale_factor,
    attract_enabled = panel.attract_enabled,
  })
end

local function change_canvas_scale(val)
  if type(val) ~= "number" then return end
  val = math.max(2, math.min(16, math.floor(val)))
  if val == SCREEN_SCALE then return end
  local old_scale = SCREEN_SCALE
  SCREEN_SCALE = val
  local ratio = old_scale / val
  for _, gs in ipairs(gui_screens) do
    local r = gs.target_rect
    r.x = r.x * ratio
    r.y = r.y * ratio
    r.width = r.width * ratio
    r.height = r.height * ratio
  end
  center_layout(true)
  anchor_data = anchors.detect(gui_screens)
  panel.screen_scale.value = val
  save_settings()
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

local function reload_all()
  load_screens()
  center_layout(true)
  panel:set_screen(nil)
  set_current_modes_as_ref()
end

local function revert_layout(msg)
  if original_cmd and #original_cmd > 0 then
    apply.run_commands(original_cmd)
  end
  confirm_start = 0
  reload_all()
  status_msg = msg
  status_timer = 3
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
      w, h = Rect.screen_size(max_w, max_h, screen.scale, SCREEN_SCALE, screen.transform)
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
  panel.on_screen_scale_change = change_canvas_scale
  panel.on_ui_scale_change = function(val)
    if type(val) ~= "number" then return end
    panel.ui_scale_factor = val
    panel_w = math.floor(Panel.PANEL_W * val)
    for _, gs in ipairs(gui_screens) do
      gs.ui_scale = val
    end
    layout_panel()
    save_settings()
  end
  panel.on_visibility_changed = function()
    layout_panel()
  end
  panel.on_reload = function()
    reload_all()
  end
  panel.on_attract_toggle = function(val)
    panel.attract_enabled = val
    save_settings()
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

  local saved = settings.load()
  if saved.canvas_scale then
    SCREEN_SCALE = math.max(2, math.min(16, saved.canvas_scale))
  end
  if saved.ui_scale then
    panel.ui_scale_factor = saved.ui_scale
    panel_w = math.floor(Panel.PANEL_W * saved.ui_scale)
  end
  if saved.attract_enabled ~= nil then
    panel.attract_enabled = saved.attract_enabled
  end

  load_screens()
  layout_panel()
  panel.screen_scale.value = SCREEN_SCALE
  for _, gs in ipairs(gui_screens) do
    gs.ui_scale = panel.ui_scale_factor or 1.0
  end
  set_current_modes_as_ref()
  start_screenshot_thread()
  shot_timer = SCREENSHOT_INTERVAL
end

function love.quit()
  save_settings()
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
      revert_layout("Timed out - reverted")
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

    -- Dim overlay
    love.graphics.setColor(0, 0, 0, 0.6)
    love.graphics.rectangle("fill", 0, 0, win_w, win_h)

    -- Modal box
    local mw, mh = 360, 160
    local mx, my = (win_w - mw) / 2, (win_h - mh) / 2
    love.graphics.setColor(0.15, 0.15, 0.2, 1)
    love.graphics.rectangle("fill", mx, my, mw, mh, 8, 8)
    love.graphics.setColor(0.4, 0.4, 0.5)
    love.graphics.setLineWidth(1)
    love.graphics.rectangle("line", mx, my, mw, mh, 8, 8)

    -- Title
    love.graphics.setColor(1, 1, 1)
    love.graphics.printf("Apply layout?", mx, my + 20, mw, "center")

    -- Progress bar
    local bar_w, bar_h = mw - 60, 12
    local bar_x, bar_y = mx + 30, my + 60
    love.graphics.setColor(0.3, 0.3, 0.35)
    love.graphics.rectangle("fill", bar_x, bar_y, bar_w, bar_h, 4, 4)
    local bar_color_r = 50 + math.floor(200 * (1.0 - ratio)) / 255
    local bar_color_g = math.floor(200 * ratio) / 255
    love.graphics.setColor(bar_color_r, bar_color_g, 0.4)
    love.graphics.rectangle("fill", bar_x, bar_y, math.max(bar_h, math.floor(bar_w * ratio)), bar_h, 4, 4)

    -- Instructions
    love.graphics.setColor(0.7, 0.7, 0.7)
    love.graphics.printf("ENTER to confirm  |  ESC to abort", mx, my + 100, mw, "center")
    love.graphics.printf(string.format("%.1fs", remaining), mx, my + 125, mw, "center")
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

function love.wheelmoved(_, dy)
  local x = love.mouse.getX()
  if x < canvas_w() then
    change_canvas_scale(SCREEN_SCALE + dy)
  end
end

local function set_highlight(gs)
  for _, s in ipairs(gui_screens) do
    s.highlighted = (s == gs)
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
      set_highlight(gs)
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
  set_highlight(nil)
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
      revert_layout("Reverted")
    else
      love.event.quit()
    end
  elseif key == "tab" then
    if panel:cycle_profile() then
      panel:load_profile()
    end
  elseif key == "r" then
    reload_all()
  end
end
