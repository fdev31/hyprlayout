local M = {}

local function has(cmd)
	return os.execute(string.format("which %s > /dev/null 2>&1", cmd))
end

-- Detect the capture tool and an available image converter.
-- Returns { grim = bool, converter = "convert" | "magick" | "ffmpeg" | nil }.
function M.detect()
	local converter
	if has("convert") then
		converter = "convert"
	elseif has("magick") then
		converter = "magick"
	elseif has("ffmpeg") then
		converter = "ffmpeg"
	end
	return { grim = has("grim"), converter = converter }
end

-- Convert a PNG to raw RGBA (resized to w x h) at dst. Returns true on success.
local function to_rgba(src, dst, w, h, converter, timeout)
	if converter == "convert" then
		return os.execute(
			string.format(
				'timeout %s convert "%s" -resize "%dx%d!" -depth 8 rgba:- > "%s" 2>/dev/null',
				timeout,
				src,
				w,
				h,
				dst
			)
		)
	elseif converter == "magick" then
		return os.execute(
			string.format(
				'timeout %s magick "%s" -resize "%dx%d!" -depth 8 rgba:- > "%s" 2>/dev/null',
				timeout,
				src,
				w,
				h,
				dst
			)
		)
	elseif converter == "ffmpeg" then
		local fmt = 'timeout %s ffmpeg -y -i "%s" -vf "scale=%d:%d" -f rawvideo -pix_fmt rgba "%s" 2>/dev/null'
		return os.execute(string.format(fmt, timeout, src, w, h, dst))
	end
	return false
end

-- Capture monitor `uid` to a raw RGBA file in `dir`. Returns the rgba filename
-- (relative to `dir`) or nil on failure. `timeout` (seconds) bounds the grim call.
function M.capture(uid, dir, tw, th, converter, timeout)
	local safe_uid = (uid:gsub("/", "_"):gsub(" ", "_"))
	local png = dir .. "/.tmp_" .. safe_uid .. ".png"
	local rgba = "shot_" .. safe_uid .. ".rgba"
	timeout = tonumber(timeout)
	if not timeout or timeout <= 0 then
		timeout = 5
	end
	if not os.execute(string.format('timeout %s grim -o "%s" "%s" 2>/dev/null', timeout, uid, png)) then
		return nil
	end
	local ok = to_rgba(png, dir .. "/" .. rgba, tw, th, converter, timeout)
	os.remove(png)
	if not ok then
		return nil
	end
	return rgba
end

return M
