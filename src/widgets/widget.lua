local Rect = require("core.rect")

local Widget = {}
Widget.__index = Widget

function Widget.new(x, y, w, h)
	return setmetatable({
		rect = Rect.new(x, y, w, h),
		visible = true,
		enabled = true,
	}, Widget)
end

function Widget:extend(name)
	local cls = {}
	cls.__index = cls
	setmetatable(cls, { __index = Widget })
	cls._name = name
	return cls
end

function Widget:hit(mx, my)
	return self.visible and self.enabled and self.rect:contains(mx, my)
end

function Widget:on_press(mx, my) end
function Widget:on_release(mx, my) end
function Widget:draw() end
function Widget:draw_overlay() end
function Widget:update(dt) end

return Widget
