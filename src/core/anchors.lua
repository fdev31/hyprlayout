local M = {}

local TOL = 2

local function ref_point_offset(ref_types, width, height)
	local x_map = { left = 0, right = width, center_x = width / 2 }
	local y_map = { top = 0, bottom = height, center_y = height / 2 }
	return x_map[ref_types[1]] or 0, y_map[ref_types[2]] or 0
end

local function ref_point_pos(rect, ref_types)
	local dx, dy = ref_point_offset(ref_types, rect.width, rect.height)
	return rect.x + dx, rect.y + dy
end

function M.detect(gui_screens)
	local anchors = {}
	for _, s in ipairs(gui_screens) do
		anchors[s] = {}
	end

	for i = 1, #gui_screens do
		for j = i + 1, #gui_screens do
			local A, B = gui_screens[i], gui_screens[j]
			local a_refs = A.target_rect:ref_points()
			local b_refs = B.target_rect:ref_points()
			local matches = {}
			for _, a in ipairs(a_refs) do
				for _, b in ipairs(b_refs) do
					if math.abs(a.pos[1] - b.pos[1]) <= TOL and math.abs(a.pos[2] - b.pos[2]) <= TOL then
						table.insert(matches, { a_types = a.types, b_types = b.types })
					end
				end
			end
			if #matches > 0 then
				anchors[A][B] = matches
				local reverse = {}
				for _, m in ipairs(matches) do
					table.insert(reverse, { a_types = m.b_types, b_types = m.a_types })
				end
				anchors[B][A] = reverse
			end
		end
	end
	return anchors
end

local function find_connected(anchors, start)
	local visited = { [start] = true }
	local queue = { start }
	while #queue > 0 do
		local s = table.remove(queue, 1)
		local neighbors = anchors[s] or {}
		for neighbor in pairs(neighbors) do
			if not visited[neighbor] then
				visited[neighbor] = true
				table.insert(queue, neighbor)
			end
		end
	end
	return visited
end

function M.propagate(gui_screens, anchors, changed, old_w, old_h)
	local affected = find_connected(anchors, changed)

	local function area(s)
		if s == changed and old_w and old_h then
			return old_w * old_h
		end
		return s.target_rect.width * s.target_rect.height
	end

	local root = nil
	local root_area = -1
	for s in pairs(affected) do
		local a = area(s)
		if a > root_area or (a == root_area and (not root or s.target_rect.y < root.target_rect.y)) then
			root_area = a
			root = s
		end
	end
	if not root then
		return
	end

	local ordered = {}
	for s in pairs(affected) do
		if s ~= root then
			table.insert(ordered, s)
		end
	end
	table.sort(ordered, function(a, b)
		if a.target_rect.y ~= b.target_rect.y then
			return a.target_rect.y < b.target_rect.y
		end
		return a.target_rect.x < b.target_rect.x
	end)

	local positioned = { [root] = true }
	for _, s in ipairs(ordered) do
		local x_val = nil
		local y_val = nil
		local neighbors = anchors[s] or {}
		for neighbor, matches in pairs(neighbors) do
			if positioned[neighbor] then
				for _, m in ipairs(matches) do
					local n_pos_x, n_pos_y = ref_point_pos(neighbor.target_rect, m.b_types)
					local s_dx, s_dy = ref_point_offset(m.a_types, s.target_rect.width, s.target_rect.height)
					if x_val == nil then
						x_val = n_pos_x - s_dx
					end
					if y_val == nil then
						y_val = n_pos_y - s_dy
					end
				end
			end
		end
		if x_val ~= nil then
			s.target_rect.x = math.floor(x_val)
		end
		if y_val ~= nil then
			s.target_rect.y = math.floor(y_val)
		end
		positioned[s] = true
	end
end

return M
