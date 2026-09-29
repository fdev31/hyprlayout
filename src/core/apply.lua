local M = {}

-- The canvas is y-down (LÖVE), same orientation as Hyprland's top-left
-- position, so we only normalize to a (0,0) origin — no y-flip.
local function trim_rects(rects)
	local min_x = math.huge
	local min_y = math.huge
	for _, r in ipairs(rects) do
		if r then
			min_x = math.min(min_x, r.x)
			min_y = math.min(min_y, r.y)
		end
	end
	for _, r in ipairs(rects) do
		if r then
			r.x = r.x - min_x
			r.y = r.y - min_y
		end
	end
end

-- Build one opaque MonitorConfig per gui screen (see core.hyprctl for the shape).
function M.make_configs(gui_screens, canvas_scale)
	local rects = {}
	for _, gs in ipairs(gui_screens) do
		local r = gs.target_rect
		table.insert(rects, {
			x = r.x * canvas_scale,
			y = r.y * canvas_scale,
			width = r.width * canvas_scale,
			height = r.height * canvas_scale,
		})
	end
	trim_rects(rects)

	local configs = {}
	for i, gs in ipairs(gui_screens) do
		local screen = gs.screen
		local r = rects[i]
		if screen.active then
			local width, height, refresh
			if screen.mode then
				width, height, refresh = screen.mode.width, screen.mode.height, screen.mode.freq
			else
				width, height, refresh = 1920, 1080, 60
			end
			table.insert(configs, {
				name = screen.uid,
				enabled = true,
				width = width,
				height = height,
				refresh = refresh,
				x = math.floor(r.x),
				y = math.floor(r.y),
				scale = screen.scale,
				transform = screen.transform,
				bitdepth = screen.hdr_enabled and 10 or 8,
				cm = screen.cm or "auto",
				sdr_eotf = screen.sdr_eotf or "default",
				sdrbrightness = screen.sdrbrightness or 1.0,
				sdrsaturation = screen.sdrsaturation or 1.0,
			})
		else
			table.insert(configs, { name = screen.uid, enabled = false })
		end
	end

	return configs
end

return M
