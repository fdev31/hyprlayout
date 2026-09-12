local Widget = require("widgets.widget")

local Button = Widget:extend("Button")

local DEFAULT_COLOR = { 0.3, 0.35, 0.45 }
local HOVER_COLOR = { 0.4, 0.45, 0.55 }
local ACTIVE_COLOR = { 0.5, 0.55, 0.65 }

function Button.new(x, y, w, h, text, opts)
  opts = opts or {}
  local self = Widget.new(x, y, w, h)
  setmetatable(self, { __index = Button })
  self.text = text or ""
  self.on_click = opts.on_click or function() end
  self.color = opts.color or DEFAULT_COLOR
  self.hover_color = opts.hover_color or HOVER_COLOR
  self.active_color = opts.active_color or ACTIVE_COLOR
  self.font_size = opts.font_size or 13
  self._font = love.graphics.newFont(self.font_size)
  self._hover = false
  self._pressed = false
  return self
end

function Button:on_press(x, y)
  if self:hit(x, y) then
    self._pressed = true
    return true
  end
  return false
end

function Button:on_release(x, y)
  if self._pressed then
    self._pressed = false
    if self:hit(x, y) then
      self.on_click(self)
      return true
    end
    return true
  end
  return false
end

function Button:on_move(x, y)
  self._hover = self:hit(x, y)
end

function Button:draw()
  local c = self.color
  if self._pressed then
    c = self.active_color
  elseif self._hover then
    c = self.hover_color
  end
  love.graphics.setColor(c[1], c[2], c[3])
  love.graphics.rectangle("fill", self.rect.x, self.rect.y, self.rect.width, self.rect.height)
  love.graphics.setColor(1, 1, 1)
  love.graphics.setFont(self._font)
  local tw = love.graphics.getFont():getWidth(self.text)
  local tx = self.rect.x + (self.rect.width - tw) / 2
  local ty = self.rect.y + (self.rect.height - self.font_size) / 2
  love.graphics.print(self.text, tx, ty)
end

return Button
