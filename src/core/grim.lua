local M = {}
local debug = require("core.debug")

local function exec_ok(cmd)
	local r = os.execute(cmd)
	return r == true or r == 0
end

local function has(cmd)
	return exec_ok(string.format("which %s > /dev/null 2>&1", cmd))
end

function M.detect()
	local ok = has("grim")
	debug.log("grim detect: %s", ok and "found" or "NOT FOUND")
	return ok
end

function M.capture(uid, dir, scale, timeout)
	local safe_uid = (uid:gsub("/", "_"):gsub(" ", "_"))
	local png = "shot_" .. safe_uid .. ".png"
	timeout = tonumber(timeout)
	if not timeout or timeout <= 0 then
		timeout = 5
	end
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

-- Capture a monitor's output as raw PPM data via stdout.
-- Returns the full PPM payload ("P6\n<w> <h>\n<maxval>\n<raw RGB bytes>")
-- or nil on any failure (popen failed, empty read, or missing P6 header).
function M.capture_ppm(uid, scale, timeout)
	timeout = tonumber(timeout)
	if not timeout or timeout <= 0 then
		timeout = 5
	end
	local quiet = debug.enabled() and "" or " 2>/dev/null"
	local cmd = string.format('timeout %s grim -o "%s" -s %s -t ppm -%s', timeout, uid, scale, quiet)
	debug.log("capture_ppm: %s", cmd)
	local f = io.popen(cmd)
	if not f then
		debug.log("capture_ppm %s: FAILED (popen)", uid)
		return nil
	end
	local data = f:read("*a")
	f:close()
	if not data or data == "" then
		debug.log("capture_ppm %s: FAILED (empty)", uid)
		return nil
	end
	if data:sub(1, 2) ~= "P6" then
		debug.log("capture_ppm %s: FAILED (no P6 header)", uid)
		return nil
	end
	debug.log("capture_ppm %s: ok (%d bytes)", uid, #data)
	return data
end

return M
