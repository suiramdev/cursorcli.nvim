local api = vim.api
local fn = vim.fn
local uv = vim.uv or vim.loop

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

local function notify(message, level)
  if not state.opts or not state.opts.notify then return end
  vim.schedule(function() vim.notify(message, level or vim.log.levels.INFO, { title = "Cursor Agent" }) end)
end

local function is_valid_buf(bufnr) return type(bufnr) == "number" and bufnr > 0 and api.nvim_buf_is_valid(bufnr) end

local function is_valid_win(winnr) return type(winnr) == "number" and winnr > 0 and api.nvim_win_is_valid(winnr) end

local function is_job_running()
  if type(state.job_id) ~= "number" or state.job_id <= 0 then return false end

  local ok, result = pcall(fn.jobwait, { state.job_id }, 0)
  if not ok or not result or result[1] ~= -1 then
    state.job_id = nil
    return false
  end
  return true
end

local function resolve_size(value, total, fallback)
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

local function build_float_config()
  local editor_width = math.max(1, vim.o.columns)
  local editor_height = math.max(1, vim.o.lines - vim.o.cmdheight)

  local width = resolve_size(state.opts.float.width, editor_width, math.floor(editor_width * 0.9))
  local height = resolve_size(state.opts.float.height, editor_height, math.floor(editor_height * 0.8))

  local row = math.max(0, math.floor((editor_height - height) / 2))
  local col = math.max(0, math.floor((editor_width - width) / 2))

  return {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = state.opts.float.border,
    title = state.opts.float.title,
    title_pos = state.opts.float.title_pos,
    zindex = state.opts.float.zindex,
  }
end

local function apply_window_style()
  if not is_valid_win(state.win) then return end

  if state.opts.float.winhighlight and state.opts.float.winhighlight ~= "" then
    api.nvim_set_option_value("winhighlight", state.opts.float.winhighlight, { win = state.win })
  end

  api.nvim_set_option_value("winblend", state.opts.float.winblend or 0, { win = state.win })
  api.nvim_set_option_value("number", false, { win = state.win })
  api.nvim_set_option_value("relativenumber", false, { win = state.win })
  api.nvim_set_option_value("signcolumn", "no", { win = state.win })
end

local function open_window()
  if not is_valid_buf(state.buf) then return false end

  if is_valid_win(state.win) then
    local current_tab = api.nvim_get_current_tabpage()
    if api.nvim_win_get_tabpage(state.win) ~= current_tab then
      state.win = nil
    else
      if api.nvim_win_get_buf(state.win) ~= state.buf then api.nvim_win_set_buf(state.win, state.buf) end
      api.nvim_set_current_win(state.win)
      apply_window_style()
      return true
    end
  end

  state.win = api.nvim_open_win(state.buf, true, build_float_config())
  apply_window_style()
  return true
end

local function close_window()
  if not is_valid_win(state.win) then
    state.win = nil
    return
  end
  pcall(api.nvim_win_close, state.win, true)
  state.win = nil
end

local function delete_buffer()
  if not is_valid_buf(state.buf) then
    state.buf = nil
    return
  end
  pcall(api.nvim_buf_delete, state.buf, { force = true })
  state.buf = nil
end

local function executable_for_command(command)
  if type(command) == "table" then return command[1] end
  if type(command) == "string" then return command:match("^%s*(%S+)") end
  return nil
end

local function ensure_command_is_available()
  local executable = executable_for_command(state.opts.command)
  if not executable or executable == "" then
    notify("Invalid command. Set `command` to `agent` or a valid command table.", vim.log.levels.ERROR)
    return false
  end

  if fn.executable(executable) ~= 1 then
    notify(("Command `%s` is not executable or not in PATH."):format(executable), vim.log.levels.ERROR)
    return false
  end

  return true
end

