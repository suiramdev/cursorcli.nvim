local api = vim.api
local chats = require("cursorcli.chats")
local util = require("cursorcli.util")
local window = require("cursorcli.agent.window")

local M = {}

local augroup_id = nil

function M.setup()
  if augroup_id then
    pcall(api.nvim_del_augroup_by_id, augroup_id)
  end
  augroup_id = api.nvim_create_augroup("CursorCliIntegration", { clear = true })

  api.nvim_create_autocmd("VimResized", {
    group = augroup_id,
    callback = function()
      if not window.is_float_layout() then
        return
      end
      local active = chats.get_active()
      if active and util.is_valid_win(active.win) then
        pcall(api.nvim_win_set_config, active.win, window.build_float_config())
      end
    end,
  })

  api.nvim_create_autocmd("TermClose", {
    group = augroup_id,
    callback = function(args)
      local chat = chats.find_by_buf(args.buf)
      if chat then
        chats.set_job_id(chat.id, nil)
      end
    end,
  })

  api.nvim_create_autocmd("WinClosed", {
    group = augroup_id,
    callback = function(args)
      local closed = tonumber(args.match)
      local chat = chats.find_by_win(closed)
      if chat then
        chat.win = nil
      end
    end,
  })

  api.nvim_create_autocmd("BufWipeout", {
    group = augroup_id,
    callback = function(args)
      local chat = chats.find_by_buf(args.buf)
      if chat then
        chats.clear_buf_win_job(chat.id)
      end
    end,
  })
end

return M
