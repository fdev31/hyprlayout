local Widget = require("widgets.widget")
local Rect = require("core.rect")

local ANIMATION_LENGTH = 8

local ALL_COLORS = {
  { 108, 158, 208 },
  { 126, 141, 80 },
  { 229, 181, 102 },
  { 108, 153, 186 },
  { 158, 78, 133 },
  { 172, 65, 66 },
  { 125, 213, 207 },
  { 208, 208, 208 },
}

local GuiScreen = setmetatable({}, { __index = Widget })
GuiScreen.__index = GuiScreen
GuiScreen.cur_color = 0

function GuiScreen.new(screen, rect)
  local self = setmetatable(Widget.new(rect.x, rect.y, rect.width, rect.height), GuiScreen)
  self.screen = screen
  self.target_rect = rect:copy()
  self.color = { 100, 100, 100 }
  self.dragging = false
  self.highlighted = false
  self.cur_border = 2.0
  self.preview = nil
  self._pulse = 0
  return self
end

function GuiScreen:set_preview(img)
  self.preview = img
end

function GuiScreen:genColor()
  GuiScreen.cur_color = GuiScreen.cur_color + 1
  if GuiScreen.cur_color > #ALL_COLORS then
    self.color = {
      math.random(100, 200),
      math.random(100, 200),
      math.random(100, 200),
    }
  else
    self.color = { unpack(ALL_COLORS[GuiScreen.cur_color]) }
  end
  self.drag_color = { self.color[1], self.color[2], self.color[3] }
end

function GuiScreen:set_position(x, y)
  self.rect.x = x
  self.rect.y = y
  self.target_rect.x = x
  self.target_rect.y = y
end

function GuiScreen:_animation_step()
  local r, t = self.rect, self.target_rect
  local vars = { "x", "y", "width", "height" }
  for _, var in ipairs(vars) do
    local cv = r[var]
    local tv = t[var]
    if cv ~= tv then
      if math.abs(tv - cv) < 2 then
        r[var] = tv
      else
        local tgt = (cv * ANIMATION_LENGTH + tv) / (ANIMATION_LENGTH + 1)
        if cv < tv then
          r[var] = math.min(tv, math.ceil(tgt))
        else
          r[var] = math.max(tv, math.floor(tgt))
        end
      end
    end
  end
end

function GuiScreen:update(dt)
  if not self.rect:equals(self.target_rect) then
    self:_animation_step()
  end
  if self.highlighted then
    self._pulse = self._pulse + dt
    if self.cur_border < 3 then
      self.cur_border = self.cur_border + dt * 10
    end
  else
    if self.cur_border > 2 then
      self.cur_border = self.cur_border - dt * 10
    end
  end
end

function GuiScreen:draw()
  local r = self.rect
  local color = self.dragging and self.drag_color or self.color

  if not self.screen.active then
    color = { math.floor(color[1] / 3), math.floor(color[2] / 3), math.floor(color[3] / 3) }
  end

  local border_color = { 100, 100, 155 }
  if not self.screen.active then
    border_color = { 70, 70, 70 }
  end
  if self.highlighted then
    border_color = { 255, 201, 0 }
  end

  love.graphics.setColor(color[1] / 255, color[2] / 255, color[3] / 255)
  love.graphics.rectangle("fill", r.x, r.y, r.width, r.height)

  if self.preview and self.screen.active then
    local sx = r.width / self.preview:getWidth()
    local sy = r.height / self.preview:getHeight()
    love.graphics.draw(self.preview, r.x, r.y, 0, sx, sy)
    love.graphics.setColor(0, 0, 0, 0.4)
    love.graphics.rectangle("fill", r.x, r.y, r.width, r.height)
  end

  love.graphics.setColor(border_color[1] / 255, border_color[2] / 255, border_color[3] / 255)
  love.graphics.setLineWidth(self.cur_border)
  love.graphics.rectangle("line", r.x, r.y, r.width, r.height)

  if self.highlighted then
    local pulse = 0.5 + 0.5 * math.sin(self._pulse * 3)
    local inset = 4
    local iw = r.width - inset * 2
    local ih = r.height - inset * 2
    if iw > 0 and ih > 0 then
      love.graphics.setColor(1, 0.85, 0, 0.4 + pulse * 0.4)
      love.graphics.setLineWidth(2 + pulse * 3)
      love.graphics.rectangle("line", r.x + inset, r.y + inset, iw, ih)
    end
  end
  love.graphics.setLineWidth(1)

  local tx, ty = r.x + r.width / 2, r.y + r.height / 2
  local font = love.graphics.getFont()
  love.graphics.setColor(0.94, 0.94, 0.94)
  love.graphics.printf(self.screen.name, r.x, ty - 10, r.width, "center")

  if self.screen.active and self.screen.mode then
    local label = string.format("%dx%d@%d",
      self.screen.mode.width, self.screen.mode.height, math.floor(self.screen.mode.freq))
    love.graphics.printf(label, r.x, ty - 25, r.width, "center")
    love.graphics.printf(self.screen.uid, r.x, ty + 5, r.width, "center")
  end
end

return GuiScreen
