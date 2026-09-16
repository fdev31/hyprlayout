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

function M.make_commands(gui_screens, canvas_scale)
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

	local cmds = {}
	for i, gs in ipairs(gui_screens) do
		local screen = gs.screen
		local r = rects[i]
		if screen.active then
			local mode_str
			if screen.mode then
				mode_str = string.format("%dx%d@%.2f", screen.mode.width, screen.mode.height, screen.mode.freq)
			else
				mode_str = "preferred"
			end
			local pos = string.format("%dx%d", math.floor(r.x), math.floor(r.y))
			local cmd = string.format(
				"hl.monitor({output='%s', mode='%s', position='%s', scale=%.6f, transform=%d",
				screen.uid,
				mode_str,
				pos,
				screen.scale,
				screen.transform
			)
			if screen.hdr_enabled then
				cmd = cmd
					.. string.format(
						", bitdepth=10, cm='%s', sdrbrightness=%.2f, sdrsaturation=%.2f, sdr_eotf='%s'",
						screen.cm or "auto",
						screen.sdrbrightness or 1.0,
						screen.sdrsaturation or 1.0,
						screen.sdr_eotf or "default"
					)
			else
				cmd = cmd .. string.format(", bitdepth=8")
			end
			cmd = cmd .. "})"
			table.insert(cmds, cmd)
		else
			local cmd = string.format("hl.monitor({output='%s', disabled=true})", screen.uid)
			table.insert(cmds, cmd)
		end
	end

	local joined = table.concat(cmds, " ; ")
	return { 'hyprctl eval "' .. joined .. '"' }
end

function M.run_commands(cmds)
	for _, cmd in ipairs(cmds) do
		print("Running: " .. cmd)
		local f = io.popen(cmd .. " 2>&1")
		local out = f:read("*a") or ""
		f:close()
		if out ~= "" then
			print(out)
		end
	end
end

return M
