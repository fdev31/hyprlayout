local Widget = require("widgets.widget")
local Button = require("widgets.button")
local Dropdown = require("widgets.dropdown")
local Label = require("widgets.label")
local Toggle = require("widgets.toggle")
local Slider = require("widgets.slider")
local Modal = require("widgets.modal")
local profiles = require("core.profiles")
local apply = require("core.apply")
local Rect = require("core.rect")

local PANEL = {}
PANEL.__index = PANEL

PANEL.PANEL_W = 280
PANEL.DEFAULT_CANVAS_SCALE = 6
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

local CM_OPTIONS = {
  { name = "auto", value = "auto" },
  { name = "srgb", value = "srgb" },
  { name = "dcip3", value = "dcip3" },
  { name = "dp3", value = "dp3" },
  { name = "adobe", value = "adobe" },
  { name = "wide", value = "wide" },
  { name = "edid", value = "edid" },
  { name = "hdr", value = "hdr" },
  { name = "hdredid", value = "hdredid" },
}

local SDR_EOTF_OPTIONS = {
  { name = "default", value = "default" },
  { name = "srgb", value = "srgb" },
  { name = "gamma22", value = "gamma22" },
}

local function find_option_index(options, value)
  for i, o in ipairs(options) do
    if o.value == value then
      return i
    end
  end
  return 1
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
  self.screen_widgets = {}
  self.visible = true
  self.selected_gs = nil
  self.screen_settings_visible = false
  self.attract_enabled = true
  self.scroll = 0
  self._max_scroll = 0
  self._scroll_widgets = {}
  self._view_top = 0
  self._view_h = 0
  return self
end

-- Shift all scrollable content widgets up by the current scroll offset.
function PANEL:apply_scroll()
  for _, item in ipairs(self._scroll_widgets) do
    item.widget.rect.y = item.base_y - self.scroll
  end
end

-- Returns true if the mouse is over the panel.
function PANEL:hovered(mx, my)
  return self.visible and mx >= self.x and mx <= self.x + self.w and my >= self.y and my <= self.y + self.h
end

-- Handle a vertical wheel event while hovering the panel.
-- Returns true if the event was consumed by the panel.
function PANEL:handle_scroll(dy)
  if not self.visible then return false end
  local mx, my = love.mouse.getX(), love.mouse.getY()
  if not self:hovered(mx, my) then return false end
  if self._max_scroll <= 0 then return true end
  local new_scroll = self.scroll - dy * 40
  new_scroll = math.max(0, math.min(self._max_scroll, new_scroll))
  if new_scroll ~= self.scroll then
    self.scroll = new_scroll
    self:apply_scroll()
  end
  return true
end

