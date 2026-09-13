local Widget = require("widgets.widget")

local Label = Widget:extend("Label")

function Label.new(x, y, text, opts)
  opts = opts or {}
  local self = Widget.new(x, y, opts.width or 200, opts.height or 20)
  setmetatable(self, { __index = Label })
  self.text = text or ""
  self.font_size = opts.font_size or 14
  self.color = opts.color or { 0.9, 0.9, 0.9 }
  self.align = opts.align or "left"
  self._font = love.graphics.newFont(self.font_size)
  return self
end

function Label:set_text(text)
  self.text = text
end

function Label:draw()
  love.graphics.setFont(self._font)
  love.graphics.setColor(self.color[1], self.color[2], self.color[3])
  local tw = love.graphics.getFont():getWidth(self.text)
  local tx = self.rect.x
  if self.align == "center" then
    tx = self.rect.x + (self.rect.width - tw) / 2
  elseif self.align == "right" then
    tx = self.rect.x + self.rect.width - tw
  end
  love.graphics.print(self.text, tx, self.rect.y + 2)
end

return Label
