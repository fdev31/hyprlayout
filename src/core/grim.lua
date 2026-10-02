local M = {}
local debug = require("core.debug")

-- This LÖVE build's os.execute returns the raw C wait status (0 on success,
-- exit_code*256 on failure) instead of LuaJIT's `true, "exit", code`.
-- Normalize to a success boolean, tolerating both conventions.
local function exec_ok(cmd)
	local r = os.execute(cmd)
	return r == true or r == 0
end

local function has(cmd)
	return exec_ok(string.format("which %s > /dev/null 2>&1", cmd))
end

-- Detect whether grim is available.
function M.detect()
	local ok = has("grim")
	debug.log("grim detect: %s", ok and "found" or "NOT FOUND")
	return ok
end

-- Capture monitor `uid` to a PNG in `dir`, scaled down by `scale` at capture
-- time via `grim -s`. Returns the png filename (relative to `dir`) or nil on
-- failure. `timeout` (seconds) bounds the grim call.
function M.capture(uid, dir, scale, timeout)
	local safe_uid = (uid:gsub("/", "_"):gsub(" ", "_"))
	local png = "shot_" .. safe_uid .. ".png"
	timeout = tonumber(timeout)
	if not timeout or timeout <= 0 then
		timeout = 5
	end
	-- Keep grim's stderr visible when debugging so failures explain themselves.
	local quiet = debug.enabled() and "" or " 2>/dev/null"
	local cmd = string.format('timeout %s grim -o "%s" -s %s "%s"%s', timeout, uid, scale, dir .. "/" .. png, quiet)
	debug.log("capture: %s", cmd)
	local ok = exec_ok(cmd)
	debug.log("capture %s: %s", uid, ok and "ok" or "FAILED")
	if not ok then
		return nil
	end
	return png
end

return M
