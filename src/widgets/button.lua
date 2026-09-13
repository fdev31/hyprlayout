local Widget = require("widgets.widget")
local Anim = require("widgets.anim")

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
  self._col = Anim.AnimColor.new(self.color[1], self.color[2], self.color[3])
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
  -- Determine target color
  local tr, tg, tb
  if self._pressed then
    tr, tg, tb = self.active_color[1], self.active_color[2], self.active_color[3]
  elseif self._hover then
    tr, tg, tb = self.hover_color[1], self.hover_color[2], self.hover_color[3]
  else
    tr, tg, tb = self.color[1], self.color[2], self.color[3]
  end
  self._col.tr, self._col.tg, self._col.tb = tr, tg, tb
  self._col:advance()

  love.graphics.setColor(self._col.r, self._col.g, self._col.b)
  love.graphics.rectangle("fill", self.rect.x, self.rect.y, self.rect.width, self.rect.height)
  love.graphics.setColor(1, 1, 1)
  love.graphics.setFont(self._font)
  local tw = love.graphics.getFont():getWidth(self.text)
  local tx = self.rect.x + (self.rect.width - tw) / 2
  local ty = self.rect.y + (self.rect.height - self.font_size) / 2
  love.graphics.print(self.text, tx, ty)
end

return Button
