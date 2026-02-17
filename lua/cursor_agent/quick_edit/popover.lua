local api = vim.api
local fn = vim.fn
local config = require("cursor_agent.config")
local util = require("cursor_agent.util")
local stream = require("cursor_agent.quick_edit.stream")

local M = {}

function M.quick_edit_anchor_editor()
  local win = api.nvim_get_current_win()
  if not util.is_valid_win(win) then
    return nil
  end
  local pos = api.nvim_win_get_position(win)
  local cur = api.nvim_win_get_cursor(win)
  if not pos or not cur then
    return nil
  end
  return { row = pos[1] + cur[1] - 1, col = pos[2] + cur[2] - 1 }
end

function M.close_quick_popover()
  stream.clear_quick_spinner()

  local quick_state = config.get_quick_state()
  if quick_state.job_id and quick_state.job_id > 0 then
    pcall(fn.jobstop, quick_state.job_id)
    quick_state.job_id = nil
  end
  stream.stop_redraw_timer()
  stream.stop_content_spinner()

  if quick_state.augroup then
    pcall(api.nvim_del_augroup_by_id, quick_state.augroup)
    quick_state.augroup = nil
  end

  if quick_state.win and util.is_valid_win(quick_state.win) then
    pcall(api.nvim_win_close, quick_state.win, true)
  end
  quick_state.win = nil

  if quick_state.buf and util.is_valid_buf(quick_state.buf) then
    pcall(api.nvim_buf_delete, quick_state.buf, { force = true })
  end
  quick_state.buf = nil

  if quick_state.prev_win and util.is_valid_win(quick_state.prev_win) then
    pcall(api.nvim_set_current_win, quick_state.prev_win)
  end
  quick_state.prev_win = nil
  quick_state.anchor_editor = nil

  quick_state.stream_buffer = ""
  quick_state.stream_visible = ""
  quick_state.stream_thinking = ""
  quick_state.stream_phase = "loading"
  quick_state.stream_complete = false
  quick_state.stream_stderr = {}
  quick_state.stream_exit_code = nil
  quick_state.stream_filetype = "text"
  quick_state.tool_events = {}
  quick_state.tool_blocked_count = 0
end

function M.ensure_quick_buf()
  local quick_state = config.get_quick_state()
  if quick_state.buf and util.is_valid_buf(quick_state.buf) then
    return quick_state.buf
  end

  local buf = api.nvim_create_buf(false, true)
  quick_state.buf = buf

  api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  api.nvim_set_option_value("swapfile", false, { buf = buf })
  api.nvim_set_option_value("modifiable", false, { buf = buf })

  vim.keymap.set("n", "<Esc>", M.close_quick_popover, {
    buffer = buf,
    silent = true,
    desc = "Close Cursor Agent Quick Edit popover",
  })
  vim.keymap.set("n", "q", M.close_quick_popover, {
    buffer = buf,
    silent = true,
    desc = "Close Cursor Agent Quick Edit popover",
  })

  return buf
end

function M.attach_popover_close_autocmds_after_delay(delay_ms)
  delay_ms = delay_ms or 400
  vim.defer_fn(function()
    local quick_state = config.get_quick_state()
    if not quick_state.win or not util.is_valid_win(quick_state.win) then
      return
    end
    if not quick_state.augroup or not quick_state.buf then
      return
    end
    api.nvim_create_autocmd("BufLeave", {
      group = quick_state.augroup,
      buffer = quick_state.buf,
      callback = function()
        vim.schedule(M.close_quick_popover)
      end,
      once = true,
    })
  end, delay_ms)
end

local function apply_popover_win_opts(win)
  api.nvim_set_option_value("winhighlight", "Normal:NormalFloat,FloatBorder:FloatBorder", { win = win })
  api.nvim_set_option_value("wrap", true, { win = win })
  api.nvim_set_option_value("cursorline", false, { win = win })
  api.nvim_set_option_value("signcolumn", "no", { win = win })
  api.nvim_set_option_value("number", false, { win = win })
  api.nvim_set_option_value("relativenumber", false, { win = win })
end

