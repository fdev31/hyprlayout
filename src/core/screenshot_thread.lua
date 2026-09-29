local s, shot_dir, converter, timeout = ...
local channel = love.thread.getChannel("screenshots")
local grim = require("core.grim")

local HDR_FORMATS = { XR30 = true, XB30 = true }

local valid = s.active and s.tw and s.tw > 0 and s.th > 0
if valid and HDR_FORMATS[s.currentFormat] then
	print("[shot-thread] skipping HDR monitor " .. s.uid .. " (grim hangs on 10-bit)")
elseif valid then
	local file = grim.capture(s.uid, shot_dir, s.tw, s.th, converter, timeout)
	if file then
		channel:push({ type = "screenshot", uid = s.uid, file = file, w = s.tw, h = s.th })
	else
		print("[shot-thread] capture failed for " .. s.uid)
	end
end
channel:push({ type = "done" })
