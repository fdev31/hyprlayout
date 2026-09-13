local screens, shot_dir = ...
local channel = love.thread.getChannel("screenshots")

os.execute('mkdir -p "' .. shot_dir .. '"')

local grim = os.execute("which grim > /dev/null 2>&1")
if grim then
  for _, s in ipairs(screens) do
    if s.active then
      local safe_uid = (s.uid:gsub("/", "_"):gsub(" ", "_"))
      local fname = "shot_" .. safe_uid .. ".png"
      local path = shot_dir .. "/" .. fname
      os.execute(string.format('grim -o "%s" "%s" 2>/dev/null', s.uid, path))
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
