local module = {}

local function should_use_color()
  if os.getenv("FORCE_COLOR") then return true end
  if os.getenv("NO_COLOR") then return false end
  local term = os.getenv("TERM")
  if not term or term == "dumb" then return false end
  return true
end

local use_color = should_use_color()

local codes = {
  reset = 0,
  bold = 1,
  red = 31,
  green = 32,
  yellow = 33,
  blue = 34,
  bright_black = 90,
}

local function seq(code)
  if not use_color then return "" end
  return string.char(27) .. "[" .. code .. "m"
end

local function emit(stream, ...)
  local args = { ... }
  for i = 1, #args do
    args[i] = tostring(args[i])
  end
  stream:write(table.concat(args))
  stream:flush()
end

function module.write(...)
  emit(io.stdout, ...)
end

function module.err(...)
  emit(io.stderr, ...)
end

function module.color(name)
  local code = codes[name]
  if not code then return "" end
  return seq(code)
end

function module.reset()
  return seq(codes.reset)
end

return module
