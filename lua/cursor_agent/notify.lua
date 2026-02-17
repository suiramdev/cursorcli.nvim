local config = require("cursor_agent.config")

local M = {}

local function has_snacks_notifier()
  local ok = pcall(function()
    return type(_G.Snacks) == "table" and type(_G.Snacks.notifier) == "table" and type(_G.Snacks.notifier.notify) == "function"
  end)
  return ok and type(_G.Snacks) == "table" and type(_G.Snacks.notifier) == "table" and type(_G.Snacks.notifier.notify) == "function"
end

function M.notify(message, level)
  local opts = config.opts()
  if not opts or not opts.notify then
    return
  end
  level = level or vim.log.levels.INFO
  vim.schedule(function()
    if has_snacks_notifier() then
      _G.Snacks.notifier.notify(message, level, { title = "Cursor Agent" })
    else
      vim.notify(message, level, { title = "Cursor Agent" })
    end
  end)
end

return M
