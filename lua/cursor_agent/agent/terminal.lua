local api = vim.api
local fn = vim.fn
local config = require("cursor_agent.config")

local M = {}

function M.is_job_running()
  local state = config.get_state()
  if type(state.job_id) ~= "number" or state.job_id <= 0 then
    return false
  end

  local ok, result = pcall(fn.jobwait, { state.job_id }, 0)
  if not ok or not result or result[1] ~= -1 then
    state.job_id = nil
    return false
  end
  return true
end

function M.configure_terminal_buffer(bufnr, close_cb)
  api.nvim_set_option_value("bufhidden", "hide", { buf = bufnr })
  api.nvim_set_option_value("swapfile", false, { buf = bufnr })

  vim.keymap.set("n", "q", function()
    if close_cb then close_cb() end
  end, {
    buffer = bufnr,
    silent = true,
    desc = "Close Cursor Agent window",
  })

  vim.keymap.set("t", "<Esc><Esc>", [[<C-\><C-n>]], {
    buffer = bufnr,
    silent = true,
    desc = "Exit terminal mode",
  })

  vim.keymap.set("n", "<Esc>", function()
    if close_cb then close_cb() end
  end, {
    buffer = bufnr,
    silent = true,
    desc = "Close Cursor Agent window",
  })
end

return M
