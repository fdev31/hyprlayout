local Widget = require("widgets.widget")
local Button = require("widgets.button")
local Dropdown = require("widgets.dropdown")
local Label = require("widgets.label")
local Toggle = require("widgets.toggle")
local Modal = require("widgets.modal")
local profiles = require("core.profiles")
local apply = require("core.apply")

local PANEL = {}
PANEL.__index = PANEL

local PANEL_W = 280
local MARGIN = 10
local ROW_H = 28
local LABEL_W = 80

local function sorted_resolutions(available)
  local seen = {}
  local res = {}
  for _, m in ipairs(available) do
    local key = m.width .. "x" .. m.height
    if not seen[key] then
      seen[key] = true
      table.insert(res, { w = m.width, h = m.height })
    end
  end
  table.sort(res, function(a, b) return (a.w * a.h) > (b.w * b.h) end)
  return res
end

local function sorted_frequencies(available, w, h)
  local freqs = {}
  for _, m in ipairs(available) do
    if m.width == w and m.height == h then
      table.insert(freqs, m.freq)
    end
  end
  table.sort(freqs, function(a, b) return a > b end)
  return freqs
end

local function find_matching_mode(available, w, h, freq)
  for _, m in ipairs(available) do
    if m.width == w and m.height == h and math.abs(m.freq - freq) < 0.1 then
      return m
    end
  end
  local best = nil
  local best_diff = math.huge
  for _, m in ipairs(available) do
    if m.width == w and m.height == h then
      local diff = math.abs(m.freq - freq)
      if diff < best_diff then
        best_diff = diff
        best = m
      end
    end
  end
  return best
end

local function get_closest_match(values, target)
  local best_idx = 1
  local best_diff = math.huge
  for i, v in ipairs(values) do
    local diff = math.abs(v - target)
    if diff < best_diff then
      best_diff = diff
      best_idx = i
    end
  end
  return best_idx
end

local function simplify_model_name(name)
  local words = {}
  local seen = {}
  for word in name:gmatch("%S+") do
    local lower = word:lower()
    if not seen[lower] and not word:match("^%x+$") then
      seen[lower] = true
      table.insert(words, word)
    end
  end
  return table.concat(words, " ")
end

function PANEL.new()
  local self = setmetatable({}, PANEL)
  self.widgets = {}
  self.visible = true
  self.selected_gs = nil
  return self
end

