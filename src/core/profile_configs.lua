local Rect = require("core.rect")
local apply = require("core.apply")
local profile_apply = require("core.profile_apply")

local M = {}

-- Compute the initial (canvas-unit) target rect for a screen, given the canvas
-- scale. Returns a plain {x, y, width, height} table. Mirrors the math the GUI
-- uses to lay out a screen (see main.build_gui_screens) but without any LÖVE /
-- widget dependency, so it can be shared with the headless / Hyprland paths.
function M.initial_target_rect(screen, canvas_scale)
	local x, y = screen.position[1], screen.position[2]
	local w, h
	if screen.mode then
		w, h = Rect.screen_size(screen.mode.width, screen.mode.height, screen.scale, canvas_scale, screen.transform)
	else
		local max_w, max_h = 1920, 1080
		for _, m in ipairs(screen.available) do
			max_w = math.max(max_w, m.width)
			max_h = math.max(max_h, m.height)
		end
		w, h = Rect.screen_size(max_w, max_h, screen.scale, canvas_scale, screen.transform)
	end
	return {
		x = math.floor(x / canvas_scale),
		y = math.floor(y / canvas_scale),
		width = w,
		height = h,
	}
end

-- Convert a loaded profile (data) into a list of opaque MonitorConfigs, using
-- the current screens as the base. This is the shared logic behind both the
-- LÖVE headless apply and the Hyprland apply. Returns the configs list.
function M.make(data, screens, canvas_scale)
	local gs_list = {}
	for _, screen in ipairs(screens) do
		local rect = M.initial_target_rect(screen, canvas_scale)
		table.insert(gs_list, { screen = screen, target_rect = rect })
	end

	-- Apply the profile entries, matching by monitor name first, then by uid.
	for _, entry in ipairs(data.screens or {}) do
		local matched = false
		if entry.monitor_name then
			for _, gs in ipairs(gs_list) do
				if gs.screen.name == entry.monitor_name then
					profile_apply.apply_screen_entry(gs, entry, canvas_scale, { match_modes = true })
					matched = true
					break
				end
			end
		end
		if not matched then
			for _, gs in ipairs(gs_list) do
				if gs.screen.uid == entry.uid then
					profile_apply.apply_screen_entry(gs, entry, canvas_scale, { match_modes = true })
					break
				end
			end
		end
	end

	return apply.make_configs(gs_list, canvas_scale)
end

return M
