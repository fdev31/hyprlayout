local screens, shot_dir = ...
local channel = love.thread.getChannel("screenshots")

os.execute('mkdir -p "' .. shot_dir .. '"')

local has_grim = os.execute("which grim > /dev/null 2>&1")

-- Downscale each capture to the size the preview is displayed at and dump raw
-- RGBA (4 bytes/pixel) to a file. The main thread can't newImage() an absolute
-- path in this LÖVE build, so it decodes these raw bytes via ffi instead.
local to_rgba
if os.execute("which convert > /dev/null 2>&1") then
	to_rgba = function(src, dst, w, h)
		return os.execute(
			string.format('convert "%s" -resize "%dx%d" -depth 8 rgba:- > "%s" 2>/dev/null', src, w, h, dst)
		)
	end
elseif os.execute("which magick > /dev/null 2>&1") then
	to_rgba = function(src, dst, w, h)
		return os.execute(
			string.format('magick "%s" -resize "%dx%d" -depth 8 rgba:- > "%s" 2>/dev/null', src, w, h, dst)
		)
	end
elseif os.execute("which ffmpeg > /dev/null 2>&1") then
	to_rgba = function(src, dst, w, h)
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
end

local HDR_FORMATS = { XR30 = true, XB30 = true }

if has_grim and to_rgba then
	for _, s in ipairs(screens) do
		local valid = s.active and s.tw and s.tw > 0 and s.th > 0
		if valid and HDR_FORMATS[s.currentFormat] then
			print("[shot-thread] skipping HDR monitor " .. s.uid .. " (grim hangs on 10-bit)")
		elseif valid then
			local safe_uid = (s.uid:gsub("/", "_"):gsub(" ", "_"))
			local png = shot_dir .. "/.tmp_" .. safe_uid .. ".png"
			local rgba = "shot_" .. safe_uid .. ".rgba"
			if os.execute(string.format('grim -o "%s" "%s" 2>/dev/null', s.uid, png)) then
				if to_rgba(png, shot_dir .. "/" .. rgba, s.tw, s.th) then
					channel:push({ type = "screenshot", uid = s.uid, file = rgba, w = s.tw, h = s.th })
				end
				os.remove(png)
			else
				print("[shot-thread] grim failed for " .. s.uid)
			end
		end
	end
end
channel:push({ type = "done" })
