local screens, shot_dir = ...
local channel = love.thread.getChannel("screenshots")

os.execute('mkdir -p "' .. shot_dir .. '"')

local grim = os.execute("which grim > /dev/null 2>&1")

-- Downscale each capture to the size the preview is displayed at, so the main
-- thread decodes a small image (fast) instead of the full-resolution screenshot.
-- Pick a scaler that exists; if none is available, keep the full-res image.
local scaler
if os.execute("which convert > /dev/null 2>&1") then
  scaler = function(src, dst, w, h)
    return os.execute(string.format('convert "%s" -resize "%dx%d" "%s" 2>/dev/null', src, w, h, dst))
  end
elseif os.execute("which magick > /dev/null 2>&1") then
  scaler = function(src, dst, w, h)
    return os.execute(string.format('magick "%s" -resize "%dx%d" "%s" 2>/dev/null', src, w, h, dst))
  end
elseif os.execute("which ffmpeg > /dev/null 2>&1") then
  scaler = function(src, dst, w, h)
    return os.execute(string.format('ffmpeg -y -i "%s" -vf "scale=%d:%d" "%s" 2>/dev/null', src, w, h, dst))
  end
end

if grim then
  for _, s in ipairs(screens) do
    if s.active then
      local safe_uid = (s.uid:gsub("/", "_"):gsub(" ", "_"))
      local fname = "shot_" .. safe_uid .. ".png"
      local path = shot_dir .. "/" .. fname
      os.execute(string.format('grim -o "%s" "%s" 2>/dev/null', s.uid, path))
      if scaler and s.tw and s.tw > 0 and s.th > 0 then
        local tmp = path .. ".tmp.png"
        if scaler(path, tmp, s.tw, s.th) then
          os.rename(tmp, path)
        else
          os.remove(tmp)
        end
      end
      local f = io.open(path, "r")
      if f then
        f:close()
        channel:push({ type = "screenshot", uid = s.uid, file = fname })
      else
        print("[shot-thread] grim failed for " .. s.uid)
      end
    end
  end
end
channel:push({ type = "done" })
