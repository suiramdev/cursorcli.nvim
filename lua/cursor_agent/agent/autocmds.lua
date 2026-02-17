local api = vim.api
local config = require("cursor_agent.config")
local util = require("cursor_agent.util")
local window = require("cursor_agent.agent.window")

local M = {}

function M.setup()
  local state = config.get_state()
  if state.augroup then
    pcall(api.nvim_del_augroup_by_id, state.augroup)
  end
  state.augroup = api.nvim_create_augroup("CursorAgentIntegration", { clear = true })

  api.nvim_create_autocmd("VimResized", {
    group = state.augroup,
    callback = function()
      if util.is_valid_win(state.win) then
        pcall(api.nvim_win_set_config, state.win, window.build_float_config())
      end
    end,
  })

  api.nvim_create_autocmd("TermClose", {
    group = state.augroup,
    callback = function(args)
      if args.buf == state.buf then
        state.job_id = nil
      end
    end,
  })

  api.nvim_create_autocmd("WinClosed", {
    group = state.augroup,
    callback = function(args)
      local closed = tonumber(args.match)
      if closed and state.win == closed then
        state.win = nil
      end
    end,
  })

  api.nvim_create_autocmd("BufWipeout", {
    group = state.augroup,
    callback = function(args)
      if args.buf == state.buf then
        state.buf = nil
        state.job_id = nil
        state.win = nil
      end
    end,
  })
end

return M