function PANEL:layout(win_w, win_h)
  local ui_scale = self.ui_scale_factor or 1.0
  local pw = math.floor(PANEL.PANEL_W * ui_scale)
  local row_h = math.floor(ROW_H * ui_scale)
  local margin = math.floor(MARGIN * ui_scale)
  local label_w = math.floor(LABEL_W * ui_scale)
  local dd_font = math.floor(13 * ui_scale)
  local btn_font = math.floor(13 * ui_scale)

  self.x = win_w - pw - margin
  self.y = margin
  self.w = pw
  self.h = win_h - 2 * margin

  local x = self.x + margin
  local y = self.y + margin
  local cw = self.w - 2 * margin

  self.widgets = {}
  self.screen_widgets = {}

  -- === GENERAL SECTION (always visible) ===
  self.title = Label.new(x, y, "General", { width = cw, height = 20, font_size = math.floor(15 * ui_scale), align = "center" })
  y = y + math.floor(30 * ui_scale)

  -- Canvas
  self.ss_label = Label.new(x, y, "Canvas", { width = label_w, height = row_h, font_size = math.floor(14 * ui_scale) })
  local ss_val = self.screen_scale and self.screen_scale.value or PANEL.DEFAULT_CANVAS_SCALE
  self.screen_scale = Slider.new(x + label_w, y, cw - label_w, row_h, {
    min = 2, max = 16, step = 1, value = ss_val, scale = ui_scale,
    on_change = function(val) self.on_screen_scale_change(val) end,
  })
  y = y + row_h + 5

  -- UI Scale
  self.ui_label = Label.new(x, y, "UI Scale", { width = label_w, height = row_h, font_size = math.floor(14 * ui_scale) })
  self.ui_scale = Slider.new(x + label_w, y, cw - label_w, row_h, {
    min = 0.5, max = 2.0, step = 0.25, value = self.ui_scale_factor or 1.0, scale = ui_scale,
    on_change = function(val) self.on_ui_scale_change(val) end,
  })
  y = y + row_h + 5

  -- Attraction
  self.attract_label = Label.new(x, y, "Attraction", { width = label_w, height = row_h, font_size = math.floor(14 * ui_scale) })
  self.attract = Toggle.new(x + label_w, y, math.floor(50 * ui_scale), math.floor(20 * ui_scale), {
    value = self.attract_enabled ~= false,
    on_toggle = function(val) self.on_attract_toggle(val) end,
  })
  y = y + row_h + 5

  -- Reload
  local reload_w = math.floor((cw - margin) / 2)
  self.btn_reload = Button.new(x, y, reload_w, row_h, "Reload", {
    font_size = btn_font,
    on_click = function()
      if self.on_reload then self.on_reload() end
    end,
  })
  y = y + row_h + 15

  -- Profiles section
  self.profile_label = Label.new(x, y, "Profiles", { width = cw, height = 20, font_size = math.floor(14 * ui_scale) })
  y = y + math.floor(25 * ui_scale)

  self.profiles_dd = Dropdown.new(x, y, cw, row_h, {
    font_size = dd_font,
    options = {},
    on_change = function() self:on_profile_select() end,
  })
  y = y + row_h + 5

  local bw = math.floor((cw - 3 * margin) / 4)
  self.btn_save = Button.new(x, y, bw, row_h, "Save", { font_size = btn_font, on_click = function() self:on_save_profile() end })
  self.btn_load = Button.new(x + bw + margin, y, bw, row_h, "Load", { font_size = btn_font, on_click = function() self:on_load_profile() end })
  self.btn_new = Button.new(x + 2 * (bw + margin), y, bw, row_h, "New", { font_size = btn_font, on_click = function() self:on_new_profile() end })
  self.btn_delete = Button.new(x + 3 * (bw + margin), y, bw, row_h, "Del", {
    font_size = btn_font,
    color = { 0.5, 0.2, 0.2 },
    hover_color = { 0.6, 0.25, 0.25 },
    on_click = function() self:on_delete_profile() end,
  })
  y = y + row_h + 15

  -- General widgets
  local general_widgets = {
    self.screen_scale, self.ui_scale, self.attract, self.btn_reload,
    self.profiles_dd,
    self.btn_save, self.btn_load, self.btn_new, self.btn_delete,
  }

  -- === SCREEN SETTINGS SECTION (conditional) ===
  if self.screen_settings_visible then
    y = y + 5
    self.screen_title = Label.new(x, y, "Screen Settings", { width = cw, height = 20, font_size = math.floor(15 * ui_scale), align = "center" })
    y = y + math.floor(30 * ui_scale)

    self.screen_name = Label.new(x, y, "", { width = cw, height = 20, font_size = math.floor(13 * ui_scale) })
    y = y + row_h + 5

    -- Power
    self.power_label = Label.new(x, y, "Enabled", { width = label_w, height = row_h, font_size = math.floor(14 * ui_scale) })
    self.power = Toggle.new(x + label_w, y, math.floor(50 * ui_scale), math.floor(20 * ui_scale), {
      value = true,
      on_toggle = function(val) self:on_power_toggle(val) end,
    })
    y = y + row_h + 5

    -- Resolution
    self.res_label = Label.new(x, y, "Resolution", { width = label_w, height = row_h, font_size = math.floor(14 * ui_scale) })
    self.resolutions = Dropdown.new(x + label_w, y, cw - label_w, row_h, {
      font_size = dd_font,
      options = {},
      on_change = function() self:on_resolution_change() end,
    })
    y = y + row_h + 5

    -- Frequency
    self.freq_label = Label.new(x, y, "Refresh", { width = label_w, height = row_h, font_size = math.floor(14 * ui_scale) })
    self.frequencies = Dropdown.new(x + label_w, y, cw - label_w, row_h, {
      font_size = dd_font,
      options = {},
      on_change = function() end,
    })
    y = y + row_h + 5

    -- Scale
    self.scale_label = Label.new(x, y, "Scale", { width = label_w, height = row_h, font_size = math.floor(14 * ui_scale) })
    self.scale = Dropdown.new(x + label_w, y, cw - label_w, row_h, {
      font_size = dd_font,
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
    y = y + row_h + 5

    -- Rotation
    self.rot_label = Label.new(x, y, "Rotation", { width = label_w, height = row_h, font_size = math.floor(14 * ui_scale) })
    self.rotation = Dropdown.new(x + label_w, y, cw - label_w, row_h, {
      font_size = dd_font,
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
    y = y + row_h + 5

    -- HDR (master toggle: enables 10 bit + color management + SDR options)
    self.hdr_label = Label.new(x, y, "HDR", { width = label_w, height = row_h, font_size = math.floor(14 * ui_scale) })
    self.hdr = Toggle.new(x + label_w, y, math.floor(50 * ui_scale), math.floor(20 * ui_scale), {
      value = false,
      on_toggle = function(val) self:on_hdr_toggle(val) end,
    })
    y = y + row_h + 5

    -- HDR sub-options (only shown when HDR is enabled)
    local hdr_on = self.selected_gs and self.selected_gs.screen.hdr_enabled
    self._hdr_sub_visible = hdr_on
    if hdr_on then
      self.cm_label = Label.new(x, y, "CM", { width = label_w, height = row_h, font_size = math.floor(14 * ui_scale) })
      self.cm = Dropdown.new(x + label_w, y, cw - label_w, row_h, {
        font_size = dd_font,
        options = CM_OPTIONS,
        on_change = function() self:on_cm_change() end,
      })
      y = y + row_h + 5

      self.sdrb_label = Label.new(x, y, "SDR Bright", { width = label_w, height = row_h, font_size = math.floor(14 * ui_scale) })
      self.sdrbrightness = Slider.new(x + label_w, y, cw - label_w, row_h, {
        min = 0.0, max = 3.0, step = 0.01, value = 1.0, scale = ui_scale,
        on_change = function(val) self:on_sdrbrightness_change(val) end,
      })
      y = y + row_h + 5

      self.sdrs_label = Label.new(x, y, "SDR Sat", { width = label_w, height = row_h, font_size = math.floor(14 * ui_scale) })
      self.sdrsaturation = Slider.new(x + label_w, y, cw - label_w, row_h, {
        min = 0.0, max = 3.0, step = 0.01, value = 1.0, scale = ui_scale,
        on_change = function(val) self:on_sdrsaturation_change(val) end,
      })
      y = y + row_h + 5

      self.sdr_eotf_label = Label.new(x, y, "SDR EOTF", { width = label_w, height = row_h, font_size = math.floor(14 * ui_scale) })
      self.sdr_eotf = Dropdown.new(x + label_w, y, cw - label_w, row_h, {
        font_size = dd_font,
        options = SDR_EOTF_OPTIONS,
        on_change = function() self:on_sdr_eotf_change() end,
      })
      y = y + row_h + 5
    end
    y = y + 5

    -- Apply section
    local apply_w = math.floor((cw - MARGIN) / 2)
    local apply_h = math.floor(35 * ui_scale)
    self.btn_apply = Button.new(x, y, apply_w, apply_h, "Apply", {
      font_size = btn_font,
      color = { 0.2, 0.5, 0.3 },
      hover_color = { 0.25, 0.6, 0.35 },
      on_click = function() self:on_apply() end,
    })
    self.btn_center = Button.new(x + apply_w + MARGIN, y, apply_w, apply_h, "Center", {
      font_size = btn_font,
      on_click = function() if self.on_center then self.on_center() end end,
    })
    y = y + apply_h + 10

    self.screen_widgets = {
      self.resolutions, self.frequencies, self.scale, self.rotation,
      self.power, self.hdr, self.btn_apply, self.btn_center,
    }
    if hdr_on then
      table.insert(self.screen_widgets, self.cm)
      table.insert(self.screen_widgets, self.sdrbrightness)
      table.insert(self.screen_widgets, self.sdrsaturation)
      table.insert(self.screen_widgets, self.sdr_eotf)
    end
  end

  -- Combine all widgets for event dispatch
  for _, w in ipairs(general_widgets) do
    table.insert(self.widgets, w)
  end
  for _, w in ipairs(self.screen_widgets) do
    table.insert(self.widgets, w)
  end

  -- Content bottom (Y after the last content row, before the status bar)
  local content_bottom = y
  self._view_top = self.y + margin
  local interior_h = self.h - 2 * margin

  -- Track base positions of every scrollable widget (interactive + labels)
  self._scroll_widgets = {}
  local function track(w)
    if w then table.insert(self._scroll_widgets, { widget = w, base_y = w.rect.y }) end
  end
  for _, w in ipairs(self.widgets) do track(w) end
  track(self.title)
  track(self.ss_label)
  track(self.ui_label)
  track(self.attract_label)
  track(self.profile_label)
  if self.screen_settings_visible then
    track(self.screen_title)
    track(self.screen_name)
    track(self.power_label)
    track(self.res_label)
    track(self.freq_label)
    track(self.scale_label)
    track(self.rot_label)
    track(self.hdr_label)
    if self._hdr_sub_visible then
      track(self.cm_label)
      track(self.sdrb_label)
      track(self.sdrs_label)
      track(self.sdr_eotf_label)
    end
  end

  local status_h = 20
  local content_h = content_bottom - self._view_top
  if content_h <= interior_h then
    -- Everything fits: status sits right after the content, no scrolling
    self.status = Label.new(x, content_bottom, "", { width = cw, height = status_h, font_size = math.floor(14 * ui_scale), color = { 1, 0.9, 0.5 } })
    self._view_h = interior_h
    self._max_scroll = 0
    self.scroll = 0
  else
    -- Content overflows: pin status at the bottom, scroll the content above it
    local status_y = self.y + self.h - margin - status_h
    self.status = Label.new(x, status_y, "", { width = cw, height = status_h, font_size = math.floor(14 * ui_scale), color = { 1, 0.9, 0.5 } })
    local gap = 8
    self._view_h = math.max(0, status_y - self._view_top - gap)
    self._max_scroll = math.max(0, content_h - self._view_h)
    self.scroll = math.max(0, math.min(self.scroll, self._max_scroll))
  end
  self:apply_scroll()
end

function PANEL:set_screen(gs, scale_factor)
  local was_visible = self.screen_settings_visible
  self.selected_gs = gs
  self.screen_settings_visible = (gs ~= nil)

  if self.screen_settings_visible ~= was_visible then
    if self.on_visibility_changed then
      self.on_visibility_changed()
    end
    return
  end

  if not gs then
    return
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

  -- HDR
  self.hdr.toggled = screen.hdr_enabled
  -- If the panel was laid out with a different HDR state, re-layout to show/hide sub-widgets
  if (screen.hdr_enabled and not self._hdr_sub_visible) or (not screen.hdr_enabled and self._hdr_sub_visible) then
    if self.on_visibility_changed then
      self.on_visibility_changed()
    end
    return
  end
  if screen.hdr_enabled then
    self.cm.selected_index = find_option_index(CM_OPTIONS, screen.cm or "auto")
    self.sdrbrightness.value = screen.sdrbrightness or 1.0
    self.sdrsaturation.value = screen.sdrsaturation or 1.0
    self.sdr_eotf.selected_index = find_option_index(SDR_EOTF_OPTIONS, screen.sdr_eotf or "default")
  end
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
  if self._selected_profile_name then
    for i, o in ipairs(opts) do
      if o.name == self._selected_profile_name then
        self.profiles_dd.selected_index = i
        break
      end
    end
  end
end

function PANEL:on_resolution_change()
  local gs = self.selected_gs
  if not gs then return end
  local opt = self.resolutions:get_selected()
  if not opt or not opt.value then return end
  local screen = gs.screen
  local old_w, old_h = gs.target_rect.width, gs.target_rect.height
  screen.mode = { width = opt.value.w, height = opt.value.h, freq = screen.mode and screen.mode.freq or 60 }
  local new_w, new_h = Rect.screen_size(opt.value.w, opt.value.h, screen.scale, self.screen_scale.value, screen.transform)
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
  if screen.mode then
    local old_w, old_h = gs.target_rect.width, gs.target_rect.height
    local new_w, new_h = Rect.screen_size(screen.mode.width, screen.mode.height, screen.scale, self.screen_scale.value, screen.transform)
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
  if screen.mode then
    local old_w, old_h = gs.target_rect.width, gs.target_rect.height
    local new_w, new_h = Rect.screen_size(screen.mode.width, screen.mode.height, screen.scale, self.screen_scale.value, screen.transform)
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

function PANEL:on_hdr_toggle(val)
  local gs = self.selected_gs
  if not gs then return end
  gs.screen.hdr_enabled = val
  if self.on_visibility_changed then
    self.on_visibility_changed()
  end
end

function PANEL:on_cm_change()
  local gs = self.selected_gs
  if not gs then return end
  local opt = self.cm:get_selected()
  if opt then
    gs.screen.cm = opt.value
  end
end

function PANEL:on_sdrbrightness_change(val)
  local gs = self.selected_gs
  if not gs then return end
  gs.screen.sdrbrightness = val
end

function PANEL:on_sdrsaturation_change(val)
  local gs = self.selected_gs
  if not gs then return end
  gs.screen.sdrsaturation = val
end

function PANEL:on_sdr_eotf_change()
  local gs = self.selected_gs
  if not gs then return end
  local opt = self.sdr_eotf:get_selected()
  if opt then
    gs.screen.sdr_eotf = opt.value
  end
end

function PANEL:on_attract_toggle(val)
  self.attract_enabled = val
  if self.on_attract_toggle then
    self.on_attract_toggle(val)
  end
end

function PANEL:on_screen_scale_change(val)
  if self.on_screen_scale_change then
    self.on_screen_scale_change(val)
  end
end

function PANEL:on_ui_scale_change(val)
  if self.on_ui_scale_change then
    self.on_ui_scale_change(val)
  end
end

function PANEL:on_profile_select()
  self._selected_profile_name = self.profiles_dd:get_selected_name()
  -- Loading is done via the Load button
end

function PANEL:on_save_profile()
  local gs_list = self.get_all_screens and self.get_all_screens()
  if not gs_list then return end

  local name = self.profiles_dd:get_selected_name()
  if name == "" or name == "(no profiles)" then
    if not self._modal then
      local win_w = love.graphics.getWidth()
      local win_h = love.graphics.getHeight()
      self._modal = Modal.new(win_w, win_h, "Save Profile", "Profile name",
        function(text)
          self:_do_save_profile(text)
        end,
        function()
        end
      )
    end
    self._modal:show()
    return
  end
  self:_do_save_profile(name)
end

function PANEL:_do_save_profile(name)
  local gs_list = self.get_all_screens and self.get_all_screens()
  if not gs_list then return end

  local data = {
    name = name,
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
      hdr_enabled = screen.hdr_enabled,
      cm = screen.cm,
      sdrbrightness = screen.sdrbrightness,
      sdrsaturation = screen.sdrsaturation,
      sdr_eotf = screen.sdr_eotf,
      position = {
        x = math.floor(gs.target_rect.x * self.screen_scale.value),
        y = math.floor(gs.target_rect.y * self.screen_scale.value),
      },
    })
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
        gs.screen.hdr_enabled = saved.hdr_enabled or false
        gs.screen.cm = saved.cm or "auto"
        gs.screen.sdrbrightness = saved.sdrbrightness or 1.0
        gs.screen.sdrsaturation = saved.sdrsaturation or 1.0
        gs.screen.sdr_eotf = saved.sdr_eotf or "default"
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
          local new_w, new_h = Rect.screen_size(gs.screen.mode.width, gs.screen.mode.height, gs.screen.scale, self.screen_scale.value, gs.screen.transform)
          gs.target_rect.width = new_w
          gs.target_rect.height = new_h
        end
        if saved.position then
          local sc = self.screen_scale.value or PANEL.DEFAULT_CANVAS_SCALE
          gs.target_rect.x = saved.position.x / sc
          gs.target_rect.y = saved.position.y / sc
        end
      end
    end
  end

  self.status:set_text("Loaded: " .. name)
  if self.on_screen_changed then
    self.on_screen_changed()
  end
  if self.on_visibility_changed then
    self.on_visibility_changed()
  end
end

function PANEL:on_new_profile()
  if not self._modal then
    local win_w = love.graphics.getWidth()
    local win_h = love.graphics.getHeight()
    self._modal = Modal.new(win_w, win_h, "New Profile Name", "Profile name",
      function(text)
        self:_do_save_profile(text)
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
  self._selected_profile_name = self.profiles_dd:get_selected_name()
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

  -- Scrollable content, clipped to the viewport (panel top .. just above the status bar).
  -- Note: setScissor must be reset explicitly afterwards - LÖVE's push/pop does NOT restore it.
  local clip_h = self._view_top + self._view_h - self.y
  love.graphics.setScissor(self.x, self.y, self.w, clip_h)

  -- Draw all interactive widgets
  for _, w in ipairs(self.widgets) do
    w:draw()
  end

  -- General labels
  self.title:draw()
  self.ss_label:draw()
  self.ui_label:draw()
  self.attract_label:draw()
  self.profile_label:draw()

  -- Screen settings labels (conditional)
  if self.screen_settings_visible then
    self.screen_title:draw()
    self.screen_name:draw()
    self.power_label:draw()
    self.res_label:draw()
    self.freq_label:draw()
    self.scale_label:draw()
    self.rot_label:draw()
    self.hdr_label:draw()
    if self.selected_gs and self.selected_gs.screen.hdr_enabled then
      self.cm_label:draw()
      self.sdrb_label:draw()
      self.sdrs_label:draw()
      self.sdr_eotf_label:draw()
    end
  end

  love.graphics.setScissor()  -- reset so the clip doesn't leak onto the canvas

  self.status:draw()

  -- Draw overlays (dropdown options) on top of everything
  for _, w in ipairs(self.widgets) do
    w:draw_overlay()
  end

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
  -- Open dropdowns get absolute priority (options overlay everything)
  for _, w in ipairs(self.widgets) do
    if w.is_open and w:is_open() then
      w:on_press(mx, my)
      return true
    end
  end
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
  -- Open dropdowns get hover priority
  local has_open = false
  for _, w in ipairs(self.widgets) do
    if w.is_open and w:is_open() then
      has_open = true
      if w.on_move then w:on_move(mx, my) end
    end
  end
  if has_open then return false end
  for _, w in ipairs(self.widgets) do
    if w.on_move then
      w:on_move(mx, my)
    end
  end
  return false
end

return PANEL
