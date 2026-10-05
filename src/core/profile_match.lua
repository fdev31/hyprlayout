local profiles = require("core.profiles")

local M = {}

-- True when two sets (tables of key->true) contain the same keys.
local function sets_equal(a, b)
	if #a ~= #b then
		return false
	end
	for k in pairs(a) do
		if not b[k] then
			return false
		end
	end
	return true
end

-- Find a saved profile whose screen set matches the current set of screens.
-- Two passes:
--   pass 1: the set of monitor_name (description) values in the profile equals
--           the set of current screen names (descriptions).
--   pass 2: the set of uid (output name) values in the profile equals the set
--           of current screen uids (output names).
-- Returns (name, data) for the first match, or (nil, nil) when none matches.
-- `current` is the list of Screen objects from core.screens.
function M.find_matching_profile(current)
	local current_by_name = {}
	local current_by_uid = {}
	for _, s in ipairs(current) do
		current_by_name[s.name] = true
		current_by_uid[s.uid] = true
	end

	local names = profiles.list_profiles()

	-- pass 1: by monitor name / description
	for _, name in ipairs(names) do
		local data = profiles.load_profile(name)
		if data then
			local prof = {}
			local has_names = true
			for _, s in ipairs(data.screens or {}) do
				if s.monitor_name then
					prof[s.monitor_name] = true
				else
					has_names = false
					break
				end
			end
			if has_names and sets_equal(current_by_name, prof) then
				return name, data
			end
		end
	end

	-- pass 2: by uid / output name
	for _, name in ipairs(names) do
		local data = profiles.load_profile(name)
		if data then
			local prof = {}
			for _, s in ipairs(data.screens or {}) do
				prof[s.uid] = true
			end
			if sets_equal(current_by_uid, prof) then
				return name, data
			end
		end
	end

	return nil, nil
end

return M
