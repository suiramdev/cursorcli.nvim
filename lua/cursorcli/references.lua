local api = vim.api
local fn = vim.fn
local config = require("cursorcli.config")
local notify = require("cursorcli.notify")

local M = {}

function M.normalize_path(path)
  local opts = config.opts()
  if not opts or not opts.path then
    return fn.fnamemodify(path, ":p"):gsub(" ", "\\ ")
  end
  local absolute = fn.fnamemodify(path, ":p")
  local normalized = opts.path.relative_to_cwd and fn.fnamemodify(absolute, ":.") or absolute
  return normalized:gsub(" ", "\\ ")
end

function M.create_reference(bufnr, line_start, line_end)
  local path = api.nvim_buf_get_name(bufnr)
  if path == "" then
    notify.notify("Current buffer has no file path. Save the file first.", vim.log.levels.WARN)
    return nil
  end

  local first = math.min(line_start, line_end)
  local last = math.max(line_start, line_end)
  local normalized = M.normalize_path(path)

  return ("@%s:%d-%d"):format(normalized, first, last)
end

return M
