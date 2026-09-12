local Widget = require("widgets.widget")

local Toggle = Widget:extend("Toggle")

local OFF_COLOR = { 0.3, 0.3, 0.35 }
local ON_COLOR = { 0.2, 0.6, 0.3 }
local KNOB_COLOR = { 0.9, 0.9, 0.9 }

function Toggle.new(x, y, w, h, opts)
  opts = opts or {}
  local self = Widget.new(x, y, w, h)
  setmetatable(self, { __index = Toggle })
  self.toggled = opts.value or false
  self.on_toggle = opts.on_toggle or function() end
  self._hover = false
  return self
end

function Toggle:on_press(x, y)
  if self:hit(x, y) then
    self.toggled = not self.toggled
    self.on_toggle(self.toggled, self)
    return true
  end
  return false
end

function Toggle:on_move(x, y)
  self._hover = self:hit(x, y)
end

function Toggle:draw()
  local r = self.rect
  local h = r.height
  local w = r.width
  local radius = h / 2

  love.graphics.setColor(
    self.toggled and ON_COLOR[1] or OFF_COLOR[1],
    self.toggled and ON_COLOR[2] or OFF_COLOR[2],
    self.toggled and ON_COLOR[3] or OFF_COLOR[3]
  )
  love.graphics.rectangle("fill", r.x, r.y, w, h, radius, radius)

  local knob_x
  if self.toggled then
    knob_x = r.x + w - radius
  else
    knob_x = r.x + radius
  end
  love.graphics.setColor(KNOB_COLOR[1], KNOB_COLOR[2], KNOB_COLOR[3])
  love.graphics.circle("fill", knob_x, r.y + radius, radius - 2)
end

return Toggle
