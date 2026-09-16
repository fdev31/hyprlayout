local Rect = require("core.rect")

local SNAP_WEIGHT_BOTH = 0.25
local SNAP_WEIGHT_SINGLE = 0.5
local SNAP_PENALTY_CORNER = 1.5
local SNAP_RADIUS = 300

local M = {}

local function snap_weight(ac_types, oc_types)
	local opposite = {
		["left|right"] = true,
		["right|left"] = true,
		["top|bottom"] = true,
		["bottom|top"] = true,
	}

	local function axes_match(a, b)
		return a == b or opposite[a .. "|" .. b]
	end

	local matches = 0
	if axes_match(ac_types[1], oc_types[1]) then
		matches = matches + 1
	end
	if axes_match(ac_types[2], oc_types[2]) then
		matches = matches + 1
	end

	if matches == 2 then
		return SNAP_WEIGHT_BOTH
	elseif matches == 1 then
		return SNAP_WEIGHT_SINGLE
	end

	local ac0, ac1 = ac_types[1], ac_types[2]
	local oc0, oc1 = oc_types[1], oc_types[2]
	if ac0 ~= "center_x" and ac1 ~= "center_y" and oc0 ~= "center_x" and oc1 ~= "center_y" then
		return SNAP_PENALTY_CORNER
	end
	return 1.0
end

-- Check if moving rect (rx, ry, rw, rh) by (-dx, -dy) would overlap any screen in gui_screens
-- except the one at index active_idx
local function test_no_overlap(rx, ry, rw, rh, dx, dy, gui_screens, active_idx)
	local test = Rect.new(rx - dx, ry - dy, rw, rh)
	for i = 1, #gui_screens do
		if i ~= active_idx then
			if test:collide(gui_screens[i].target_rect) then
				return false
			end
		end
	end
	return true
end

local function find_active_index(gui_screens, active)
	for i = 1, #gui_screens do
		if gui_screens[i] == active then
			return i
		end
	end
	return #gui_screens
end

function M.snap_to_best_non_overlapping(active, candidates, gui_screens, max_dist)
	local ar = active.target_rect
	local active_idx = find_active_index(gui_screens, active)
	local active_coords = ar:ref_points()
	local pairs_list = {}

	for _, other in ipairs(candidates) do
		local otr = other.target_rect
		local other_coords = otr:ref_points()

		for _, ac in ipairs(active_coords) do
			for _, oc in ipairs(other_coords) do
				local dx = ac.pos[1] - oc.pos[1]
				local dy = ac.pos[2] - oc.pos[2]
				local raw_dist = math.sqrt(dx * dx + dy * dy)
				if not (max_dist and raw_dist > max_dist) then
					local weight = snap_weight(ac.types, oc.types)
					table.insert(pairs_list, { weighted = raw_dist * weight, dx = dx, dy = dy })
				end
			end
		end
	end

	table.sort(pairs_list, function(a, b)
		return a.weighted < b.weighted
	end)

	for _, p in ipairs(pairs_list) do
		if test_no_overlap(ar.x, ar.y, ar.width, ar.height, p.dx, p.dy, gui_screens, active_idx) then
			ar.x = ar.x - p.dx
			ar.y = ar.y - p.dy
			return true
		end
	end

	-- Last resort: push away along the axis that preserves center alignment
	for _, other in ipairs(candidates) do
		local otr = other.target_rect
		if ar:collide(otr) then
			local acx = ar.x + ar.width / 2
			local acy = ar.y + ar.height / 2
			local ocx = otr.x + otr.width / 2
			local ocy = otr.y + otr.height / 2
			local center_dx = acx - ocx
			local center_dy = acy - ocy

			local dx_push
			if center_dx >= 0 then
				dx_push = ar.x + ar.width - otr.x
			else
				dx_push = ar.x - (otr.x + otr.width)
			end
			if
				dx_push ~= 0 and test_no_overlap(ar.x, ar.y, ar.width, ar.height, dx_push, 0, gui_screens, active_idx)
			then
				ar.x = ar.x - dx_push
				return true
			end

			local dy_push
			if center_dy >= 0 then
				dy_push = ar.y + ar.height - otr.y
			else
				dy_push = ar.y - (otr.y + otr.height)
			end
			if
				dy_push ~= 0 and test_no_overlap(ar.x, ar.y, ar.width, ar.height, 0, dy_push, gui_screens, active_idx)
			then
				ar.y = ar.y - dy_push
				return true
			end
		end
	end

	return false
end

function M.snap_active_screen(gui_screens)
	local active = gui_screens[#gui_screens]
	if not active then
		return
	end
	local ar = active.target_rect

	local colliding = {}
	for i = 1, #gui_screens - 1 do
		local other = gui_screens[i]
		if ar:collide(other.target_rect) then
			table.insert(colliding, other)
		end
	end

	if #colliding > 0 then
		M.snap_to_best_non_overlapping(active, colliding, gui_screens, nil)
	end
end

function M.attract_screens(gui_screens)
	local active = gui_screens[#gui_screens]
	if not active then
		return
	end
	local ar = active.target_rect

	-- If screens already overlap, don't interfere
	for i = 1, #gui_screens - 1 do
		if ar:collide(gui_screens[i].target_rect) then
			return
		end
	end

	local candidates = {}
	for i = 1, #gui_screens - 1 do
		table.insert(candidates, gui_screens[i])
	end
	M.snap_to_best_non_overlapping(active, candidates, gui_screens, SNAP_RADIUS)
end

return M
