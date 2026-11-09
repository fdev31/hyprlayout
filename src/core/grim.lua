local M = {}
local debug = require("core.debug")

local grim_available = nil

local function exec_ok(cmd)
	local r = os.execute(cmd)
	return r == true or r == 0
end

local function has(cmd)
	return exec_ok(string.format("which %s > /dev/null 2>&1", cmd))
end

--- Check if grim is installed (cached; the `which` probe is only run once).
function M.detect()
	if grim_available == nil then
		grim_available = has("grim")
		debug.log("grim detect: %s", grim_available and "found" or "NOT FOUND")
	end
	return grim_available
end

--- Capture a monitor as a PNG file in dir. Returns the filename or nil.
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

--- Delegation: native Wayland → grim PNG → nil.
---
--- Returns:
---   { width=..., height=..., stride=..., size=..., data=<cdata ptr>, format="bgra" }
---   { path=<absolute path>, format="png" }
---   nil  (no backend available or all failed)
function M.capture_native(uid, dir, scale, timeout)
	-- 1. Native Wayland backend (in-process, zero-copy)
	local ok, wc = pcall(require, "core.wayland_capture")
	if ok and wc.detect() and wc.init() then
		local result = wc.capture(uid, scale)
		if result then
			debug.log("screenshot %s: backend=native (%dx%d)", uid, result.width, result.height)
			return {
				width = result.width,
				height = result.height,
				stride = result.stride,
				size = result.size,
				data = result.data,
				format = "bgra",
			}
		end
	end

	-- 2. Grim PNG (external command)
	if M.detect() then
		local png = M.capture(uid, dir, scale, timeout)
		if png then
			debug.log("screenshot %s: backend=grim-png", uid)
			return { path = dir .. "/" .. png, format = "png" }
		end
	end

	-- 3. Disabled (no backend available)
	return nil
end

return M
