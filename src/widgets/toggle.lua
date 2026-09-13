local Widget = require("widgets.widget")
local Anim = require("widgets.anim")

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
  self._knob_pos = Anim.AnimFloat.new(self.toggled and 1 or 0)
  self._track_col = Anim.AnimColor.new(
    self.toggled and ON_COLOR[1] or OFF_COLOR[1],
    self.toggled and ON_COLOR[2] or OFF_COLOR[2],
    self.toggled and ON_COLOR[3] or OFF_COLOR[3]
  )
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

  -- Set animation targets
  if self.toggled then
    self._knob_pos.target = 1
    self._track_col.tr, self._track_col.tg, self._track_col.tb = ON_COLOR[1], ON_COLOR[2], ON_COLOR[3]
  else
    self._knob_pos.target = 0
    self._track_col.tr, self._track_col.tg, self._track_col.tb = OFF_COLOR[1], OFF_COLOR[2], OFF_COLOR[3]
  end
  self._knob_pos:advance()
  self._track_col:advance()

  -- Track
  love.graphics.setColor(self._track_col.r, self._track_col.g, self._track_col.b)
  love.graphics.rectangle("fill", r.x, r.y, w, h, radius, radius)

  -- Knob
  local knob_x = r.x + radius + self._knob_pos.value * (w - 2 * radius)
  love.graphics.setColor(KNOB_COLOR[1], KNOB_COLOR[2], KNOB_COLOR[3])
  love.graphics.circle("fill", knob_x, r.y + radius, radius - 2)
end

return Toggle
