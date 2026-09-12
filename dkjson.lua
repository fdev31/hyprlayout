local json = {}

local function skip_whitespace(str, idx)
  local s, e = str:find("^[ \t\r\n]*", idx)
  if s then
    return e + 1
  end
  return idx
end

local function decode_string(str, idx)
  if str:sub(idx, idx) ~= '"' then
    return nil, idx, "string expected at " .. idx
  end
  idx = idx + 1
  local buf = {}
  while true do
    local c = str:sub(idx, idx)
    if c == '"' then
      return table.concat(buf), idx + 1, nil
    elseif c == '\\' then
      idx = idx + 1
      local esc = str:sub(idx, idx)
      if esc == '"' then table.insert(buf, '"')
      elseif esc == '\\' then table.insert(buf, '\\')
      elseif esc == '/' then table.insert(buf, '/')
      elseif esc == 'b' then table.insert(buf, '\b')
      elseif esc == 'f' then table.insert(buf, '\f')
      elseif esc == 'n' then table.insert(buf, '\n')
      elseif esc == 'r' then table.insert(buf, '\r')
      elseif esc == 't' then table.insert(buf, '\t')
      elseif esc == 'u' then
        local hex = str:sub(idx + 1, idx + 4)
        if hex:match("^%x+%x+%x+%x$") then
          table.insert(buf, string.char(tonumber(hex, 16)))
          idx = idx + 4
        else
          return nil, idx, "invalid unicode escape"
        end
      else
        return nil, idx, "invalid escape \\" .. esc
      end
      idx = idx + 1
    elseif c == '' then
      return nil, idx, "unterminated string"
    else
      table.insert(buf, c)
      idx = idx + 1
    end
  end
end

local function decode_number(str, idx)
  local numstr = str:match("^-?%d+%.?%d*[eE]?[+-]?%d*", idx)
  if not numstr or #numstr == 0 then
    return nil, idx, "number expected at " .. idx
  end
  return tonumber(numstr), idx + #numstr, nil
end

local decode_value

local function decode_object(str, idx)
  idx = idx + 1
  local obj = {}
  idx = skip_whitespace(str, idx)
  if str:sub(idx, idx) == '}' then
    return obj, idx + 1, nil
  end
  while true do
    idx = skip_whitespace(str, idx)
    local key
    key, idx = decode_string(str, idx)
    if not key then return nil, idx, "key expected" end
    idx = skip_whitespace(str, idx)
    if str:sub(idx, idx) ~= ':' then
      return nil, idx, "colon expected at " .. idx
    end
    idx = idx + 1
    local val
    val, idx = decode_value(str, idx)
    obj[key] = val
    idx = skip_whitespace(str, idx)
    local c = str:sub(idx, idx)
    if c == ',' then
      idx = idx + 1
    elseif c == '}' then
      return obj, idx + 1, nil
    else
      return nil, idx, "comma or } expected at " .. idx
    end
  end
end

local function decode_array(str, idx)
  idx = idx + 1
  local arr = {}
  idx = skip_whitespace(str, idx)
  if str:sub(idx, idx) == ']' then
    return arr, idx + 1, nil
  end
  while true do
    idx = skip_whitespace(str, idx)
    local val
    val, idx = decode_value(str, idx)
    table.insert(arr, val)
    idx = skip_whitespace(str, idx)
    local c = str:sub(idx, idx)
    if c == ',' then
      idx = idx + 1
    elseif c == ']' then
      return arr, idx + 1, nil
    else
      return nil, idx, "comma or ] expected at " .. idx
    end
  end
end

decode_value = function(str, idx)
  idx = skip_whitespace(str, idx)
  local c = str:sub(idx, idx)

  if c == '"' then
    return decode_string(str, idx)
  elseif c == '{' then
    return decode_object(str, idx)
  elseif c == '[' then
    return decode_array(str, idx)
  elseif c == 't' then
    if str:sub(idx, idx + 3) == "true" then
      return true, idx + 4, nil
    end
  elseif c == 'f' then
    if str:sub(idx, idx + 4) == "false" then
      return false, idx + 5, nil
    end
  elseif c == 'n' then
    if str:sub(idx, idx + 3) == "null" then
      return nil, idx + 4, nil
    end
  elseif c == '-' or (c ~= '' and c:match("^%d")) then
    return decode_number(str, idx)
  end

  return nil, idx, "unexpected character '" .. tostring(c) .. "' at " .. idx
end

function json.decode(str)
  if type(str) ~= "string" then
    return nil, "expected string, got " .. type(str)
  end
  local val, idx, err = decode_value(str, 1)
  if err then
    return nil, err
  end
  return val
end

return json
