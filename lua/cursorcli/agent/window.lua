local api = vim.api
local config = require("cursorcli.config")
local util = require("cursorcli.util")
local chats = require("cursorcli.chats")

local M = {}

local function is_float_layout()
  local opts = config.opts()
  local pos = (opts and opts.position) or "float"
  return pos == "float"
end

local function build_float_config()
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

--- Open a split window and display the buffer. Returns the new window id or nil.
--- @param bufnr number
--- @param position_override? string "right"|"left"|"bottom"|"top" (uses config if nil)
local function open_split_window(bufnr, position_override)
  local opts = config.opts()
  local pos = position_override or (opts and opts.position) or "right"
  local size = (opts and opts.split_size) or 0.4
  local editor_width = math.max(1, vim.o.columns)
  local editor_height = math.max(1, vim.o.lines - vim.o.cmdheight)

  local size_abs
  if type(size) == "number" and size > 0 and size < 1 then
    size_abs = pos == "left" or pos == "right"
      and math.max(10, math.floor(editor_width * size))
      or math.max(5, math.floor(editor_height * size))
  else
    local min_size = (pos == "left" or pos == "right") and 10 or 5
    size_abs = math.max(min_size, math.floor(size))
  end

  local cmd
  if pos == "right" then
    cmd = ("rightbelow vertical %dsplit"):format(size_abs)
  elseif pos == "left" then
    cmd = ("leftabove vertical %dsplit"):format(size_abs)
  elseif pos == "bottom" then
    cmd = ("rightbelow %dsplit"):format(size_abs)
  else
    cmd = ("leftabove %dsplit"):format(size_abs) -- top
  end

  vim.cmd(cmd)
  local win = api.nvim_get_current_win()
  api.nvim_win_set_buf(win, bufnr)
  return win
end

local function apply_window_style(win, floating)
  if not win or not util.is_valid_win(win) then
    return
  end
  local opts = config.opts()
  if floating and opts.float and opts.float.winhighlight and opts.float.winhighlight ~= "" then
    api.nvim_set_option_value("winhighlight", opts.float.winhighlight, { win = win })
  end
  if floating and opts.float then
    api.nvim_set_option_value("winblend", opts.float.winblend or 0, { win = win })
  end
  api.nvim_set_option_value("number", false, { win = win })
  api.nvim_set_option_value("relativenumber", false, { win = win })
  api.nvim_set_option_value("signcolumn", "no", { win = win })
end

function M.build_float_config()
  return build_float_config()
end

function M.is_float_layout()
  return is_float_layout()
end

--- @param open_opts? { position?: string } "float"|"right"|"left"|"bottom"|"top" for this open only
function M.open_window(chat_id, _close_cb, open_opts)
  local chat = chats.get(chat_id)
  if not chat or not util.is_valid_buf(chat.buf) then
    return false
  end

  local position_override = open_opts and open_opts.position
  local use_float = position_override
    and (position_override == "float")
    or (not position_override and is_float_layout())

  if util.is_valid_win(chat.win) then
    if position_override then
      -- Requested a specific layout; close current window so we reopen with it.
      pcall(api.nvim_win_close, chat.win, true)
      chat.win = nil
    else
      local current_tab = api.nvim_get_current_tabpage()
      if api.nvim_win_get_tabpage(chat.win) ~= current_tab then
        chat.win = nil
      else
        if api.nvim_win_get_buf(chat.win) ~= chat.buf then
          api.nvim_win_set_buf(chat.win, chat.buf)
        end
        api.nvim_set_current_win(chat.win)
        apply_window_style(chat.win, is_float_layout())
        return true
      end
    end
  end

  if use_float then
    chat.win = api.nvim_open_win(chat.buf, true, build_float_config())
  else
    chat.win = open_split_window(chat.buf, position_override)
  end
  apply_window_style(chat.win, use_float)
  return true
end

function M.close_window(chat_id)
  local chat = chat_id and chats.get(chat_id) or nil
  if not chat then
    return
  end
  if not util.is_valid_win(chat.win) then
    chat.win = nil
    return
  end
  pcall(api.nvim_win_close, chat.win, true)
  chat.win = nil
end

function M.delete_buffer(chat_id)
  local chat = chat_id and chats.get(chat_id) or nil
  if not chat then
    return
  end
  if not util.is_valid_buf(chat.buf) then
    chat.buf = nil
    return
  end
  pcall(api.nvim_buf_delete, chat.buf, { force = true })
  chat.buf = nil
  chat.job_id = nil
  chat.win = nil
end

return M
