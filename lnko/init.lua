local module = {}

local fs = require("lnko.fs")
local plan_mod = require("lnko.plan")
local tree = require("lnko.tree")
local output = require("lnko.output")
local json = require("lnko.json")
local log = require("lnko.log")
local cli = require("lnko.cli")

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

  output.err(output.color("yellow"), "  conflict", output.reset(), " ", target_path, "\n")
  output.err("    [b]ackup  [s]kip  [o]verwrite  [d]iff  [q]uit? ")

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

  local verbose_hint = options.verbose or options.dry_run
  if verbose_hint then log.info("linking " .. package) end

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

  if options.dry_run then log.info(string.format("preview: %d task(s), %d skipped", #tasks, #skipped)) end

  if failed > 0 then
    log.warn(package .. ": " .. executed .. " completed, " .. failed .. " failed")
    return false
  end

  log.success(package .. ": " .. executed .. " tasks completed")
  if not options.dry_run then log.hint("run 'lnko unlink " .. package .. "' to undo") end

  return true
end

function module.unlink_package(source_dir, package, target_dir, options)
  options = options or {}

  if options.verbose or options.dry_run then log.info("unlinking " .. package) end

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
    return false
  end

  log.success(package .. ": " .. executed .. " unlinked")
  if not options.dry_run then log.hint("run 'lnko link " .. package .. "' to relink") end

  return true
end

function module.get_status(source_dir, target_dir)
  source_dir = fs.canonical(source_dir)
  target_dir = fs.canonical(target_dir)
  local packages = list_packages(source_dir)

  local results = {}

  local source_prefix = source_dir .. "/"

  for _, package in ipairs(packages) do
    local pkg_dir = fs.join(source_dir, package)
    local pkg_prefix = pkg_dir .. "/"
    local linked = 0
    local missing = 0
    local conflict = 0
    local occupied = 0
    local total = 0

    local function is_occupied_by_sibling(target_path)
      local resolved = fs.canonical(fs.resolve_symlink(target_path))
      if not resolved then return false end

      if resolved:sub(1, #source_prefix) ~= source_prefix then return false end

      return resolved:sub(1, #pkg_prefix) ~= pkg_prefix
    end

    local function count_dir(pkg_subdir, target_subdir)
      local entries = fs.dir(pkg_subdir)

      for _, entry in ipairs(entries) do
        local source_path = fs.join(pkg_subdir, entry)
        local target_path = fs.join(target_subdir, entry)

        if fs.is_directory(source_path) and not fs.is_symlink(source_path) then
          if fs.is_symlink(target_path) then
            total = total + 1
            if fs.symlink_points_to(target_path, source_path) then
              linked = linked + 1
            elseif is_occupied_by_sibling(target_path) then
              occupied = occupied + 1
            else
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
            elseif is_occupied_by_sibling(target_path) then
              occupied = occupied + 1
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

    local status_text = "ok"

    if conflict > 0 then
      status_text = "conflict"
    elseif linked == 0 and occupied > 0 then
      status_text = "occupied"
    elseif total == 0 or (missing > 0 and linked == 0) then
      status_text = "not linked"
    elseif missing > 0 then
      status_text = "partial"
    end

    results[#results + 1] = {
      package = package,
      status = status_text,
      total = total,
      linked = linked,
      missing = missing,
      occupied = occupied,
      conflict = conflict,
    }
  end

  return results
end

function module.show_status(source_dir, target_dir, options)
  options = options or {}

  local results = module.get_status(source_dir, target_dir)

  if #results == 0 then
    log.warn("no packages found in " .. source_dir)
    return
  end

  if options.json then
    output.write(json.encode(results), "\n")
    return
  end

  local status_colors = {
    ok = "green",
    conflict = "red",
    occupied = "bright_black",
    ["not linked"] = "bright_black",
    partial = "yellow",
  }

  for _, result in ipairs(results) do
    local item_word = result.total == 1 and "item" or "items"
    output.write(
      output.color(status_colors[result.status]),
      string.format("%-12s", result.status),
      output.reset(),
      " ",
      result.package,
      output.color("bright_black"),
      " (",
      result.total,
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
      output.err("    [r]emove  [k]eep  [a]ll remove  [n]one? ")

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

function module.main(args)
  cli.run(module, args)
end

return module
