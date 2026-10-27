local module = {}

local output = require("lnko.output")

local action_colors = {
  link = "green",
  unlink = "yellow",
  backup = "blue",
  skip = "bright_black",
  mkdir = "blue",
  rmdir = "yellow",
}

function module.info(msg)
  output.err(output.color("blue"), "[info]", output.reset(), " ", msg, "\n")
end

function module.success(msg)
  output.err(output.color("green"), "[success]", output.reset(), " ", msg, "\n")
end

function module.warn(msg)
  output.err(output.color("yellow"), "[warn]", output.reset(), " ", msg, "\n")
end

function module.error(msg)
  output.err(output.color("red"), "[error]", output.reset(), " ", msg, "\n")
end

function module.debug(msg, verbose)
  if verbose then output.err(output.color("bright_black"), "[debug]", output.reset(), " ", msg, "\n") end
end

function module.hint(msg)
  output.err(output.color("bright_black"), "  hint: ", output.reset(), msg, "\n")
end

function module.action(action, path)
  local color = action_colors[action] or "white"
  output.err("  ", output.color(color), action, output.reset(), " ", path, "\n")
end

return module
