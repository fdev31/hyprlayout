local M = {}

local PROFILES_DIR = os.getenv("HOME") .. "/.config/hyprlayout/profiles"

local function ensure_dir(path)
  os.execute(string.format('mkdir -p "%s"', path))
end

local function serialize_key(k)
  if type(k) == "number" then
    return "[" .. string.format("%d", k) .. "]"
  end
  if k:match("^[%a_][%w_]*$") then
    return k
  end
  return string.format("%q", k)
end

local function serialize_value(v, indent)
  local t = type(v)
  if t == "table" then
    local is_array = true
    local max_i = 0
    for k, _ in pairs(v) do
      if type(k) ~= "number" then
        is_array = false
        break
      end
      max_i = math.max(max_i, k)
    end
    if is_array then
      for i = 1, max_i do
        if v[i] == nil then
          is_array = false
          break
        end
      end
    end

    local pad = string.rep("  ", indent)
    local pad2 = string.rep("  ", indent + 1)

    if is_array then
      if #v == 0 then return "{}" end
      local parts = {}
      for i = 1, #v do
        table.insert(parts, pad2 .. serialize_value(v[i], indent + 1))
      end
      return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
    else
      local parts = {}
      for k, val in pairs(v) do
        table.insert(parts, pad2 .. serialize_key(k) .. " = " .. serialize_value(val, indent + 1))
      end
      if #parts == 0 then return "{}" end
      return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
    end
  elseif t == "string" then
    return string.format("%q", v)
  elseif t == "number" then
    if v == math.floor(v) then
      return string.format("%d", v)
    end
    return string.format("%g", v)
  elseif t == "boolean" then
    return tostring(v)
  end
  return "nil"
end

function M.list_profiles()
  ensure_dir(PROFILES_DIR)
  local profiles = {}
  local f = io.popen(string.format('ls -1 "%s"/*.lua 2>/dev/null', PROFILES_DIR))
  for line in f:lines() do
    local name = line:match("([^/]+)%.lua$")
    if name then
      table.insert(profiles, name)
    end
  end
  f:close()
  table.sort(profiles)
  return profiles
end

function M.save_profile(name, data)
  ensure_dir(PROFILES_DIR)
  local path = string.format("%s/%s.lua", PROFILES_DIR, name)
  local f = io.open(path, "w")
  if not f then return false, "Cannot write to " .. path end
  f:write("-- Profile: " .. name .. "\n")
  f:write("return " .. serialize_value(data, 0) .. "\n")
  f:close()
  return true
end

function M.load_profile(name)
  local path = string.format("%s/%s.lua", PROFILES_DIR, name)
  local chunk, err = loadfile(path)
  if not chunk then
    return nil, err
  end
  local ok, result = pcall(chunk)
  if not ok then
    return nil, result
  end
  return result
end

function M.delete_profile(name)
  local path = string.format("%s/%s.lua", PROFILES_DIR, name)
  return os.remove(path)
end

return M
