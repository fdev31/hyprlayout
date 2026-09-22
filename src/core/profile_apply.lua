local Rect = require("core.rect")

local M = {}

function M.find_matching_mode(available, w, h, freq)
	for _, m in ipairs(available) do
		if m.width == w and m.height == h and math.abs(m.freq - freq) < 0.1 then
			return m
		end
	end
	local best = nil
	local best_diff = math.huge
	for _, m in ipairs(available) do
		if m.width == w and m.height == h then
			local diff = math.abs(m.freq - freq)
			if diff < best_diff then
				best_diff = diff
				best = m
			end
		end
	end
	return best
end

-- Apply a saved profile entry onto a live GuiScreen.
-- opts.match_modes: prefer a real available mode over a synthetic one.
-- opts.on_no_mode(uid): called when no available mode matches.
function M.apply_screen_entry(gs, entry, scale, opts)
	opts = opts or {}
	gs.screen.active = entry.active
	gs.screen.scale = entry.scale or 1
	gs.screen.transform = entry.transform or 0
	gs.screen.hdr_enabled = entry.hdr_enabled or false
	gs.screen.cm = entry.cm or "auto"
	gs.screen.sdrbrightness = entry.sdrbrightness or 1.0
	gs.screen.sdrsaturation = entry.sdrsaturation or 1.0
	gs.screen.sdr_eotf = entry.sdr_eotf or "default"
	if entry.mode then
		local mode = nil
		if opts.match_modes then
			mode = M.find_matching_mode(gs.screen.available, entry.mode.width, entry.mode.height, entry.mode.freq)
		end
		if mode then
			gs.screen.mode = mode
		else
			gs.screen.mode = {
				width = entry.mode.width,
				height = entry.mode.height,
				freq = entry.mode.freq,
			}
			if opts.on_no_mode then
				opts.on_no_mode(gs.screen.uid)
			end
		end
		local new_w, new_h =
			Rect.screen_size(gs.screen.mode.width, gs.screen.mode.height, gs.screen.scale, scale, gs.screen.transform)
		gs.target_rect.width = new_w
		gs.target_rect.height = new_h
	end
	if entry.position then
		gs.target_rect.x = entry.position.x / scale
		gs.target_rect.y = entry.position.y / scale
	end
end

return M