function M.open_quick_popover(lines, filetype)
  local quick_state = config.get_quick_state()
  local buf = M.ensure_quick_buf()

  lines = lines or { "Processing Quick Edit..." }
  filetype = filetype or "text"

  api.nvim_set_option_value("modifiable", true, { buf = buf })
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  api.nvim_set_option_value("modifiable", false, { buf = buf })
  api.nvim_set_option_value("filetype", filetype, { buf = buf })

  local max_width = math.max(20, math.floor(vim.o.columns * 0.5))
  local max_height = math.max(5, math.floor(vim.o.lines * 0.4))

  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 2, max_width)
  local height = math.min(#lines, max_height)

  local anchor = quick_state.anchor_editor or M.quick_edit_anchor_editor()
  if anchor then
    quick_state.anchor_editor = anchor
  end
  local win_config = {
    relative = "editor",
    row = (anchor and anchor.row) or 1,
    col = (anchor and anchor.col) or 1,
    width = math.max(20, width),
    height = math.max(1, height),
    style = "minimal",
    border = "rounded",
    zindex = 80,
  }

  if quick_state.win and util.is_valid_win(quick_state.win) then
    pcall(api.nvim_win_set_config, quick_state.win, win_config)
    api.nvim_win_set_buf(quick_state.win, buf)
    api.nvim_set_current_win(quick_state.win)
  else
    quick_state.prev_win = api.nvim_get_current_win()
    if not quick_state.anchor_editor then
      quick_state.anchor_editor = M.quick_edit_anchor_editor()
    end
    win_config.row = quick_state.anchor_editor and quick_state.anchor_editor.row or 1
    win_config.col = quick_state.anchor_editor and quick_state.anchor_editor.col or 1
    quick_state.win = api.nvim_open_win(buf, true, win_config)
  end

  apply_popover_win_opts(quick_state.win)

  if quick_state.augroup then
    pcall(api.nvim_del_augroup_by_id, quick_state.augroup)
  end
  quick_state.augroup = api.nvim_create_augroup("CursorAgentQuickEditPopover", { clear = true })
  M.attach_popover_close_autocmds_after_delay(400)
end

function M.open_quick_popover_streaming(filetype, mode)
  local quick_state = config.get_quick_state()
  local buf = M.ensure_quick_buf()

  quick_state.mode = mode or "edit"
  quick_state.stream_filetype = filetype or "text"
  quick_state.stream_visible = ""
  quick_state.stream_thinking = ""
  quick_state.stream_phase = "loading"
  quick_state.stream_complete = false
  quick_state.stream_stderr = {}
  quick_state.stream_exit_code = nil
  quick_state.tool_events = {}
  quick_state.tool_blocked_count = 0
  quick_state.spinner_frame = 1
  stream.stop_content_spinner()

  api.nvim_set_option_value("filetype", quick_state.stream_filetype, { buf = buf })
  api.nvim_set_option_value("modifiable", true, { buf = buf })
  api.nvim_buf_set_lines(buf, 0, -1, false, { "Processing Quick Edit..." })
  api.nvim_set_option_value("modifiable", false, { buf = buf })

  if not quick_state.anchor_editor then
    quick_state.anchor_editor = M.quick_edit_anchor_editor()
  end
  local anchor = quick_state.anchor_editor
  local win_config = {
    relative = "editor",
    row = anchor and anchor.row or 1,
    col = anchor and anchor.col or 1,
    width = 36,
    height = 3,
    style = "minimal",
    border = "rounded",
    zindex = 80,
  }

  if quick_state.win and util.is_valid_win(quick_state.win) then
    pcall(api.nvim_win_set_config, quick_state.win, win_config)
    api.nvim_win_set_buf(quick_state.win, buf)
    api.nvim_set_current_win(quick_state.win)
  else
    quick_state.prev_win = api.nvim_get_current_win()
    quick_state.win = api.nvim_open_win(buf, true, win_config)
  end

  apply_popover_win_opts(quick_state.win)

  if quick_state.augroup then
    pcall(api.nvim_del_augroup_by_id, quick_state.augroup)
  end
  quick_state.augroup = api.nvim_create_augroup("CursorAgentQuickEditPopover", { clear = true })
  M.attach_popover_close_autocmds_after_delay(400)
end

return M