function PANEL:layout(win_w, win_h)
  self.x = win_w - PANEL_W - MARGIN
  self.y = MARGIN
  self.w = PANEL_W
  self.h = win_h - 2 * MARGIN

  local x = self.x + MARGIN
  local y = self.y + MARGIN
  local cw = self.w - 2 * MARGIN

  -- Title
  self.title = Label.new(x, y, "Screen Settings", { width = cw, height = 20, font_size = 15, align = "center" })
  y = y + 30

  -- Screen name
  self.screen_name = Label.new(x, y, "", { width = cw, height = 20, font_size = 13 })
  y = y + ROW_H + 5

  -- Resolution
  self.res_label = Label.new(x, y, "Resolution", { width = LABEL_W, height = ROW_H })
  self.resolutions = Dropdown.new(x + LABEL_W, y, cw - LABEL_W, ROW_H, {
    options = {},
    on_change = function() self:on_resolution_change() end,
  })
  y = y + ROW_H + 5

  -- Frequency
  self.freq_label = Label.new(x, y, "Refresh", { width = LABEL_W, height = ROW_H })
  self.frequencies = Dropdown.new(x + LABEL_W, y, cw - LABEL_W, ROW_H, {
    options = {},
    on_change = function() end,
  })
  y = y + ROW_H + 5

  -- Scale
  self.scale_label = Label.new(x, y, "Scale", { width = LABEL_W, height = ROW_H })
  self.scale = Dropdown.new(x + LABEL_W, y, cw - LABEL_W, ROW_H, {
    options = {
      { name = "0.5", value = 0.5 },
      { name = "0.75", value = 0.75 },
      { name = "1.0", value = 1.0 },
      { name = "1.25", value = 1.25 },
      { name = "1.5", value = 1.5 },
      { name = "2.0", value = 2.0 },
    },
    on_change = function() self:on_scale_change() end,
  })
  y = y + ROW_H + 5

  -- Rotation
  self.rot_label = Label.new(x, y, "Rotation", { width = LABEL_W, height = ROW_H })
  self.rotation = Dropdown.new(x + LABEL_W, y, cw - LABEL_W, ROW_H, {
    options = {
      { name = "0 (normal)", value = 0 },
      { name = "1 (90 CW)", value = 1 },
      { name = "2 (180)", value = 2 },
      { name = "3 (90 CCW)", value = 3 },
      { name = "4 (flip H)", value = 4 },
      { name = "5 (flip V)", value = 5 },
    },
    on_change = function() self:on_rotation_change() end,
  })
  y = y + ROW_H + 10

  -- Power
  self.power_label = Label.new(x, y, "Enabled", { width = LABEL_W, height = ROW_H })
  self.power = Toggle.new(x + LABEL_W, y, 50, 20, {
    value = true,
    on_toggle = function(val) self:on_power_toggle(val) end,
  })
  y = y + ROW_H + 15

  -- Separator
  y = y + 5
  -- Profiles section
  self.profile_label = Label.new(x, y, "Profiles", { width = cw, height = 20, font_size = 14 })
  y = y + 25

  local btn_w = math.floor((cw - 5 * MARGIN) / 6)
  self.profiles_dd = Dropdown.new(x, y, cw, ROW_H, {
    options = {},
    on_change = function() self:on_profile_select() end,
  })
  y = y + ROW_H + 5

  local bw = math.floor((cw - 3 * MARGIN) / 4)
  self.btn_save = Button.new(x, y, bw, ROW_H, "Save", { on_click = function() self:on_save_profile() end })
  self.btn_load = Button.new(x + bw + MARGIN, y, bw, ROW_H, "Load", { on_click = function() self:on_load_profile() end })
  self.btn_new = Button.new(x + 2 * (bw + MARGIN), y, bw, ROW_H, "New", { on_click = function() self:on_new_profile() end })
  self.btn_delete = Button.new(x + 3 * (bw + MARGIN), y, bw, ROW_H, "Del", {
    color = { 0.5, 0.2, 0.2 },
    hover_color = { 0.6, 0.25, 0.25 },
    on_click = function() self:on_delete_profile() end,
  })
  y = y + ROW_H + 15

  -- Apply section
  local apply_w = math.floor((cw - MARGIN) / 2)
  self.btn_apply = Button.new(x, y, apply_w, 35, "Apply", {
    color = { 0.2, 0.5, 0.3 },
    hover_color = { 0.25, 0.6, 0.35 },
    on_click = function() self:on_apply() end,
  })
  self.btn_center = Button.new(x + apply_w + MARGIN, y, apply_w, 35, "Center", {
    on_click = function() if self.on_center then self.on_center() end end,
  })
  y = y + 45

  -- Status
  self.status = Label.new(x, y, "", { width = cw, height = 20, color = { 1, 0.9, 0.5 } })

  -- Store all widgets for event dispatch
  self.widgets = {
    self.resolutions, self.frequencies, self.scale, self.rotation,
    self.power, self.profiles_dd,
    self.btn_save, self.btn_load, self.btn_new, self.btn_delete,
    self.btn_apply, self.btn_center,
  }
end

function PANEL:set_screen(gs, scale_factor)
  self.selected_gs = gs
  if not gs then
    self.screen_name:set_text("(no screen selected)")
    for _, w in ipairs(self.widgets) do
      w.enabled = false
    end
    return
  end
  for _, w in ipairs(self.widgets) do
    w.enabled = true
  end
  local screen = gs.screen

  self.screen_name:set_text(simplify_model_name(screen.name))

  -- Resolutions
  local res = sorted_resolutions(screen.available)
  local res_opts = {}
  local cur_idx = 1
  for i, r in ipairs(res) do
    table.insert(res_opts, { name = r.w .. " x " .. r.h, value = r })
    if screen.mode and r.w == screen.mode.width and r.h == screen.mode.height then
      cur_idx = i
    end
  end
  self.resolutions:set_options(res_opts)
  self.resolutions.selected_index = cur_idx

  -- Frequencies
  self:update_frequencies()

  -- Scale
  local scale_vals = { 0.5, 0.75, 1.0, 1.25, 1.5, 2.0 }
  self.scale.selected_index = get_closest_match(scale_vals, screen.scale)

  -- Rotation
  self.rotation.selected_index = screen.transform + 1

  -- Power
  self.power.toggled = screen.active
end

function PANEL:update_frequencies()
  local gs = self.selected_gs
  if not gs then return end
  local screen = gs.screen
  if not screen.mode then return end
  local freqs = sorted_frequencies(screen.available, screen.mode.width, screen.mode.height)
  local freq_opts = {}
  local cur_idx = 1
  for i, f in ipairs(freqs) do
    table.insert(freq_opts, { name = string.format("%.2f Hz", f), value = f })
    if math.abs(f - screen.mode.freq) < 0.1 then
      cur_idx = i
    end
  end
  self.frequencies:set_options(freq_opts)
  self.frequencies.selected_index = cur_idx
