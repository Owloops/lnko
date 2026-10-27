local module = {}

local fs = require("lnko.fs")
local log = require("lnko.log")
local output = require("lnko.output")
local config_mod = require("lnko.config")
local version = require("lnko.version")

local cli_options = {
  {
    flags = { "-d", "--dir" },
    key = "source_dir",
    arg = "dir",
    desc = "Source directory containing packages (default: cwd)",
    all = true,
  },
  {
    flags = { "-t", "--target" },
    key = "target_dir",
    arg = "dir",
    desc = "Target directory (default: $HOME)",
    all = true,
  },
  {
    flags = { "-n", "--dry-run" },
    key = "dry_run",
    desc = "Show what would be done",
    commands = { link = true, unlink = true, clean = true },
    all = false,
  },
  {
    flags = { "-v", "--verbose" },
    key = "verbose",
    desc = "Show debug output",
    all = true,
  },
  {
    flags = { "-b", "--backup" },
    key = "backup",
    desc = "Auto-backup conflicts to <target>/.lnko-backup/",
    commands = { link = true },
    all = false,
  },
  {
    flags = { "-s", "--skip" },
    key = "skip",
    desc = "Auto-skip conflicts",
    commands = { link = true },
    all = false,
  },
  {
    flags = { "-f", "--force" },
    key = "force",
    desc = "Auto-overwrite conflicts (dangerous)",
    commands = { link = true },
    all = false,
  },
  {
    flags = { "--ignore" },
    key = "ignore",
    arg = "glob",
    list = true,
    desc = "Ignore files matching glob (can be repeated)",
    commands = { link = true },
    all = false,
  },
  {
    flags = { "--no-folding" },
    key = "no_folding",
    desc = "Don't fold directories into symlinks",
    commands = { link = true },
    all = false,
  },
  {
    flags = { "--json" },
    key = "json",
    desc = "Output as JSON",
    commands = { status = true },
    all = false,
  },
  {
    flags = { "--remove-orphans" },
    key = "remove_orphans",
    desc = "Auto-remove orphan symlinks",
    commands = { clean = true },
    all = false,
  },
  {
    flags = { "--keep-orphans" },
    key = "keep_orphans",
    desc = "Auto-keep orphan symlinks",
    commands = { clean = true },
    all = false,
  },
  {
    flags = { "--config" },
    key = "config",
    arg = "file",
    desc = "Config file path (default: .lnkorc in source dir, env: LNKO_CONFIG)",
    all = true,
  },
  {
    flags = { "-h", "--help" },
    key = "help",
    desc = "Show this help",
    all = true,
  },
  {
    flags = { "--version" },
    key = "version",
    desc = "Show version",
    all = true,
  },
}

local cli_commands = {
  { name = "link", args = "<packages...>", desc = "create symlinks for packages" },
  { name = "unlink", args = "<packages...>", desc = "remove symlinks for packages" },
  { name = "status", args = "", desc = "show status of all packages" },
  { name = "clean", args = "", desc = "remove orphan symlinks" },
}

local command_lookup = {}
for _, command in ipairs(cli_commands) do
  command_lookup[command.name] = command
end

-- ant by tre, https://asciiart.website/art/96

