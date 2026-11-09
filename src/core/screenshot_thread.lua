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

	-- The native child (spawned inside capture_native) must be cleaned up
	-- here: this is a one-shot thread, so without shutdown the child and its
	-- FIFOs would leak on every interval.  Runs even when the capture fell
	-- back to grim or failed, since init() may still have spawned the child.
	local ok2, wc = pcall(require, "core.wayland_capture")
	if ok2 and wc and wc.shutdown then
		wc.shutdown()
	end

	if data then
		debug.log("thread: capture ok for %s (%s)", s.uid, data.format)
		if data.format == "bgra" then
			-- Write the raw BGRA to a BMP file on disk.  Pushing ~19 MB
			-- through the LÖVE channel pipe stalls the main thread; a
			-- file path is tiny and the main thread reads it from disk.
			local w, h = data.width, data.height
			local pixel_size = w * h * 4
			local file_size = 54 + pixel_size
			local function u32le(n)
				return string.char(n & 0xFF, (n >> 8) & 0xFF, (n >> 16) & 0xFF, (n >> 24) & 0xFF)
			end
			local function u16le(n)
				return string.char(n & 0xFF, (n >> 8) & 0xFF)
			end
			local header = "BM"
				.. u32le(file_size)
				.. u32le(0)
				.. u32le(54)
				.. u32le(40)
				.. u32le(w)
				.. u32le(h)
				.. u16le(1)
				.. u16le(32)
				.. u32le(0)
				.. u32le(pixel_size)
				.. u32le(0)
				.. u32le(0)
				.. u32le(0)
				.. u32le(0)
			local bmp_path = shot_dir .. "/" .. s.uid .. ".bmp"
			local f = io.open(bmp_path, "wb")
			if f then
				f:write(header)
				f:write(data.data)
				f:close()
				channel:push({ type = "screenshot", uid = s.uid, data = { format = "bmp", path = bmp_path } })
			else
				print("[shot-thread] can't write BMP for " .. s.uid)
			end
		else
			channel:push({ type = "screenshot", uid = s.uid, data = data })
		end
	else
		print("[shot-thread] capture failed for " .. s.uid)
	end
end
channel:push({ type = "done" })
