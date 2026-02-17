local api = vim.api
local fn = vim.fn
local chats = require("cursorcli.chats")

local M = {}

function M.is_job_running(chat_id)
  chat_id = chat_id or chats.get_active_id()
  if not chat_id then
    return false
  end
  local chat = chats.get(chat_id)
  if not chat or type(chat.job_id) ~= "number" or chat.job_id <= 0 then
    return false
  end

  local ok, result = pcall(fn.jobwait, { chat.job_id }, 0)
  if not ok or not result or result[1] ~= -1 then
    chats.set_job_id(chat_id, nil)
    return false
  end
  return true
end

function M.configure_terminal_buffer(bufnr, close_cb, chat_id)
  api.nvim_set_option_value("bufhidden", "hide", { buf = bufnr })
  api.nvim_set_option_value("swapfile", false, { buf = bufnr })

  vim.keymap.set("n", "q", function()
    if close_cb then close_cb() end
  end, {
    buffer = bufnr,
    silent = true,
    desc = "Close Cursor CLI window",
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
    desc = "Close Cursor CLI window",
  })
end

return M
