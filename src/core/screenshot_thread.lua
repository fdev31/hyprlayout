local s, shot_dir, scale, timeout = ...
-- Make the C source path available to wayland_capture.lua (loaded via
-- require below).  love.filesystem and debug are nil in worker threads.
_G.HYPR_C_SOURCE_PATH = s.c_source_path
local channel = love.thread.getChannel("screenshots")
local grim = require("core.grim")
local debug = require("core.debug")

local HDR_FORMATS = { XR30 = true, XB30 = true }

debug.log(
	"thread start: uid=%s active=%s tw=%s th=%s scale=%s fmt=%s dir=%s",
	s.uid,
	tostring(s.active),
	tostring(s.tw),
	tostring(s.th),
	tostring(scale),
	tostring(s.currentFormat),
	tostring(shot_dir)
)

local valid = s.active and s.tw and s.tw > 0 and s.th > 0
if not valid then
	debug.log(
		"thread: invalid screen state (active=%s tw=%s th=%s), skipping capture",
		tostring(s.active),
		tostring(s.tw),
		tostring(s.th)
	)
elseif HDR_FORMATS[s.currentFormat] then
	print("[shot-thread] skipping HDR monitor " .. s.uid .. " (grim hangs on 10-bit)")
else
	local ok, data = pcall(grim.capture_native, s.uid, shot_dir, scale, timeout)
	if not ok then
		print("[shot-thread] capture error for " .. s.uid .. ": " .. tostring(data))
		data = nil
	end
	if data then
		debug.log("thread: capture ok for %s (%s)", s.uid, data.format)
		channel:push({ type = "screenshot", uid = s.uid, data = data })
	else
		print("[shot-thread] capture failed for " .. s.uid)
	end
end
channel:push({ type = "done" })
