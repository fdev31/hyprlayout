local Widget = require("widgets.widget")
local Anim = require("widgets.anim")
local icons = require("core.icons")

local Button = Widget:extend("Button")

local DEFAULT_COLOR = { 0.3, 0.35, 0.45 }
local HOVER_COLOR = { 0.4, 0.45, 0.55 }
local ACTIVE_COLOR = { 0.5, 0.55, 0.65 }

-- Resolve an icon spec into a love.Graphics.Image, or nil.
-- Accepts a named icon (key in core.icons), a raw base64 PNG string, or an
-- already-decoded love.Graphics.Image.
local function resolve_icon(icon)
	if not icon then
		return nil
	end
	if type(icon) == "userdata" and icon.getWidth then
		return icon
	end
	if type(icon) == "string" then
		local named = icons.decode(icon)
		if named then
			return named
		end
		local ok, data = pcall(love.data.decode, "string", "base64", icon)
		if ok and data then
			return love.graphics.newImage(love.data.newByteData(data))
		end
	end
	return nil
end

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
	self.radius = opts.radius or 4
	self._hover = false
	self._pressed = false
	self._col = Anim.AnimColor.new(self.color[1], self.color[2], self.color[3])
	self._icon = resolve_icon(opts.icon)
	self.icon_size = opts.icon_size or 16
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
	love.graphics.rectangle(
		"fill",
		self.rect.x,
		self.rect.y,
		self.rect.width,
		self.rect.height,
		self.radius,
		self.radius
	)

	-- Draw the icon (if any) and the label centered together as a group.
	love.graphics.setFont(self._font)
	local font = self._font
	local tw = font:getWidth(self.text)
	local icon_w, gap = 0, 0
	if self._icon then
		icon_w = self.icon_size
		gap = math.floor(self.icon_size * 0.375)
	end
	local total = icon_w + gap + tw
	local cx = self.rect.x + (self.rect.width - total) / 2
	local cy = self.rect.y + self.rect.height / 2
	if self._icon then
		local iy = cy - self.icon_size / 2
		-- Scale the (64x64) source image down to icon_size, matching the
		-- scale-factor draw pattern used elsewhere (see gui_screen.lua).
		local scale = self.icon_size / self._icon:getWidth()
		love.graphics.setColor(0, 0, 0)
		love.graphics.draw(self._icon, cx, iy, 0, scale, scale)
		cx = cx + icon_w + gap
	end
	local ty = cy - font:getHeight() / 2
	love.graphics.setColor(0, 0, 0)
	love.graphics.print(self.text, cx, ty)
end

return Button
