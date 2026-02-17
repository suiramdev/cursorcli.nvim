local M = {}

local defaults = {
  command = { "agent" },
  auto_insert = true,
  notify = true,
  path = {
    relative_to_cwd = true,
  },
  float = {
    width = 0.9,
    height = 0.8,
    border = "rounded",
    title = " Cursor Agent ",
    title_pos = "center",
    zindex = 60,
    winblend = 0,
    winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder,FloatTitle:FloatTitle",
  },
}

local state = {
  setup_done = false,
  opts = nil,
  buf = nil,
  win = nil,
  job_id = nil,
  augroup = nil,
}

local quick_state = {
  buf = nil,
  win = nil,
  job_id = nil,
  spinner_timer = nil,
  augroup = nil,
  stream_buffer = "",
  stream_visible = "",
  stream_thinking = "",
  stream_phase = "loading",
  stream_complete = false,
  stream_stderr = {},
  stream_exit_code = nil,
  redraw_timer = nil,
  redraw_interval_ms = 80,
  content_spinner_timer = nil,
  spinner_frame = 1,
  stream_filetype = "text",
  mode = "edit",
  tool_events = {},
  tool_blocked_count = 0,
  prev_win = nil,
  anchor_editor = nil,
}

function M.defaults()
  return vim.deepcopy(defaults)
end

function M.get_state()
  return state
end

function M.get_quick_state()
  return quick_state
end

function M.opts()
  return state.opts
end

function M.set_opts(opts)
  state.opts = opts
end

function M.merge_opts(user_opts)
  state.opts = vim.tbl_deep_extend("force", vim.deepcopy(defaults), user_opts or {})
end

function M.set_setup_done(done)
  state.setup_done = done
end

function M.setup_done()
  return state.setup_done
end

return M