local function configure_terminal_buffer(bufnr)
  api.nvim_set_option_value("bufhidden", "hide", { buf = bufnr })
  api.nvim_set_option_value("swapfile", false, { buf = bufnr })

  vim.keymap.set("n", "q", function() M.close() end, {
    buffer = bufnr,
    silent = true,
    desc = "Close Cursor Agent window",
  })

  vim.keymap.set("t", "<Esc><Esc>", [[<C-\><C-n>]], {
    buffer = bufnr,
    silent = true,
    desc = "Exit terminal mode",
  })

  vim.keymap.set("n", "<Esc>", function() M.close() end, {
    buffer = bufnr,
    silent = true,
    desc = "Close Cursor Agent window",
  })
end

local function start_agent_session(resume_last, extra_args)
  if not ensure_command_is_available() then return false end

  if is_valid_buf(state.buf) then delete_buffer() end

  state.buf = api.nvim_create_buf(false, false)
  configure_terminal_buffer(state.buf)

  if not open_window() then
    notify("Unable to open Cursor Agent terminal window.", vim.log.levels.ERROR)
    return false
  end

  local cwd = uv.cwd()
  local cmd = state.opts.command
  cmd = type(cmd) == "table" and vim.tbl_extend("force", {}, cmd) or { tostring(cmd) }
  if resume_last then
    table.insert(cmd, "--continue")
  elseif extra_args and #extra_args > 0 then
    for _, a in ipairs(extra_args) do
      table.insert(cmd, a)
    end
  end

  local job_id = api.nvim_buf_call(state.buf, function()
    return fn.termopen(cmd, {
      cwd = cwd,
      on_exit = function(_, code)
        vim.schedule(function()
          state.job_id = nil
          if code ~= 0 then
            notify(("Cursor Agent exited with code %d"):format(code), vim.log.levels.WARN)
          else
            notify("Cursor Agent exited.", vim.log.levels.INFO)
          end
        end)
      end,
    })
  end)

  if type(job_id) ~= "number" or job_id <= 0 then
    notify("Failed to start Cursor Agent terminal job.", vim.log.levels.ERROR)
    return false
  end

  state.job_id = job_id
  return true
end

