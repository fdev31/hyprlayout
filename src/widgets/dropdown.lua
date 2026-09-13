local Widget = require("widgets.widget")
local Anim = require("widgets.anim")

local Dropdown = Widget:extend("Dropdown")

local BG_COLOR = { 0.25, 0.25, 0.3 }
local BORDER_COLOR = { 0.4, 0.4, 0.5 }
local HOVER_COLOR = { 0.35, 0.35, 0.45 }
local SELECTED_COLOR = { 0.2, 0.5, 0.3 }
local TEXT_COLOR = { 0.9, 0.9, 0.9 }

function Dropdown.new(x, y, w, h, opts)
  opts = opts or {}
  local self = Widget.new(x, y, w, h)
  setmetatable(self, { __index = Dropdown })
  self.options = opts.options or {}
  self.selected_index = opts.selected or 0
  self.on_change = opts.on_change or function() end
  self.font_size = opts.font_size or 13
  self._font = love.graphics.newFont(self.font_size)
  self.radius = opts.radius or 4
  self._open = false
  self._hover = false
  self._hover_option = -1
  self._pressed = false
  self._expand = Anim.AnimFloat.new(0)
  return self
end

function Dropdown:get_selected()
  if self.selected_index >= 0 and self.selected_index <= #self.options then
    return self.options[self.selected_index]
  end
  return nil
end

function Dropdown:get_selected_name()
  local opt = self:get_selected()
  if opt then
    return opt.name or tostring(opt)
  end
  return ""
end

function Dropdown:set_options(options)
  self.options = options
  if self.selected_index > #options then
    self.selected_index = 0
  end
end

function Dropdown:is_open()
  return self._open
end

function Dropdown:hit_options(mx, my)
  if not self._open then return nil end
  local opt_h = self.rect.height
  for i = 1, #self.options do
    local oy = self.rect.y + i * opt_h
    if mx >= self.rect.x and mx <= self.rect.x + self.rect.width
      and my >= oy and my <= oy + opt_h then
      return i
    end
  end
  return nil
end

function Dropdown:on_press(mx, my)
  if self._open then
    local idx = self:hit_options(mx, my)
    if idx then
      self.selected_index = idx
      self._open = false
      self.on_change(self.selected_index, self)
    else
      self._open = false
    end
    return true
  else
    if self:hit(mx, my) then
      self._open = true
      self._pressed = true
      return true
    end
  end
  return false
end

function Dropdown:on_release(mx, my)
  self._pressed = false
end

function Dropdown:on_move(mx, my)
  if self._open then
    local opt_h = self.rect.height
    self._hover_option = -1
    for i = 1, #self.options do
      local oy = self.rect.y + i * opt_h
      if mx >= self.rect.x and mx <= self.rect.x + self.rect.width
        and my >= oy and my <= oy + opt_h then
        self._hover_option = i
        break
      end
    end
  else
    self._hover = self:hit(mx, my)
  end
end

function Dropdown:draw()
  -- Advance animation (same pattern as original: set target + advance in draw)
  self._expand.target = self._open and 1 or 0
  self._expand:advance()

  local r = self.rect
  love.graphics.setFont(self._font)

  -- Main box
  local bg = self._hover and HOVER_COLOR or BG_COLOR
  love.graphics.setColor(bg[1], bg[2], bg[3])
  love.graphics.rectangle("fill", r.x, r.y, r.width, r.height, self.radius, self.radius)
  love.graphics.setColor(BORDER_COLOR[1], BORDER_COLOR[2], BORDER_COLOR[3])
  love.graphics.rectangle("line", r.x, r.y, r.width, r.height, self.radius, self.radius)

  -- Text
  love.graphics.setColor(TEXT_COLOR[1], TEXT_COLOR[2], TEXT_COLOR[3])
  local text = self:get_selected_name()
  local tx = r.x + 8
  local ty = r.y + (r.height - self._font:getHeight()) / 2
  love.graphics.print(text, tx, ty)

  -- Arrow
  local ax = r.x + r.width - 15
  local ay = r.y + r.height / 2
  love.graphics.setColor(TEXT_COLOR[1], TEXT_COLOR[2], TEXT_COLOR[3])
  local exp = self._expand.value
  if exp > 0.5 then
    love.graphics.polygon("fill", ax, ay + 3, ax + 6, ay + 3, ax + 3, ay - 3)
  else
    love.graphics.polygon("fill", ax, ay - 3, ax + 6, ay - 3, ax + 3, ay + 3)
  end
end

function Dropdown:draw_overlay()
  local exp = self._expand.value
  if exp < 0.01 then return end

  local r = self.rect
  love.graphics.setFont(self._font)
  local opt_h = r.height
  local total_h = #self.options * opt_h
  local visible_h = total_h * exp

  love.graphics.setScissor(r.x, r.y + r.height, r.width, visible_h)

  for i = 1, #self.options do
    local oy = r.y + i * opt_h
    local opt = self.options[i]
    local name = opt.name or tostring(opt)

    if i == self.selected_index then
      love.graphics.setColor(SELECTED_COLOR[1], SELECTED_COLOR[2], SELECTED_COLOR[3])
    elseif i == self._hover_option then
      love.graphics.setColor(HOVER_COLOR[1], HOVER_COLOR[2], HOVER_COLOR[3])
    else
      love.graphics.setColor(BG_COLOR[1], BG_COLOR[2], BG_COLOR[3])
    end
    love.graphics.rectangle("fill", r.x, oy, r.width, opt_h)
    love.graphics.setColor(BORDER_COLOR[1], BORDER_COLOR[2], BORDER_COLOR[3])
    love.graphics.rectangle("line", r.x, oy, r.width, opt_h)

    love.graphics.setColor(TEXT_COLOR[1], TEXT_COLOR[2], TEXT_COLOR[3])
    love.graphics.print(name, r.x + 8, oy + (opt_h - self._font:getHeight()) / 2)
  end

  love.graphics.setScissor()
end

return Dropdown