local banner = [[\(")/
-( )-
/(_)\]]

local command_examples = {
  link = [[
  cd ~/dotfiles/config
  lnko link bash git nvim

  lnko link -d ~/dotfiles/config -t ~ bash git nvim

  lnko link -b --ignore '.git' --ignore 'README*' --ignore '*.swp' bash

  lnko link -n bash
]],
  unlink = [[
  lnko unlink bash

  lnko unlink -d ~/dotfiles/config bash git
]],
  status = [[
  lnko status -d ~/dotfiles/config

  lnko status --json -d ~/dotfiles/config
]],
  clean = [[
  lnko clean -d ~/dotfiles/config

  lnko clean --remove-orphans -d ~/dotfiles/config
]],
}

local function options_for(command)
  local applicable = {}
  for _, option in ipairs(cli_options) do
    if option.all or (command and option.commands and option.commands[command]) then
      applicable[#applicable + 1] = option
    end
  end
  return applicable
end

local function find_option(options, arg)
  for _, option in ipairs(options) do
    for _, flag in ipairs(option.flags) do
      if flag == arg then return option end
    end
  end
  return nil
end

local function levenshtein(a, b)
  local matrix = {}
  for i = 0, #a do
    matrix[i] = {}
    for j = 0, #b do
      if i == 0 then
        matrix[i][j] = j
      elseif j == 0 then
        matrix[i][j] = i
      else
        matrix[i][j] = math.min(
          matrix[i - 1][j] + 1,
          matrix[i][j - 1] + 1,
          matrix[i - 1][j - 1] + (a:sub(i, i) == b:sub(j, j) and 0 or 1)
        )
      end
    end
  end
  return matrix[#a][#b]
end

local function suggest_option(options, arg)
  local best, best_distance = nil, math.huge
  for _, option in ipairs(options) do
    for _, flag in ipairs(option.flags) do
      local distance = levenshtein(arg, flag)
      if distance < best_distance then
        best_distance = distance
        best = flag
      end
    end
  end
  if best and best_distance <= 2 then return best end
  return nil
end

local function suggest_command(arg)
  local best, best_distance = nil, math.huge
  for _, command in ipairs(cli_commands) do
    local distance = levenshtein(arg, command.name)
    if distance < best_distance then
      best_distance = distance
      best = command.name
    end
  end
  if best and best_distance <= 2 then return best end
  return nil
end

local function render_options(command)
  local max_len = 0
  for _, option in ipairs(options_for(command)) do
    local flags = table.concat(option.flags, ", ")
    if option.arg then flags = flags .. " <" .. option.arg .. ">" end
    if #flags > max_len then max_len = #flags end
  end
  for _, option in ipairs(options_for(command)) do
    local flags = table.concat(option.flags, ", ")
    if option.arg then flags = flags .. " <" .. option.arg .. ">" end
    output.write(
      "  ",
      output.color("yellow"),
      flags,
      output.reset(),
      string.rep(" ", max_len - #flags + 3),
      option.desc,
      "\n"
    )
  end
end

function module.show_version()
  local parts = {}

  if version.commit ~= "" then parts[#parts + 1] = "commit: " .. version.commit end
  if version.built ~= "" then parts[#parts + 1] = "built: " .. version.built end

  local extra = #parts > 0 and (" (" .. table.concat(parts, ", ") .. ")") or ""
  output.write("lnko ", version.version, extra, "\n")
end

function module.show_help(command)
  if command and command_lookup[command] then
    local spec = command_lookup[command]

    output.write(output.color("cyan"), "usage:", output.reset(), " lnko ", command)
    if spec.args ~= "" then output.write(" ", spec.args) end
    output.write("\n\n")

    output.write(spec.desc, "\n\n")
    output.write(output.color("bright_black"), "options:\n", output.reset())
    render_options(command)

    output.write(output.color("bright_black"), "\nexamples:\n", output.reset())
    output.write(command_examples[command])
    return
  end

  output.write(output.color("blue"), banner, output.reset(), "\n")
  output.write(output.color("cyan"), "usage:", output.reset(), " lnko <command> [options] [packages...]\n\n")

  output.write(output.color("bright_black"), "commands:\n", output.reset())

  local max_name = 0
  local max_args = 0
  for _, spec in ipairs(cli_commands) do
    if #spec.name > max_name then max_name = #spec.name end
    if #spec.args > max_args then max_args = #spec.args end
  end
  for _, spec in ipairs(cli_commands) do
    output.write(
      "  ",
      output.color("cyan"),
      spec.name,
      output.reset(),
      string.rep(" ", max_name - #spec.name + 1),
      spec.args,
      string.rep(" ", max_args - #spec.args + 2),
      spec.desc,
      "\n"
    )
  end

  output.write(output.color("bright_black"), "\noptions:\n", output.reset())
  render_options(nil)
  output.write(
    "\nrun '",
    output.color("cyan"),
    "lnko <command> --help",
    output.reset(),
    "' for command-specific examples.\n"
  )
end

function module.run(commands, args)
  local options = {}
  local explicit = {}
  local command = nil
  local packages = {}

  local i = 1
  while i <= #args do
    local a = args[i]

    local option = find_option(cli_options, a)

    if option == nil then
      if a:sub(1, 1) == "-" then
        log.error("unknown option: " .. a)
        local suggestion = suggest_option(options_for(command), a)
        if suggestion then log.error("did you mean '" .. suggestion .. "'?") end
        log.error("run 'lnko " .. (command or "") .. " --help' for usage")
        os.exit(2)
      end
    end

    if option then
      if command and not option.all and option.commands and not option.commands[command] then
        log.error("unknown option for " .. command .. ": " .. a)
        local suggestion = suggest_option(options_for(command), a)
        if suggestion then log.error("did you mean '" .. suggestion .. "'?") end
        os.exit(2)
      end

      if option.key == "help" then
        module.show_help(command)
        os.exit(0)
      end

      if option.key == "version" then
        module.show_version()
        os.exit(0)
      end

      if option.arg then
        i = i + 1
        local value = args[i]
        if not value or value:sub(1, 1) == "-" then
          log.error("option " .. a .. " requires a value")
          os.exit(2)
        end
        if option.list then
          options[option.key] = options[option.key] or {}
          options[option.key][#options[option.key] + 1] = value
        else
          options[option.key] = value
        end
        explicit[option.key] = true
      else
        options[option.key] = true
        explicit[option.key] = true
      end
    elseif not command then
      command = a

      if not command_lookup[command] then
        log.error("unknown command: " .. command)
        local suggestion = suggest_command(command)
        if suggestion then log.error("did you mean '" .. suggestion .. "'?") end
        log.error("run 'lnko --help' for usage")
        os.exit(2)
      end
    else
      packages[#packages + 1] = a
    end

    i = i + 1
  end

  if not command then
    module.show_help()
    os.exit(2)
  end

  for _, option in ipairs(options_for(command)) do
    if option.key ~= "help" and options[option.key] == nil then
      if option.list then
        options[option.key] = {}
      else
        options[option.key] = false
      end
    end
  end

  if not options.source_dir then options.source_dir = fs.current_dir() end
  if not options.target_dir then options.target_dir = os.getenv("HOME") end

  local config_path, config_required

  if options.config then
    config_path = fs.absolute(config_mod.expand(options.config))
    config_required = true
  else
    config_path, config_required = config_mod.find(options.source_dir)
  end

  if config_path then
    local config = config_mod.load(config_path)
    if config then
      config_mod.apply(options, config, explicit)
    elseif config_required then
      os.exit(1)
    end
  elseif config_required then
    os.exit(1)
  end

  if not options.source_dir then options.source_dir = fs.current_dir() end

  if not fs.is_directory(options.source_dir) then
    log.error("source directory not found: " .. options.source_dir)
    os.exit(1)
  end

  if not fs.is_directory(options.target_dir) then
    log.error("target directory not found: " .. options.target_dir)
    os.exit(1)
  end

  if options.dry_run then log.warn("dry-run mode, no changes will be made") end

  if command == "link" then
    if #packages == 0 and options.packages then packages = options.packages end
    if #packages == 0 then
      log.error("no packages specified")
      os.exit(2)
    end
    for _, pkg in ipairs(packages) do
      if not commands.link_package(options.source_dir, pkg, options.target_dir, options) then os.exit(1) end
    end
  elseif command == "unlink" then
    if #packages == 0 then
      log.error("no packages specified")
      os.exit(2)
    end
    for _, pkg in ipairs(packages) do
      if not commands.unlink_package(options.source_dir, pkg, options.target_dir, options) then os.exit(1) end
    end
  elseif command == "status" then
    commands.show_status(options.source_dir, options.target_dir, options)
  elseif command == "clean" then
    commands.clean_orphans(options.source_dir, options.target_dir, options)
  else
    log.error("unknown command: " .. command)
    os.exit(2)
  end

  os.exit(0)
end

return module
