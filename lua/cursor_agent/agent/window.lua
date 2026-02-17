local api = vim.api
local config = require("cursor_agent.config")
local util = require("cursor_agent.util")

local M = {}

local function build_float_config()
  local state = config.get_state()
  local opts = config.opts()
  local editor_width = math.max(1, vim.o.columns)
  local editor_height = math.max(1, vim.o.lines - vim.o.cmdheight)

  local width = util.resolve_size(opts.float.width, editor_width, math.floor(editor_width * 0.9))
  local height = util.resolve_size(opts.float.height, editor_height, math.floor(editor_height * 0.8))

  local row = math.max(0, math.floor((editor_height - height) / 2))
  local col = math.max(0, math.floor((editor_width - width) / 2))

  return {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = opts.float.border,
    title = opts.float.title,
    title_pos = opts.float.title_pos,
    zindex = opts.float.zindex,
  }
end

local function apply_window_style()
  local state = config.get_state()
  if not util.is_valid_win(state.win) then
    return
  end

  local opts = config.opts()
  if opts.float.winhighlight and opts.float.winhighlight ~= "" then
    api.nvim_set_option_value("winhighlight", opts.float.winhighlight, { win = state.win })
  end

  api.nvim_set_option_value("winblend", opts.float.winblend or 0, { win = state.win })
  api.nvim_set_option_value("number", false, { win = state.win })
  api.nvim_set_option_value("relativenumber", false, { win = state.win })
  api.nvim_set_option_value("signcolumn", "no", { win = state.win })
end

function M.build_float_config()
  return build_float_config()
end

function M.open_window(_close_cb)
  local state = config.get_state()
  if not util.is_valid_buf(state.buf) then
    return false
  end

  if util.is_valid_win(state.win) then
    local current_tab = api.nvim_get_current_tabpage()
    if api.nvim_win_get_tabpage(state.win) ~= current_tab then
      state.win = nil
    else
      if api.nvim_win_get_buf(state.win) ~= state.buf then
        api.nvim_win_set_buf(state.win, state.buf)
      end
      api.nvim_set_current_win(state.win)
      apply_window_style()
      return true
    end
  end

  state.win = api.nvim_open_win(state.buf, true, build_float_config())
  apply_window_style()
  return true
end

function M.close_window()
  local state = config.get_state()
  if not util.is_valid_win(state.win) then
    state.win = nil
    return
  end
  pcall(api.nvim_win_close, state.win, true)
  state.win = nil
end

function M.apply_window_style()
  apply_window_style()
end

function M.delete_buffer()
  local state = config.get_state()
  if not util.is_valid_buf(state.buf) then
    state.buf = nil
    return
  end
  pcall(api.nvim_buf_delete, state.buf, { force = true })
  state.buf = nil
end

return M
