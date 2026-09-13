local Widget = require("widgets.widget")

local Modal = {}
Modal.__index = Modal

function Modal.new(win_w, win_h, title, placeholder, on_submit, on_cancel)
  local self = setmetatable({}, Modal)
  self.win_w = win_w
  self.win_h = win_h
  self.title = title
  self.placeholder = placeholder or ""
  self.on_submit = on_submit
  self.on_cancel = on_cancel
  self.visible = false
  self.text = ""
  self.focused = false

  local modal_w = 300
  local modal_h = 120
  self.x = (win_w - modal_w) / 2
  self.y = (win_h - modal_h) / 2
  self.w = modal_w
  self.h = modal_h

  self.input_x = self.x + 20
  self.input_y = self.y + 50
  self.input_w = modal_w - 40
  self.input_h = 28

  return self
end

function Modal:show()
  self.visible = true
  self.text = ""
  self.focused = true
end

function Modal:hide()
  self.visible = false
  self.focused = false
end

function Modal:is_visible()
  return self.visible
end

function Modal:on_text(chr)
  if not self.focused then return end
  if chr == "\r" or chr == "\n" then
    if self.text ~= "" and self.on_submit then
      self.on_submit(self.text)
    end
    self:hide()
    return
  end
  if chr == "\1" then
    self:hide()
    if self.on_cancel then self.on_cancel() end
    return
  end
  if chr:match("[%z\1-\31]") == nil then
    self.text = self.text .. chr
  end
end

function Modal:keypressed(key)
  if not self.focused then return end
  if key == "backspace" then
    self.text = self.text:sub(1, -2)
  elseif key == "return" or key == "enter" then
    if self.text ~= "" and self.on_submit then
      self.on_submit(self.text)
    end
    self:hide()
  elseif key == "escape" then
    self:hide()
    if self.on_cancel then self.on_cancel() end
  end
end

function Modal:draw()
  if not self.visible then return end

  love.graphics.setColor(0, 0, 0, 0.5)
  love.graphics.rectangle("fill", 0, 0, self.win_w, self.win_h)

  love.graphics.setColor(0.15, 0.15, 0.2)
  love.graphics.rectangle("fill", self.x, self.y, self.w, self.h, 8, 8)
  love.graphics.setColor(0.4, 0.4, 0.5)
  love.graphics.rectangle("line", self.x, self.y, self.w, self.h, 8, 8)

  love.graphics.setColor(0.9, 0.9, 0.9)
  love.graphics.print(self.title, self.x + 20, self.y + 15)

  love.graphics.setColor(0.2, 0.2, 0.3)
  love.graphics.rectangle("fill", self.input_x, self.input_y, self.input_w, self.input_h, 4, 4)
  love.graphics.setColor(0.5, 0.5, 0.6)
  love.graphics.rectangle("line", self.input_x, self.input_y, self.input_w, self.input_h, 4, 4)

  love.graphics.setColor(0.8, 0.8, 0.8)
  local display_text = self.text
  if display_text == "" then
    love.graphics.setColor(0.5, 0.5, 0.5)
    display_text = self.placeholder
  end
  love.graphics.print(display_text, self.input_x + 8, self.input_y + 6)

  love.graphics.setColor(0.6, 0.6, 0.6)
  love.graphics.print("ENTER=OK  ESC=Cancel", self.x + 20, self.y + self.h - 25)
end

return Modal
