local s, shot_dir, converter = ...
local channel = love.thread.getChannel("screenshots")

local HDR_FORMATS = { XR30 = true, XB30 = true }

-- The main thread detected which image tool is available and passes its name
-- (only serializable data crosses the LÖVE thread boundary).
local function to_rgba(src, dst, w, h)
	if converter == "convert" then
		return os.execute(
			string.format('convert "%s" -resize "%dx%d" -depth 8 rgba:- > "%s" 2>/dev/null', src, w, h, dst)
		)
	elseif converter == "magick" then
		return os.execute(
			string.format('magick "%s" -resize "%dx%d" -depth 8 rgba:- > "%s" 2>/dev/null', src, w, h, dst)
		)
	elseif converter == "ffmpeg" then
		return os.execute(
			string.format(
				'ffmpeg -y -i "%s" -vf "scale=%d:%d" -f rawvideo -pix_fmt rgba "%s" 2>/dev/null',
				src,
				w,
				h,
				dst
			)
		)
	end
	return false
end

local valid = s.active and s.tw and s.tw > 0 and s.th > 0
if valid and HDR_FORMATS[s.currentFormat] then
	print("[shot-thread] skipping HDR monitor " .. s.uid .. " (grim hangs on 10-bit)")
elseif valid then
	local safe_uid = (s.uid:gsub("/", "_"):gsub(" ", "_"))
	local png = shot_dir .. "/.tmp_" .. safe_uid .. ".png"
	local rgba = "shot_" .. safe_uid .. ".rgba"
	if os.execute(string.format('timeout 5 grim -o "%s" "%s" 2>/dev/null', s.uid, png)) then
		if to_rgba(png, shot_dir .. "/" .. rgba, s.tw, s.th) then
			channel:push({ type = "screenshot", uid = s.uid, file = rgba, w = s.tw, h = s.th })
		end
		os.remove(png)
	else
		print("[shot-thread] grim failed for " .. s.uid)
	end
end
channel:push({ type = "done" })
