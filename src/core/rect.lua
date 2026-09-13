local Rect = {}
Rect.__index = Rect

function Rect.new(x, y, w, h)
  return setmetatable({ x = x, y = y, width = w, height = h }, Rect)
end

function Rect:collide(other)
  return self.x < other.x + other.width
    and other.x < self.x + other.width
    and self.y < other.y + other.height
    and other.y < self.y + self.height
end

function Rect:contains(px, py)
  return px >= self.x and px <= self.x + self.width
    and py >= self.y and py <= self.y + self.height
end

function Rect:copy()
  return Rect.new(self.x, self.y, self.width, self.height)
end

function Rect:scaled(factor)
  return Rect.new(self.x * factor, self.y * factor, self.width * factor, self.height * factor)
end

function Rect:equals(other)
  return self.x == other.x and self.y == other.y
    and self.width == other.width and self.height == other.height
end

function Rect:center()
  return self.x + self.width / 2, self.y + self.height / 2
end

function Rect:topleft()
  return self.x, self.y
end

function Rect:topright()
  return self.x + self.width, self.y
end

function Rect:bottomright()
  return self.x + self.width, self.y + self.height
end

function Rect:bottomleft()
  return self.x, self.y + self.height
end

function Rect:ref_points()
  local cx = self.x + self.width / 2
  local cy = self.y + self.height / 2
  return {
    { pos = { self.x, self.y }, types = { "left", "top" } },
    { pos = { self.x + self.width, self.y }, types = { "right", "top" } },
    { pos = { self.x + self.width, self.y + self.height }, types = { "right", "bottom" } },
    { pos = { self.x, self.y + self.height }, types = { "left", "bottom" } },
    { pos = { cx, self.y }, types = { "center_x", "top" } },
    { pos = { cx, self.y + self.height }, types = { "center_x", "bottom" } },
    { pos = { self.x, cy }, types = { "left", "center_y" } },
    { pos = { self.x + self.width, cy }, types = { "right", "center_y" } },
  }
end

function Rect:__tostring()
  return string.format("Rect(%d, %d, %d, %d)", self.x, self.y, self.width, self.height)
end

-- Compute display size for a screen mode given canvas and screen scale
function Rect.screen_size(mode_w, mode_h, screen_scale, canvas_scale, transform)
  local w = math.floor(mode_w / canvas_scale / screen_scale)
  local h = math.floor(mode_h / canvas_scale / screen_scale)
  if transform % 2 == 1 then
    w, h = h, w
  end
  return w, h
end

return Rect
