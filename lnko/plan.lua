local module = {}

local fs = require("lnko.fs")

module.ACTION_LINK = "link"
module.ACTION_UNLINK = "unlink"
module.ACTION_MKDIR = "mkdir"
module.ACTION_RMDIR = "rmdir"
module.ACTION_BACKUP = "backup"

function module.new()
  return {
    tasks = {},
    conflicts = {},
    skipped = {},
    link_tasks = {},
    dir_tasks = {},
  }
end

function module.add_task(plan, action, path, source, options)
  plan.tasks[#plan.tasks + 1] = {
    action = action,
    path = path,
    source = source,
    options = options or {},
  }

  if action == module.ACTION_LINK then
    plan.link_tasks[path] = { action = "create", source = source }
  elseif action == module.ACTION_UNLINK then
    plan.link_tasks[path] = { action = "remove" }
  elseif action == module.ACTION_MKDIR then
    plan.dir_tasks[path] = "create"
  elseif action == module.ACTION_RMDIR then
    plan.dir_tasks[path] = "remove"
  end
end

function module.add_conflict(plan, path, message)
  plan.conflicts[#plan.conflicts + 1] = {
    path = path,
    message = message,
  }
end

function module.add_skipped(plan, path)
  plan.skipped[#plan.skipped + 1] = path
end

function module.get_skipped(plan)
  return plan.skipped
end

function module.has_conflicts(plan)
  return #plan.conflicts > 0
end

function module.get_conflicts(plan)
  return plan.conflicts
end

function module.get_tasks(plan)
  return plan.tasks
end

function module.parent_link_scheduled_for_removal(plan, path)
  local prefix = ""
  for part in path:gmatch("[^/]+") do
    prefix = prefix == "" and part or (prefix .. "/" .. part)
    local task = plan.link_tasks[prefix]
    if task and task.action == "remove" then return true end
  end
  return false
end

function module.is_a_link(plan, path)
  local task = plan.link_tasks[path]
  if task then
    if task.action == "remove" then
      return false
    elseif task.action == "create" then
      return true
    end
  end

  if fs.is_symlink(path) then return not module.parent_link_scheduled_for_removal(plan, path) end

  return false
end

function module.read_a_link(plan, path)
  local task = plan.link_tasks[path]
  if task and task.action == "create" then return task.source end

  if fs.is_symlink(path) then return fs.symlink_target(path) end

  return nil
end

function module.is_a_dir(plan, path)
  local action = plan.dir_tasks[path]
  if action == "remove" then
    return false
  elseif action == "create" then
    return true
  end

  if module.parent_link_scheduled_for_removal(plan, path) then return false end

  return fs.is_directory(path) and not fs.is_symlink(path)
end

function module.execute(plan, options)
  options = options or {}
  local dry_run = options.dry_run
  local verbose = options.verbose
  local on_action = options.on_action

  local executed = 0
  local failed = 0

  for _, task in ipairs(plan.tasks) do
    local ok, err = true, nil

    if on_action then on_action(task.action, task.path, task.source) end

    if not dry_run then
      if task.action == module.ACTION_LINK then
        local target_dir = fs.dirname(task.path)
        if not fs.exists(target_dir) then fs.mkdir_p(target_dir) end
        ok, err = fs.symlink(task.source, task.path)
      elseif task.action == module.ACTION_UNLINK then
        ok, err = fs.remove(task.path)
      elseif task.action == module.ACTION_MKDIR then
        ok, err = fs.mkdir_p(task.path)
      elseif task.action == module.ACTION_RMDIR then
        ok, err = fs.rmdir(task.path)
      elseif task.action == module.ACTION_BACKUP then
        local backup_path = task.options.backup_path
        local backup_dir = fs.dirname(backup_path)
        if not fs.exists(backup_dir) then fs.mkdir_p(backup_dir) end
        ok, err = os.rename(task.path, backup_path)
      end
    end

    if ok then
      executed = executed + 1
    else
      failed = failed + 1
      if verbose and err then io.stderr:write("error: " .. task.path .. ": " .. tostring(err) .. "\n") end
    end
  end

  return executed, failed
end

return module
