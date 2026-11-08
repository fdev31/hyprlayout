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

-- Native Wayland capture (in-process, zero-copy).
-- Tries the in-process Wayland capture backend first; falls back to grim PPM.
--
-- Returns:
--   { width=..., height=..., stride=..., size=..., data=<cdata ptr>, format="bgra" }
--   { data=<ppm string>, format="ppm" }
--   nil  (total failure)
function M.capture_native(uid, scale, timeout)
	-- Lazy require: only load the native backend if we actually try it
	local ok, wayland_capture = pcall(require, "core.wayland_capture")
	if not ok then
		debug.log("capture_native %s: native backend unavailable (%s), falling back to ppm", uid, wayland_capture)
		local ppm = M.capture_ppm(uid, scale, timeout)
		if ppm then
			return { data = ppm, format = "ppm" }
		end
		return nil
	end

	-- Check if the native backend is available on this system
	local available = wayland_capture.detect()
	if not available then
		debug.log("capture_native %s: native backend detected as unavailable, falling back to ppm", uid)
		local ppm = M.capture_ppm(uid, scale, timeout)
		if ppm then
			return { data = ppm, format = "ppm" }
		end
		return nil
	end

	-- Initialize the backend (idempotent – safe to call repeatedly)
	local init_ok = wayland_capture.init()
	if not init_ok then
		debug.log("capture_native %s: native init failed, falling back to ppm", uid)
		local ppm = M.capture_ppm(uid, scale, timeout)
		if ppm then
			return { data = ppm, format = "ppm" }
		end
		return nil
	end

	-- Attempt the native capture
	local result = wayland_capture.capture(uid)
	if not result then
		debug.log("capture_native %s: native capture failed, falling back to ppm", uid)
		local ppm = M.capture_ppm(uid, scale, timeout)
		if ppm then
			return { data = ppm, format = "ppm" }
		end
		return nil
	end

	debug.log(
		"capture_native %s: ok (%dx%d, %d bytes, stride=%d)",
		uid,
		result.width,
		result.height,
		result.size,
		result.stride
	)

	return {
		width = result.width,
		height = result.height,
		stride = result.stride,
		size = result.size,
		data = result.data,
		format = "bgra",
	}
end

return M