end

function PANEL:update_profiles()
  local profs = profiles.list_profiles()
  local opts = {}
  for _, p in ipairs(profs) do
    table.insert(opts, { name = p, value = p })
  end
  if #opts == 0 then
    table.insert(opts, { name = "(no profiles)", value = "" })
  end
  self.profiles_dd:set_options(opts)
end

function PANEL:on_resolution_change()
  local gs = self.selected_gs
  if not gs then return end
  local opt = self.resolutions:get_selected()
  if not opt or not opt.value then return end
  local screen = gs.screen
  local old_w, old_h = gs.target_rect.width, gs.target_rect.height
  screen.mode = { width = opt.value.w, height = opt.value.h, freq = screen.mode and screen.mode.freq or 60 }
  local SCREEN_SCALE = 8
  local new_w = math.floor(opt.value.w / SCREEN_SCALE / screen.scale)
  local new_h = math.floor(opt.value.h / SCREEN_SCALE / screen.scale)
  if screen.transform % 2 == 1 then
    new_w, new_h = new_h, new_w
  end
  gs.target_rect.width = new_w
  gs.target_rect.height = new_h
  self:update_frequencies()
  if self.on_screen_resized then
    self.on_screen_resized(gs, old_w, old_h)
  end
end

function PANEL:on_scale_change()
  local gs = self.selected_gs
  if not gs then return end
  local opt = self.scale:get_selected()
  if not opt then return end
  local screen = gs.screen
  screen.scale = opt.value
  local SCREEN_SCALE = 8
  if screen.mode then
    local old_w, old_h = gs.target_rect.width, gs.target_rect.height
    local new_w = math.floor(screen.mode.width / SCREEN_SCALE / screen.scale)
    local new_h = math.floor(screen.mode.height / SCREEN_SCALE / screen.scale)
    if screen.transform % 2 == 1 then
      new_w, new_h = new_h, new_w
    end
    gs.target_rect.width = new_w
    gs.target_rect.height = new_h
    if self.on_screen_resized then
      self.on_screen_resized(gs, old_w, old_h)
    end
  end
end

function PANEL:on_rotation_change()
  local gs = self.selected_gs
  if not gs then return end
  local opt = self.rotation:get_selected()
  if not opt then return end
  local screen = gs.screen
  screen.transform = opt.value
  local SCREEN_SCALE = 8
  if screen.mode then
    local old_w, old_h = gs.target_rect.width, gs.target_rect.height
    local new_w = math.floor(screen.mode.width / SCREEN_SCALE / screen.scale)
    local new_h = math.floor(screen.mode.height / SCREEN_SCALE / screen.scale)
    if screen.transform % 2 == 1 then
      new_w, new_h = new_h, new_w
    end
    gs.target_rect.width = new_w
    gs.target_rect.height = new_h
    if self.on_screen_resized then
      self.on_screen_resized(gs, old_w, old_h)
    end
  end
end

function PANEL:on_power_toggle(val)
  local gs = self.selected_gs
  if not gs then return end
  gs.screen.active = val
end

function PANEL:on_profile_select()
  -- Loading is done via the Load button
end

function PANEL:on_save_profile()
  local gs_list = self.get_all_screens and self.get_all_screens()
  if not gs_list then return end

  local data = {
    name = self.profiles_dd:get_selected_name(),
    screens = {},
  }
  for _, gs in ipairs(gs_list) do
    local screen = gs.screen
    table.insert(data.screens, {
      uid = screen.uid,
      active = screen.active,
      mode = screen.mode and {
        width = screen.mode.width,
        height = screen.mode.height,
        freq = screen.mode.freq,
      } or nil,
      scale = screen.scale,
      transform = screen.transform,
      position = {
        x = math.floor(gs.target_rect.x * 8),
        y = math.floor(gs.target_rect.y * 8),
      },
    })
  end

  local name = data.name
  if name == "" or name == "(no profiles)" then
    name = "profile_" .. os.date("%Y%m%d_%H%M%S")
  end
  local ok, err = profiles.save_profile(name, data)
  if ok then
    self.status:set_text("Saved: " .. name)
    self:update_profiles()
  else
    self.status:set_text("Error: " .. tostring(err))
  end
end