--- Show existing session window, or start a new one if none. (resume_last / extra_args for resume/ls.)
local function ensure_session(resume_last, extra_args)
  local reuse = not resume_last and not (extra_args and #extra_args > 0)
  if reuse and is_job_running() and is_valid_buf(state.buf) then
    return open_window()
  end
  return start_agent_session(resume_last, extra_args)
end

local function normalize_path(path)
  local absolute = fn.fnamemodify(path, ":p")
  local normalized = state.opts.path.relative_to_cwd and fn.fnamemodify(absolute, ":.") or absolute
  return normalized:gsub(" ", "\\ ")
end

local function create_reference(bufnr, line_start, line_end)
  local path = api.nvim_buf_get_name(bufnr)
  if path == "" then
    notify("Current buffer has no file path. Save the file first.", vim.log.levels.WARN)
    return nil
  end

  local first = math.min(line_start, line_end)
  local last = math.max(line_start, line_end)
  local normalized = normalize_path(path)

  return ("@%s:%d-%d"):format(normalized, first, last)
end

local function send_to_agent(text)
  if not is_job_running() then
    notify("Cursor Agent is not running.", vim.log.levels.ERROR)
    return false
  end

  local sent = fn.chansend(state.job_id, text)
  if type(sent) ~= "number" or sent <= 0 then
    notify("Failed sending text to Cursor Agent.", vim.log.levels.ERROR)
    return false
  end

  return true
end

local function setup_autocmds()
  state.augroup = api.nvim_create_augroup("CursorAgentIntegration", { clear = true })

  api.nvim_create_autocmd("VimResized", {
    group = state.augroup,
    callback = function()
      if is_valid_win(state.win) then pcall(api.nvim_win_set_config, state.win, build_float_config()) end
    end,
  })

  api.nvim_create_autocmd("TermClose", {
    group = state.augroup,
    callback = function(args)
      if args.buf == state.buf then state.job_id = nil end
    end,
  })

  api.nvim_create_autocmd("WinClosed", {
    group = state.augroup,
    callback = function(args)
      local closed = tonumber(args.match)
      if closed and state.win == closed then state.win = nil end
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

local function setup_commands()
  local command_names = {
    "CursorAgentOpen",
    "CursorAgentClose",
    "CursorAgentToggle",
    "CursorAgentRestart",
    "CursorAgentResume",
    "CursorAgentListSessions",
    "CursorAgentAddSelection",
    "CursorAgentFixErrorAtCursor",
    "CursorAgentFixErrorAtCursorInNewSession",
    "CursorAgentAddVisualSelectionToNewSession",
  }

  for _, name in ipairs(command_names) do
    pcall(api.nvim_del_user_command, name)
  end

  api.nvim_create_user_command("CursorAgentOpen", function() M.open() end, { desc = "Open Cursor Agent terminal" })
  api.nvim_create_user_command("CursorAgentClose", function() M.close() end, { desc = "Close Cursor Agent terminal" })
  api.nvim_create_user_command("CursorAgentToggle", function() M.toggle() end, { desc = "Toggle Cursor Agent terminal" })
  api.nvim_create_user_command("CursorAgentRestart", function() M.restart() end, { desc = "Restart Cursor Agent terminal" })
  api.nvim_create_user_command("CursorAgentResume", function() M.resume() end, { desc = "Resume last Cursor Agent chat session" })
  api.nvim_create_user_command("CursorAgentListSessions", function() M.list_sessions() end, {
    desc = "List Cursor Agent sessions (interactive CLI)",
  })

  api.nvim_create_user_command("CursorAgentAddSelection", function(command_opts)
    M.add_selection(command_opts.line1, command_opts.line2)
  end, {
    range = true,
    desc = "Add @file:start-end reference to Cursor Agent chat",
  })
  api.nvim_create_user_command("CursorAgentFixErrorAtCursor", function()
    M.request_fix_error_at_cursor()
  end, {
    desc = "Send error at cursor to Cursor Agent and ask to fix it",
  })
  api.nvim_create_user_command("CursorAgentFixErrorAtCursorInNewSession", function()
    M.request_fix_error_at_cursor_in_new_session()
  end, {
    desc = "Start new session and send error at cursor to Cursor Agent",
  })
  api.nvim_create_user_command("CursorAgentAddVisualSelectionToNewSession", function()
    M.add_visual_selection_to_new_session()
  end, {
    desc = "Start new session and send visual selection (code + @file ref) to Cursor Agent",
  })
end

function M.setup(opts)
  if state.setup_done then
    if opts then state.opts = vim.tbl_deep_extend("force", state.opts, opts) end
    return M
  end

  state.opts = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

  setup_autocmds()
  setup_commands()

  state.setup_done = true
  return M
end

--- Open the agent: show existing session or create a new one if none.
function M.open()
  if not state.setup_done then M.setup() end
  if not ensure_session() then return false end
  if state.opts.auto_insert then vim.schedule(function() vim.cmd.startinsert() end) end
  return true
end

function M.close()
  close_window()
  return true
end

--- Toggle the agent window: open (or create session if none) when closed, close when open.
function M.toggle()
  if not state.setup_done then M.setup() end
  if is_valid_win(state.win) then
    M.close()
    return true
  end
  return M.open()
end

function M.resume()
  if not state.setup_done then M.setup() end
  if not ensure_session(true) then return false end
  if state.opts.auto_insert then vim.schedule(function() vim.cmd.startinsert() end) end
  return true
end

function M.list_sessions()
  if not state.setup_done then M.setup() end
  if not ensure_session(false, { "ls" }) then return false end
  if state.opts.auto_insert then vim.schedule(function() vim.cmd.startinsert() end) end
  return true
end

function M.restart()
  if not state.setup_done then M.setup() end

  if is_job_running() then pcall(fn.jobstop, state.job_id) end
  state.job_id = nil

  delete_buffer()
  return M.open()
end

function M.add_selection(line_start, line_end, bufnr)
  if not state.setup_done then M.setup() end

  local target_buf = bufnr or api.nvim_get_current_buf()
  local first = tonumber(line_start)
  local last = tonumber(line_end)

  if not first or not last then
    local line = api.nvim_win_get_cursor(0)[1]
    first = line
    last = line
  end

  local reference = create_reference(target_buf, first, last)
  if not reference then return false end

  if not M.open() then return false end
  if not send_to_agent(reference .. " ") then return false end

  notify(("Added reference: %s"):format(reference), vim.log.levels.INFO)
  return true
end

function M.add_visual_selection()
  local start_pos = fn.getpos "'<"
  local end_pos = fn.getpos "'>"

  if not start_pos or not end_pos or start_pos[2] == 0 or end_pos[2] == 0 then
    notify("No visual selection found.", vim.log.levels.WARN)
    return false
  end

  return M.add_selection(start_pos[2], end_pos[2], api.nvim_get_current_buf())
end

--- Build the "fix error at cursor" message (error in ``` block + @file:start-end).
--- Returns message string or nil if no diagnostic at cursor.
local function build_fix_error_message_at_cursor()
  local bufnr = api.nvim_get_current_buf()
  local line = api.nvim_win_get_cursor(0)[1]
  local diagnostics = vim.diagnostic.get(bufnr, { lnum = line - 1 })
  if not diagnostics or #diagnostics == 0 then return nil end

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
  local reference = create_reference(bufnr, line_start, line_end)
  if not reference then return nil end
  return ("Please fix the following error:\n\n```\n%s\n```\n\n%s"):format(error_text, reference)
end

--- Send a message asking the agent to fix the error at the cursor, with the
--- error text in a code block and @file:start-end for the error location.
function M.request_fix_error_at_cursor()
  if not state.setup_done then M.setup() end
  local message = build_fix_error_message_at_cursor()
  if not message then
    notify("No diagnostic/error at cursor position.", vim.log.levels.WARN)
    return false
  end
  if not M.open() then return false end
  if not send_to_agent(message .. "\n") then return false end
  notify("Sent fix-error request to Cursor Agent.", vim.log.levels.INFO)
  return true
end

--- Start a new agent session and send the "fix error at cursor" message.
function M.request_fix_error_at_cursor_in_new_session()
  if not state.setup_done then M.setup() end
  local message = build_fix_error_message_at_cursor()
  if not message then
    notify("No diagnostic/error at cursor position.", vim.log.levels.WARN)
    return false
  end
  if not M.restart() then return false end
  if not send_to_agent(message .. "\n") then return false end
  notify("Sent fix-error request to new Cursor Agent session.", vim.log.levels.INFO)
  return true
end

--- Start a new agent session and send the visual selection as highlighted code
--- (code in ``` block + @file:start-end).
function M.add_visual_selection_to_new_session()
  if not state.setup_done then M.setup() end
  local start_pos = fn.getpos "'<"
  local end_pos = fn.getpos "'>"
  if not start_pos or not end_pos or start_pos[2] == 0 or end_pos[2] == 0 then
    notify("No visual selection found.", vim.log.levels.WARN)
    return false
  end
  local bufnr = api.nvim_get_current_buf()
  local reference = create_reference(bufnr, start_pos[2], end_pos[2])
  if not reference then return false end
  local start_row = start_pos[2] - 1
  local start_col = start_pos[3] - 1
  local end_row = end_pos[2] - 1
  local end_col = end_pos[3]
  local lines = api.nvim_buf_get_text(bufnr, start_row, start_col, end_row, end_col, {})
  local code_text = table.concat(lines, "\n")
  local message = ("Consider this code:\n\n```\n%s\n```\n\n%s"):format(code_text, reference)
  if not M.restart() then return false end
  if not send_to_agent(message .. "\n") then return false end
  notify("Sent selection to new Cursor Agent session.", vim.log.levels.INFO)
  return true
end

function M.is_running() return is_job_running() end

return M

