local screens = require("core.screens")
local Rect = require("core.rect")
local snap = require("core.snap")
local GuiScreen = require("gui_screen")

local SCREEN_SCALE = 8
local gui_screens = {}
local selected = nil
local dragging = false
local drag_offset = { 0, 0 }
local placement_mode = false
local status_msg = ""
local status_timer = 0

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
  local win_w, win_h = love.graphics.getWidth(), love.graphics.getHeight()
  local off_x = math.floor(win_w / 2) - avg_x
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
  if placement_mode then
    snap.attract_screens(gui_screens)
  end
  center_layout()
end

local function load_screens()
  gui_screens = {}
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
      w, h = 100, 100
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
end

function love.load()
  math.randomseed(os.time())
  load_screens()
end

function love.update(dt)
  for _, gs in ipairs(gui_screens) do
    gs:update(dt)
  end
  if status_timer > 0 then
    status_timer = status_timer - dt
    if status_timer <= 0 then
      status_msg = ""
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
    return
  end

  for _, gs in ipairs(gui_screens) do
    gs:draw()
  end

  local info = string.format("hyprlayout | %d screens | drag to move | P=placement %s | R=reload ESC=quit",
    #gui_screens, placement_mode and "ON" or "off")
  love.graphics.setColor(0.8, 0.8, 0.8)
  love.graphics.print(info, 10, 10)

  if status_msg ~= "" then
    love.graphics.setColor(1, 0.9, 0.5)
    love.graphics.print(status_msg, 10, 30)
  end
end

function love.mousemoved(x, y)
  if dragging and selected then
    selected:set_position(x - drag_offset[1], y - drag_offset[2])
  end
end

function love.mousepressed(x, y, button)
  if button ~= 1 then return end

  for i = #gui_screens, 1, -1 do
    local gs = gui_screens[i]
    if gs.rect:contains(x, y) then
      selected = gs
      dragging = true
      drag_offset[1] = x - gs.rect.x
      drag_offset[2] = y - gs.rect.y
      gui_screens[i] = table.remove(gui_screens, i)
      table.insert(gui_screens, gs)
      return
    end
  end
  selected = nil
end

function love.mousereleased(x, y, button)
  if button ~= 1 then return end
  if dragging and selected then
    on_release_snap()
  end
  dragging = false
end

function love.keypressed(key)
  if key == "escape" then
    love.event.quit()
  elseif key == "r" then
    load_screens()
    center_layout(true)
  elseif key == "p" then
    placement_mode = not placement_mode
    status_msg = "Placement mode: " .. (placement_mode and "ON" or "OFF")
    status_timer = 2
  end
end