function PANEL:on_load_profile()
  local name = self.profiles_dd:get_selected_name()
  if name == "" or name == "(no profiles)" then
    self.status:set_text("No profile selected")
    return
  end

  local data, err = profiles.load_profile(name)
  if not data then
    self.status:set_text("Error: " .. tostring(err))
    return
  end

  local gs_list = self.get_all_screens and self.get_all_screens()
  if not gs_list then return end

  for _, saved in ipairs(data.screens or {}) do
    for _, gs in ipairs(gs_list) do
      if gs.screen.uid == saved.uid then
        gs.screen.active = saved.active
        gs.screen.scale = saved.scale or 1
        gs.screen.transform = saved.transform or 0
        if saved.mode then
          local mode = find_matching_mode(gs.screen.available, saved.mode.width, saved.mode.height, saved.mode.freq)
          if mode then
            gs.screen.mode = mode
          else
            gs.screen.mode = {
              width = saved.mode.width,
              height = saved.mode.height,
              freq = saved.mode.freq,
            }
            self.status:set_text("No matching mode for " .. gs.screen.uid)
          end
          local SCREEN_SCALE = 8
          local new_w = math.floor(gs.screen.mode.width / SCREEN_SCALE / gs.screen.scale)
          local new_h = math.floor(gs.screen.mode.height / SCREEN_SCALE / gs.screen.scale)
          if gs.screen.transform % 2 == 1 then
            new_w, new_h = new_h, new_w
          end
          gs.target_rect.width = new_w
          gs.target_rect.height = new_h
        end
        if saved.position then
          gs.target_rect.x = saved.position.x / 8
          gs.target_rect.y = saved.position.y / 8
        end
      end
    end
  end

  self.status:set_text("Loaded: " .. name)
  if self.on_screen_changed then
    self.on_screen_changed()
  end
end

function PANEL:on_new_profile()
  if not self._modal then
    local win_w = love.graphics.getWidth()
    local win_h = love.graphics.getHeight()
    self._modal = Modal.new(win_w, win_h, "New Profile Name", "Profile name",
      function(text)
        self.profiles_dd.selected_index = 0
        self.profiles_dd.options = { { name = text, value = text } }
        self.status:set_text("Save as: " .. text)
      end,
      function()
      end
    )
  end
  self._modal:show()
end

function PANEL:on_delete_profile()
  local name = self.profiles_dd:get_selected_name()
  if name == "" or name == "(no profiles)" then
    self.status:set_text("No profile selected")
    return
  end
  profiles.delete_profile(name)
  self:update_profiles()
  self.status:set_text("Deleted: " .. name)
end

function PANEL:cycle_profile()
  local opts = self.profiles_dd.options
  if not opts or #opts == 0 then return false end
  local idx = self.profiles_dd.selected_index + 1
  if idx > #opts then
    idx = 1
  end
  self.profiles_dd.selected_index = idx
  return true
end

function PANEL:load_profile()
  self:on_load_profile()
end

function PANEL:on_apply()
  if self.on_apply_callback then
    self.on_apply_callback()
  end
end

function PANEL:draw()
  if not self.visible then return end

  -- Background
  love.graphics.setColor(0.15, 0.15, 0.2, 0.95)
  love.graphics.rectangle("fill", self.x, self.y, self.w, self.h, 8, 8)
  love.graphics.setColor(0.3, 0.3, 0.4)
  love.graphics.rectangle("line", self.x, self.y, self.w, self.h, 8, 8)

  -- Draw all widgets
  for _, w in ipairs(self.widgets) do
    w:draw()
  end
  self.title:draw()
  self.screen_name:draw()
  self.res_label:draw()
  self.freq_label:draw()
  self.scale_label:draw()
  self.rot_label:draw()
  self.power_label:draw()
  self.profile_label:draw()
  self.status:draw()

  if self._modal then
    self._modal:draw()
  end
end

function PANEL:text_input(txt)
  if self._modal and self._modal:is_visible() then
    self._modal:on_text(txt)
    return true
  end
  return false
end

function PANEL:modal_keypressed(key)
  if self._modal and self._modal:is_visible() then
    self._modal:keypressed(key)
    return true
  end
  return false
end

function PANEL:modal_visible()
  return self._modal and self._modal:is_visible()
end

function PANEL:on_press(mx, my)
  if not self.visible then return false end
  -- Check widgets in reverse order (last drawn = on top)
  for i = #self.widgets, 1, -1 do
    local w = self.widgets[i]
    if w.on_press and w:on_press(mx, my) then
      return true
    end
  end
  return false
end

function PANEL:on_release(mx, my)
  if not self.visible then return false end
  for _, w in ipairs(self.widgets) do
    if w.on_release then
      w:on_release(mx, my)
    end
  end
  return false
end

function PANEL:on_move(mx, my)
  if not self.visible then return false end
  for _, w in ipairs(self.widgets) do
    if w.on_move then
      w:on_move(mx, my)
    end
  end
  return false
end

return PANEL
