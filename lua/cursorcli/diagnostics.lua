local api = vim.api
local references = require("cursorcli.references")

local M = {}

function M.build_fix_error_message_at_cursor()
  local bufnr = api.nvim_get_current_buf()
  local line = api.nvim_win_get_cursor(0)[1]
  local diagnostics = vim.diagnostic.get(bufnr, { lnum = line - 1 })
  if not diagnostics or #diagnostics == 0 then
    return nil
  end

  local error_lines = {}
  local line_start, line_end = line, line
  for _, d in ipairs(diagnostics) do
    table.insert(error_lines, d.message)
    if d.lnum ~= nil then
      line_start = math.min(line_start, d.lnum + 1)
      line_end = math.max(line_end, (d.end_lnum and d.end_lnum > d.lnum) and (d.end_lnum + 1) or (d.lnum + 1))
    end
  end
  local error_text = table.concat(error_lines, "\n")
  local reference = references.create_reference(bufnr, line_start, line_end)
  if not reference then
    return nil
  end
  return ("Please fix the following error:\n\n```\n%s\n```\n\n%s"):format(error_text, reference)
end

return M
