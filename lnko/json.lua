local module = {}

local escapes = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

local function escape(s)
  return (s:gsub('[%c"\\]', function(c)
    return escapes[c] or string.format("\\u%04x", string.byte(c))
  end))
end

function module.encode(value)
  local t = type(value)

  if t == "nil" then return "null" end
  if t == "boolean" then return tostring(value) end
  if t == "number" then return string.format("%.14g", value) end

  if t == "string" then return '"' .. escape(value) .. '"' end

  if t == "table" then
    local is_array = true
    local count = 0

    for k in pairs(value) do
      if type(k) ~= "number" or k % 1 ~= 0 or k < 1 then
        is_array = false
        break
      end
      count = count + 1
    end

    if is_array then
      local parts = {}
      for i = 1, count do
        parts[i] = module.encode(value[i])
      end
      return "[" .. table.concat(parts, ",") .. "]"
    end

    local keys = {}
    for k in pairs(value) do
      keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
    end)

    local parts = {}
    for _, k in ipairs(keys) do
      parts[#parts + 1] = '"' .. escape(tostring(k)) .. '":' .. module.encode(value[k])
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end

  return "null"
end

return module
