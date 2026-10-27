local module = {}

local fs = require("lnko.fs")
local log = require("lnko.log")

local CONFIG_NAME = ".lnkorc"

local known_keys = {
  dir = "source_dir",
  target = "target_dir",
  ignore = "ignore",
  no_folding = "no_folding",
  packages = "packages",
}

local function expand(path)
  if path:sub(1, 1) == "~" then
    local home = os.getenv("HOME") or ""
    return home .. path:sub(2)
  end
  return path
end

function module.find(source_dir)
  local env_path = os.getenv("LNKO_CONFIG")
  if env_path and env_path ~= "" then
    local expanded = expand(env_path)
    if not fs.exists(expanded) then
      log.error("config not found: " .. env_path)
      return nil, true
    end
    return expanded, true
  end

  local candidate = fs.join(source_dir, CONFIG_NAME)
  if fs.exists(candidate) then return candidate, false end

  return nil, false
end

function module.load(path)
  local chunk, err = loadfile(path)
  if not chunk then
    log.error("invalid config: " .. err)
    return nil
  end

  local ok, config = pcall(chunk)
  if not ok then
    log.error("config error: " .. tostring(config))
    return nil
  end

  if type(config) ~= "table" then
    log.error("config must return a table")
    return nil
  end

  return config
end

module.expand = expand

function module.apply(options, config, explicit)
  for key, value in pairs(config) do
    local option_key = known_keys[key]

    if not option_key then
      log.warn("unknown config key: " .. tostring(key))
    elseif type(value) ~= "table" and type(value) ~= "string" and type(value) ~= "boolean" then
      log.warn("invalid value for " .. key)
    elseif option_key == "ignore" or option_key == "packages" then
      if type(value) == "table" then options[option_key] = value end
    elseif not explicit[option_key] then
      if type(value) == "string" then value = expand(value) end
      options[option_key] = value
    end
  end
end

return module
