local module = {}

local fs = require("lnko.fs")
local plan_mod = require("lnko.plan")
local tree = require("lnko.tree")
local output = require("lnko.output")

-- colors --

local action_colors = {
  link = "green",
  unlink = "yellow",
  backup = "blue",
  skip = "bright_black",
  mkdir = "blue",
  rmdir = "yellow",
}

-- logging --

local log = {}

function log.info(msg)
  output.write(output.color("blue"), "[info]", output.reset(), " ", msg, "\n")
end

function log.success(msg)
  output.write(output.color("green"), "[success]", output.reset(), " ", msg, "\n")
end

function log.warn(msg)
  output.write(output.color("yellow"), "[warn]", output.reset(), " ", msg, "\n")
end

function log.error(msg)
  io.stderr:write(output.color("red") .. "[error]" .. output.reset() .. " " .. msg .. "\n")
end

function log.debug(msg, verbose)
  if verbose then output.write(output.color("bright_black"), "[debug]", output.reset(), " ", msg, "\n") end
end

function log.action(action, path)
  local color = action_colors[action] or "white"
  output.write("  ", output.color(color), action, output.reset(), " ", path, "\n")
end

-- helpers --

local function compile_glob(glob)
  local specials = "().%+-?[]^$*"
  local buf = { "^" }
  for i = 1, #glob do
    local c = glob:sub(i, i)
    if c == "*" then
      buf[#buf + 1] = "[^/]*"
    elseif c == "?" then
      buf[#buf + 1] = "[^/]"
    elseif specials:find(c, 1, true) then
      buf[#buf + 1] = "%" .. c
    else
      buf[#buf + 1] = c
    end
  end
  buf[#buf + 1] = "$"
  return {
    pattern = table.concat(buf),
    path_scoped = glob:find("/", 1, true) ~= nil,
  }
end

local function compile_ignores(patterns)
  local compiled = {}
  for _, glob in ipairs(patterns) do
    compiled[#compiled + 1] = compile_glob(glob)
  end
  return compiled
end

local function is_ignored(relative_path, compiled)
  local basename
  for _, c in ipairs(compiled) do
    local target
    if c.path_scoped then
      target = relative_path
    else
      basename = basename or (relative_path:match("[^/]+$") or relative_path)
      target = basename
    end
    if target:match(c.pattern) then return true end
  end
  return false
end

local function get_backup_path(path, target_dir)
  local timestamp = os.date("%Y%m%d-%H%M%S")
  local backup_dir = fs.join(target_dir, ".lnko-backup")
  local escaped_target = target_dir:gsub("([^%w])", "%%%1")
  local relative = path:gsub("^" .. escaped_target .. "/", "")
  return fs.join(backup_dir, relative .. "." .. timestamp)
end

local function ask_conflict(target_path, options)
  if options.backup then return "backup" end
  if options.skip then return "skip" end
  if options.force then return "overwrite" end

  output.write(output.color("yellow"), "  conflict", output.reset(), " ", target_path, "\n")
  output.write("    [b]ackup  [s]kip  [o]verwrite  [d]iff  [q]uit? ")

  local answer = io.read("*l")
  if not answer then return "quit" end
  answer = answer:lower()

  if answer == "b" or answer == "backup" then return "backup" end
  if answer == "s" or answer == "skip" then return "skip" end
  if answer == "o" or answer == "overwrite" then return "overwrite" end
  if answer == "d" or answer == "diff" then return "diff" end
  if answer == "q" or answer == "quit" then return "quit" end

  return "skip"
end

local function show_diff(source, target)
  os.execute("diff -u " .. string.format("%q", target) .. " " .. string.format("%q", source) .. " | head -50")
end

local function resolve_conflict(target_path, source_path, options)
  local action = ask_conflict(target_path, options)
  if action == "quit" then return "quit" end
  if action == "diff" then
    if source_path then
      local diff_target = target_path
      if fs.is_symlink(target_path) then diff_target = fs.resolve_symlink(target_path) or target_path end
      show_diff(source_path, diff_target)
    end
    action = ask_conflict(target_path, options)
    if action == "quit" then return "quit" end
  end
  return action
end

local function list_packages(source_dir)
  local packages = {}
  local entries = fs.dir(source_dir)
  for _, entry in ipairs(entries) do
    local pkg_path = fs.join(source_dir, entry)
    if fs.is_directory(pkg_path) then packages[#packages + 1] = entry end
  end
  return packages
end

-- planning --

function module.plan_link(source_dir, package, target_dir, options)
  options = options or {}
  source_dir = fs.canonical(source_dir)
  target_dir = fs.canonical(target_dir)
  local pkg_dir = fs.join(source_dir, package)
  local plan = plan_mod.new()

  if not fs.is_directory(pkg_dir) then
    plan_mod.add_conflict(plan, pkg_dir, "package not found")
    return plan
  end

  log.debug("planning link for " .. package, options.verbose)

  local ignores = compile_ignores(options.ignore or {})

  local function handle_dir_conflict(source_path, target_path)
    local action = resolve_conflict(target_path, source_path, options)
    if action == "quit" then return "quit" end
    if action == "backup" then
      local backup_path = get_backup_path(target_path, target_dir)
      plan_mod.add_task(plan, plan_mod.ACTION_BACKUP, target_path, nil, { backup_path = backup_path })
      plan_mod.add_task(plan, plan_mod.ACTION_MKDIR, target_path)
      return "continue"
    elseif action == "overwrite" then
      plan_mod.add_task(plan, plan_mod.ACTION_UNLINK, target_path)
      plan_mod.add_task(plan, plan_mod.ACTION_MKDIR, target_path)
      return "continue"
    end
    return "skip"
  end

  local function handle_file_conflict(source_path, target_path)
    local action = resolve_conflict(target_path, source_path, options)
    if action == "quit" then return "quit" end
    if action == "backup" then
      local backup_path = get_backup_path(target_path, target_dir)
      plan_mod.add_task(plan, plan_mod.ACTION_BACKUP, target_path, nil, { backup_path = backup_path })
      local rel_source = fs.relative(fs.dirname(target_path), source_path)
      plan_mod.add_task(plan, plan_mod.ACTION_LINK, target_path, rel_source)
    elseif action == "overwrite" then
      plan_mod.add_task(plan, plan_mod.ACTION_UNLINK, target_path)
      local rel_source = fs.relative(fs.dirname(target_path), source_path)
      plan_mod.add_task(plan, plan_mod.ACTION_LINK, target_path, rel_source)
    end
    return "ok"
  end

  local function process_dir(pkg_subdir, target_subdir)
    local entries = fs.dir(pkg_subdir)

    for _, entry in ipairs(entries) do
      local source_path = fs.join(pkg_subdir, entry)
      local target_path = fs.join(target_subdir, entry)
      local relative_path = source_path:sub(#pkg_dir + 2)

      if is_ignored(relative_path, ignores) then
        plan_mod.add_skipped(plan, target_path)
        log.debug("ignoring " .. relative_path, options.verbose)
      elseif fs.is_directory(source_path) and not fs.is_symlink(source_path) then
        if plan_mod.is_a_link(plan, target_path) then
          local existing_pkg_path = tree.can_unfold(target_path, source_path, source_dir, plan)
          if existing_pkg_path == source_path then
            log.debug("already linked " .. target_path, options.verbose)
          elseif existing_pkg_path then
            log.debug("unfolding " .. target_path, options.verbose)
            tree.unfold(target_path, existing_pkg_path, plan)
            if not process_dir(source_path, target_path) then return false end
          else
            local resolved = fs.resolve_symlink(target_path)
            if resolved and fs.is_directory(resolved) then
              plan_mod.add_conflict(plan, target_path, "symlink to different package")
            else
              local result = handle_dir_conflict(source_path, target_path)
              if result == "quit" then return false end
              if result == "continue" then
                if not process_dir(source_path, target_path) then return false end
              end
            end
          end
        elseif plan_mod.is_a_dir(plan, target_path) then
          if not process_dir(source_path, target_path) then return false end
        elseif fs.exists(target_path) then
          local result = handle_dir_conflict(source_path, target_path)
          if result == "quit" then return false end
          if result == "continue" then
            if not process_dir(source_path, target_path) then return false end
          end
        else
          if options.no_folding then
            plan_mod.add_task(plan, plan_mod.ACTION_MKDIR, target_path)
            if not process_dir(source_path, target_path) then return false end
          else
            local rel_source = fs.relative(target_subdir, source_path)
            plan_mod.add_task(plan, plan_mod.ACTION_LINK, target_path, rel_source)
            log.debug("planned folder link " .. target_path .. " -> " .. rel_source, options.verbose)
          end
        end
      else
        if plan_mod.is_a_link(plan, target_path) then
          if fs.symlink_points_to(target_path, source_path) then
            log.debug("already linked " .. target_path, options.verbose)
          else
            local result = handle_file_conflict(source_path, target_path)
            if result == "quit" then return false end
          end
        elseif fs.exists(target_path) then
          local result = handle_file_conflict(source_path, target_path)
          if result == "quit" then return false end
        else
          local rel_source = fs.relative(fs.dirname(target_path), source_path)
          plan_mod.add_task(plan, plan_mod.ACTION_LINK, target_path, rel_source)
          log.debug("planned link " .. target_path .. " -> " .. rel_source, options.verbose)
        end
      end
    end

    return true
  end

  local ok = process_dir(pkg_dir, target_dir)
  if not ok then return plan_mod.new() end
  return plan
end

function module.plan_unlink(source_dir, package, target_dir, options)
  options = options or {}
  source_dir = fs.canonical(source_dir)
  target_dir = fs.canonical(target_dir)
  local pkg_dir = fs.join(source_dir, package)
  local plan = plan_mod.new()

  if not fs.is_directory(pkg_dir) then
    plan_mod.add_conflict(plan, pkg_dir, "package not found")
    return plan
  end

  log.debug("planning unlink for " .. package, options.verbose)

  local function process_dir(pkg_subdir, target_subdir)
    local entries = fs.dir(pkg_subdir)

    for _, entry in ipairs(entries) do
      local source_path = fs.join(pkg_subdir, entry)
      local target_path = fs.join(target_subdir, entry)

      if fs.is_directory(source_path) and not fs.is_symlink(source_path) then
        if fs.is_symlink(target_path) then
          if fs.symlink_points_to(target_path, source_path) then
            plan_mod.add_task(plan, plan_mod.ACTION_UNLINK, target_path)
          end
        elseif fs.is_directory(target_path) then
          process_dir(source_path, target_path)
        end
      else
        if fs.is_symlink(target_path) and fs.symlink_points_to(target_path, source_path) then
          plan_mod.add_task(plan, plan_mod.ACTION_UNLINK, target_path)
        end
      end
    end
  end

  process_dir(pkg_dir, target_dir)
  return plan
end

-- commands --

function module.link_package(source_dir, package, target_dir, options)
  options = options or {}

  log.info("linking " .. package)

  local plan = module.plan_link(source_dir, package, target_dir, options)

  if plan_mod.has_conflicts(plan) then
    for _, conflict in ipairs(plan_mod.get_conflicts(plan)) do
      log.error(conflict.path .. ": " .. conflict.message)
    end
    return false
  end

  local tasks = plan_mod.get_tasks(plan)
  local skipped = plan_mod.get_skipped(plan)

  if options.dry_run or options.verbose then
    for _, path in ipairs(skipped) do
      log.action("skip", path)
    end
  end

  if #tasks == 0 then
    local suffix = #skipped > 0 and (" (" .. #skipped .. " skipped)") or ""
    log.success(package .. ": already linked" .. suffix)
    return true
  end

  local executed, failed = plan_mod.execute(plan, {
    dry_run = options.dry_run,
    verbose = options.verbose,
    on_action = function(action, path, source)
      if source then
        log.action(action, path .. " -> " .. source)
      else
        log.action(action, path)
      end
    end,
  })

  if options.dry_run then
    log.info(string.format("preview: %d task(s), %d skipped", #tasks, #skipped))
  end

  if failed > 0 then
    log.warn(package .. ": " .. executed .. " completed, " .. failed .. " failed")
  else
    log.success(package .. ": " .. executed .. " tasks completed")
  end

  return failed == 0
end

function module.unlink_package(source_dir, package, target_dir, options)
  options = options or {}

  log.info("unlinking " .. package)

  local plan = module.plan_unlink(source_dir, package, target_dir, options)

  if plan_mod.has_conflicts(plan) then
    for _, conflict in ipairs(plan_mod.get_conflicts(plan)) do
      log.error(conflict.path .. ": " .. conflict.message)
    end
    return false
  end

  local tasks = plan_mod.get_tasks(plan)
  if #tasks == 0 then
    log.success(package .. ": nothing to unlink")
    return true
  end

  local executed, failed = plan_mod.execute(plan, {
    dry_run = options.dry_run,
    verbose = options.verbose,
    on_action = function(action, path)
      log.action(action, path)
    end,
  })

  if failed > 0 then
    log.warn(package .. ": " .. executed .. " completed, " .. failed .. " failed")
  else
    log.success(package .. ": " .. executed .. " unlinked")
  end

  return failed == 0
end

function module.show_status(source_dir, target_dir, _options)
  source_dir = fs.canonical(source_dir)
  target_dir = fs.canonical(target_dir)
  local packages = list_packages(source_dir)

  if #packages == 0 then
    log.warn("no packages found in " .. source_dir)
    return
  end

  for _, package in ipairs(packages) do
    local pkg_dir = fs.join(source_dir, package)
    local linked = 0
    local missing = 0
    local conflict = 0
    local total = 0

    local function count_dir(pkg_subdir, target_subdir)
      local entries = fs.dir(pkg_subdir)

      for _, entry in ipairs(entries) do
        local source_path = fs.join(pkg_subdir, entry)
        local target_path = fs.join(target_subdir, entry)

        if fs.is_directory(source_path) and not fs.is_symlink(source_path) then
          if fs.is_symlink(target_path) then
            if fs.symlink_points_to(target_path, source_path) then
              total = total + 1
              linked = linked + 1
            else
              total = total + 1
              conflict = conflict + 1
            end
          elseif fs.is_directory(target_path) then
            count_dir(source_path, target_path)
          else
            total = total + 1
            if fs.exists(target_path) then
              conflict = conflict + 1
            else
              missing = missing + 1
            end
          end
        else
          total = total + 1
          if fs.is_symlink(target_path) then
            if fs.symlink_points_to(target_path, source_path) then
              linked = linked + 1
            else
              conflict = conflict + 1
            end
          elseif fs.exists(target_path) then
            conflict = conflict + 1
          else
            missing = missing + 1
          end
        end
      end
    end

    count_dir(pkg_dir, target_dir)

    local status_color = "green"
    local status_text = "ok"

    if conflict > 0 then
      status_color = "red"
      status_text = "conflict"
    elseif total == 0 or (missing > 0 and linked == 0) then
      status_color = "bright_black"
      status_text = "not linked"
    elseif missing > 0 then
      status_color = "yellow"
      status_text = "partial"
    end

    local item_word = total == 1 and "item" or "items"
    output.write(
      output.color(status_color),
      string.format("%-12s", status_text),
      output.reset(),
      " ",
      package,
      output.color("bright_black"),
      " (",
      total,
      " ",
      item_word,
      ")",
      output.reset(),
      "\n"
    )
  end
end

function module.find_orphans(source_dir, target_dir)
  local source_abs = fs.canonical(source_dir)
  local target_abs = fs.canonical(target_dir)
  local orphans = {}

  local function scan(dir)
    if not fs.is_directory(dir) then return end

    local entries = fs.dir(dir)
    for _, entry in ipairs(entries) do
      local path = fs.join(dir, entry)
      if fs.is_symlink(path) then
        local resolved = fs.absolute(fs.resolve_symlink(path))
        if resolved and resolved:sub(1, #source_abs) == source_abs then
          if not fs.exists(resolved) then orphans[#orphans + 1] = { link = path, target = resolved } end
        end
      elseif fs.is_directory(path) then
        scan(path)
      end
    end
  end

  scan(target_abs)
  return orphans
end

function module.clean_orphans(source_dir, target_dir, options)
  options = options or {}

  log.info("checking for orphan symlinks")

  local orphans = module.find_orphans(source_dir, target_dir)

  if #orphans == 0 then
    log.success("no orphans found")
    return true
  end

  local removed = 0
  local kept = 0

  for _, orphan in ipairs(orphans) do
    local action = "keep"

    if options.remove_orphans then
      action = "remove"
    elseif options.keep_orphans then
      action = "keep"
    else
      output.write(output.color("yellow"), "  orphan", output.reset(), " ", orphan.link, "\n")
      output.write("    [r]emove  [k]eep  [a]ll remove  [n]one? ")

      local answer = io.read("*l")
      if answer then
        answer = answer:lower()
        if answer == "r" or answer == "remove" then
          action = "remove"
        elseif answer == "a" or answer == "all" then
          options.remove_orphans = true
          action = "remove"
        elseif answer == "n" or answer == "none" then
          options.keep_orphans = true
          action = "keep"
        end
      end
    end

    if action == "remove" then
      if not options.dry_run then fs.remove(orphan.link) end
      log.action("unlink", orphan.link)
      removed = removed + 1
    else
      kept = kept + 1
    end
  end

  log.success(removed .. " removed, " .. kept .. " kept")
  return true
end

-- cli --

function module.show_help()
  output.write(output.color("bold"), "lnko", output.reset(), " - a simple stow-like dotfile linker\n")
  output.write([[
Usage: lnko <command> [options] [packages...]

Commands:
  link <packages...>    Create symlinks for packages
  unlink <packages...>  Remove symlinks for packages
  status                Show status of all packages
  clean                 Remove orphan symlinks

Options:
  -d, --dir <dir>       Source directory containing packages (default: cwd)
  -t, --target <dir>    Target directory (default: $HOME)
  -n, --dry-run         Show what would be done
  -v, --verbose         Show debug output
  -b, --backup          Auto-backup conflicts to <target>/.lnko-backup/
  -s, --skip            Auto-skip conflicts
  -f, --force           Auto-overwrite conflicts (dangerous)
  --ignore <glob>       Ignore files matching glob (can be repeated;
                        use '/' for path-scoped globs, basename otherwise)
  --no-folding          Don't fold directories into symlinks
  --remove-orphans      Auto-remove orphan symlinks
  --keep-orphans        Auto-keep orphan symlinks
  -h, --help            Show this help

Examples:
  cd ~/dotfiles/config
  lnko link bash git nvim

  lnko link -d ~/dotfiles/config -t ~ bash git nvim

  lnko link -b --ignore '.git' --ignore 'README*' --ignore '*.swp' bash

  lnko status -d ~/dotfiles/config

  lnko unlink bash

  lnko clean -d ~/dotfiles/config

  lnko link -n bash
]])
end

function module.main(args)
  local options = {
    source_dir = nil,
    target_dir = os.getenv("HOME"),
    dry_run = false,
    verbose = false,
    backup = false,
    skip = false,
    force = false,
    ignore = {},
    no_folding = false,
    remove_orphans = false,
    keep_orphans = false,
  }
  local command = nil
  local packages = {}

  local i = 1
  while i <= #args do
    local a = args[i]

    if a == "-h" or a == "--help" then
      module.show_help()
      os.exit(0)
    elseif a == "-d" or a == "--dir" then
      i = i + 1
      options.source_dir = args[i]
    elseif a == "-t" or a == "--target" then
      i = i + 1
      options.target_dir = args[i]
    elseif a == "-n" or a == "--dry-run" then
      options.dry_run = true
    elseif a == "-v" or a == "--verbose" then
      options.verbose = true
    elseif a == "-b" or a == "--backup" then
      options.backup = true
    elseif a == "-s" or a == "--skip" then
      options.skip = true
    elseif a == "-f" or a == "--force" then
      options.force = true
    elseif a == "--ignore" then
      i = i + 1
      options.ignore[#options.ignore + 1] = args[i]
    elseif a == "--no-folding" then
      options.no_folding = true
    elseif a == "--remove-orphans" then
      options.remove_orphans = true
    elseif a == "--keep-orphans" then
      options.keep_orphans = true
    elseif not command then
      command = a
    else
      packages[#packages + 1] = a
    end

    i = i + 1
  end

  if not command then
    module.show_help()
    os.exit(2)
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
    if #packages == 0 then
      log.error("no packages specified")
      os.exit(2)
    end
    for _, pkg in ipairs(packages) do
      if not module.link_package(options.source_dir, pkg, options.target_dir, options) then os.exit(1) end
    end
  elseif command == "unlink" then
    if #packages == 0 then
      log.error("no packages specified")
      os.exit(2)
    end
    for _, pkg in ipairs(packages) do
      if not module.unlink_package(options.source_dir, pkg, options.target_dir, options) then os.exit(1) end
    end
  elseif command == "status" then
    module.show_status(options.source_dir, options.target_dir, options)
  elseif command == "clean" then
    module.clean_orphans(options.source_dir, options.target_dir, options)
  else
    log.error("unknown command: " .. command)
    os.exit(2)
  end

  os.exit(0)
end

return module
