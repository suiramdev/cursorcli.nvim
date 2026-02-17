local api = vim.api

local M = {}

function M.is_valid_buf(bufnr)
  return type(bufnr) == "number" and bufnr > 0 and api.nvim_buf_is_valid(bufnr)
end

function M.is_valid_win(winnr)
  return type(winnr) == "number" and winnr > 0 and api.nvim_win_is_valid(winnr)
end

function M.resolve_size(value, total, fallback)
  local resolved = fallback
  if type(value) == "number" then
    if value > 0 and value < 1 then
      resolved = math.floor(total * value)
    elseif value >= 1 then
      resolved = math.floor(value)
    end
  end
  return math.max(1, math.min(total, resolved))
end

return M
