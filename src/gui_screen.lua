local Widget = require("widgets.widget")
local Rect = require("core.rect")

local ANIMATION_LENGTH = 8
local SCREEN_BORDER = 2
local SCREEN_BORDER_SELECTED = 8

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
	self.ui_scale = 1.0
	self._font = nil
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

-- Recompute target size from the current mode and apply it.
-- Returns the previous width/height, or nothing if there is no mode.
function GuiScreen:resize_to_mode(canvas_scale)
	local screen = self.screen
	if not screen.mode then
		return
	end
	local old_w, old_h = self.target_rect.width, self.target_rect.height
	local new_w, new_h = Rect.screen_size(
		screen.mode.width,
		screen.mode.height,
		screen.scale,
		canvas_scale,
		screen.transform
	)
	self.target_rect.width = new_w
	self.target_rect.height = new_h
	return old_w, old_h
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
		if self.cur_border < SCREEN_BORDER_SELECTED then
			self.cur_border = self.cur_border + dt * 10
		end
	else
		if self.cur_border > SCREEN_BORDER then
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
	love.graphics.rectangle(
		"line",
		r.x + (self.cur_border / 2),
		r.y + (self.cur_border / 2),
		r.width - self.cur_border,
		r.height - self.cur_border
	)

	love.graphics.setLineWidth(1)

	local s = self.ui_scale
	local fs = math.floor(14 * s)
	local fs_port = math.floor(16 * s)
	if not self._font or self._font_size ~= fs then
		self._font_size = fs
		self._font = love.graphics.newFont(fs)
	end
	if not self._font_port or self._font_port_size ~= fs_port then
		self._font_port_size = fs_port
		self._font_port = love.graphics.newFont(fs_port)
	end
	love.graphics.setFont(self._font)
	local tx, ty = r.x + r.width / 2, r.y + r.height / 2
	love.graphics.setColor(0.94, 0.94, 0.94)

	love.graphics.setScissor(r.x, r.y, r.width, r.height)

	local function draw_centered(text, y, font, bold)
		font = font or self._font
		love.graphics.setFont(font)
		local x = tx - font:getWidth(text) / 2
		love.graphics.print(text, x, y)
		if bold then
			love.graphics.print(text, x + 1, y)
		end
	end

	local function draw_left(text, y, font, bold)
		font = font or self._font
		love.graphics.setFont(font)
		local x = r.x + 5
		love.graphics.print(text, x, y)
		if bold then
			love.graphics.print(text, x + 1, y)
		end
	end

	local name_fits_on_screen = self._font:getWidth(self.screen.name) < r.width - 10
	if name_fits_on_screen then
		draw_centered(self.screen.name, ty - math.floor(10 * s))
	else
		draw_left(self.screen.name, ty - math.floor(10 * s))
	end

	if self.screen.active and self.screen.mode then
		local label = string.format(
			"%dx%d@%d",
			self.screen.mode.width,
			self.screen.mode.height,
			math.floor(self.screen.mode.freq)
		)
		draw_centered(label, ty - math.floor(25 * s))
		draw_centered(self.screen.uid, ty + math.floor(5 * s), self._font_port, true)
	end

	if self.screen.hdr_enabled then
		local hdr_text = "HDR"
		local hdr_font = self._font_port or self._font
		love.graphics.setFont(hdr_font)
		local hdr_w = hdr_font:getWidth(hdr_text)
		local hdr_x = r.x + r.width - hdr_w - 6
		local hdr_y = r.y + 4
		love.graphics.setColor(0.9, 0.35, 0.15)
		love.graphics.rectangle("fill", hdr_x, hdr_y, hdr_w + 6, hdr_font:getHeight() + 4, 3, 3)
		love.graphics.setColor(0.94, 0.94, 0.94)
		love.graphics.print(hdr_text, hdr_x + 3, hdr_y + 2)
	end

	love.graphics.setScissor()
end

return GuiScreen
