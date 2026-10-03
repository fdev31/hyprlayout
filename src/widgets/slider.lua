local Widget = require("widgets.widget")
local Anim = require("widgets.anim")
local theme = require("theme")

local Slider = Widget:extend("Slider")
function Slider.new(x, y, w, h, opts)
	opts = opts or {}
	local self = Widget.new(x, y, w, h)
	setmetatable(self, { __index = Slider })
	self.min = opts.min or 0
	self.max = opts.max or 100
	self.value = opts.value or self.min
	self.step = opts.step or 1
	self.on_change = opts.on_change or function() end
	self.format = opts.format or function(v)
		return tostring(v)
	end
	self._dragging = false
	self._hover = false
	self.scale = opts.scale or 1.0
	self.font_size = math.floor(12 * self.scale)
	self._font = love.graphics.newFont(self.font_size)
	self._value_w = math.floor(38 * self.scale)
	self._display = Anim.AnimFloat.new(self.value)
	return self
end

function Slider:_track_geom()
	local r = self.rect
	local track_x = r.x + self._value_w
	local track_w = r.width - self._value_w
	return track_x, track_w
end

function Slider:_value_from_x(mx)
	local track_x, track_w = self:_track_geom()
	local ratio = (mx - track_x) / track_w
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

	-- Animate display value toward actual value
	if self._dragging then
		self._display:snap(self.value)
	else
		self._display.target = self.value
		self._display:advance()
	end

	local track_x, track_w = self:_track_geom()
	local track_h = math.max(2, math.floor(4 * self.scale))
	local track_y = r.y + r.height / 2 - track_h / 2

	love.graphics.setColor(theme.track_color[1], theme.track_color[2], theme.track_color[3])
	love.graphics.rectangle("fill", track_x, track_y, track_w, track_h, 2, 2)

	local disp = self._display.value
	local ratio = (disp - self.min) / (self.max - self.min)
	ratio = math.max(0, math.min(1, ratio))
	local fill_w = ratio * track_w
	love.graphics.setColor(theme.fill_color[1], theme.fill_color[2], theme.fill_color[3])
	if fill_w > 0 then
		love.graphics.rectangle("fill", track_x, track_y, fill_w, track_h, 2, 2)
	end

	local knob_r = math.floor(7 * self.scale)
	local knob_x = track_x + fill_w
	local knob_y = r.y + r.height / 2
	local kc = (self._hover or self._dragging) and theme.knob_hover or theme.knob_color
	love.graphics.setColor(kc[1], kc[2], kc[3])
	love.graphics.circle("fill", knob_x, knob_y, knob_r)

	-- label
	love.graphics.setColor(theme.text_color[1], theme.text_color[2], theme.text_color[3])
	local val_text = self.format(self.value)
	love.graphics.print(val_text, r.x, r.y + (r.height - self._font:getHeight()) / 2)
end

return Slider
