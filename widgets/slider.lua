local Widget = require("widgets.widget")

local Slider = Widget:extend("Slider")

local TRACK_COLOR = { 0.3, 0.3, 0.35 }
local FILL_COLOR = { 0.3, 0.6, 0.4 }
local KNOB_COLOR = { 0.9, 0.9, 0.9 }
local KNOB_HOVER = { 1.0, 1.0, 1.0 }
local TEXT_COLOR = { 0.9, 0.9, 0.9 }

function Slider.new(x, y, w, h, opts)
  opts = opts or {}
  local self = Widget.new(x, y, w, h)
  setmetatable(self, { __index = Slider })
  self.min = opts.min or 0
  self.max = opts.max or 100
  self.value = opts.value or self.min
  self.step = opts.step or 1
  self.on_change = opts.on_change or function() end
  self._dragging = false
  self._hover = false
  self.font_size = 12
  self._font = love.graphics.newFont(self.font_size)
  return self
end

function Slider:_value_from_x(mx)
  local r = self.rect
  local ratio = (mx - r.x) / r.width
  ratio = math.max(0, math.min(1, ratio))
  local raw = self.min + ratio * (self.max - self.min)
  local stepped = math.floor(raw / self.step + 0.5) * self.step
  return math.max(self.min, math.min(self.max, stepped))
end

function Slider:on_press(mx, my)
  if self:hit(mx, my) then
    self._dragging = true
    local new_val = self:_value_from_x(mx)
    if new_val ~= self.value then
      self.value = new_val
      self.on_change(self.value, self)
    end
    return true
  end
  return false
end

function Slider:on_drag(mx, my)
  if self._dragging then
    local new_val = self:_value_from_x(mx)
    if new_val ~= self.value then
      self.value = new_val
      self.on_change(self.value, self)
    end
  end
end

function Slider:on_release(mx, my)
  self._dragging = false
end

function Slider:on_move(mx, my)
  self._hover = self:hit(mx, my)
  if self._dragging then
    self:on_drag(mx, my)
  end
end

function Slider:draw()
  local r = self.rect
  love.graphics.setFont(self._font)

  local track_h = 4
  local track_y = r.y + r.height / 2 - track_h / 2

  love.graphics.setColor(TRACK_COLOR[1], TRACK_COLOR[2], TRACK_COLOR[3])
  love.graphics.rectangle("fill", r.x, track_y, r.width, track_h, 2, 2)

  local ratio = (self.value - self.min) / (self.max - self.min)
  local fill_w = ratio * r.width
  love.graphics.setColor(FILL_COLOR[1], FILL_COLOR[2], FILL_COLOR[3])
  if fill_w > 0 then
    love.graphics.rectangle("fill", r.x, track_y, fill_w, track_h, 2, 2)
  end

  local knob_r = 7
  local knob_x = r.x + fill_w
  local knob_y = r.y + r.height / 2
  love.graphics.setColor(
    self._hover or self._dragging and KNOB_HOVER[1] or KNOB_COLOR[1],
    self._hover or self._dragging and KNOB_HOVER[2] or KNOB_COLOR[2],
    self._hover or self._dragging and KNOB_HOVER[3] or KNOB_COLOR[3]
  )
  love.graphics.circle("fill", knob_x, knob_y, knob_r)

  love.graphics.setColor(TEXT_COLOR[1], TEXT_COLOR[2], TEXT_COLOR[3])
  local val_text = tostring(self.value)
  local tw = self._font:getWidth(val_text)
  love.graphics.print(val_text, r.x + r.width - tw - 4, r.y + (r.height - self.font_size) / 2)
end

return Slider
