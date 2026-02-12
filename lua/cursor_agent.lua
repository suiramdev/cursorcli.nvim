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

-- Separate state for the Quick Edit popover + async job (streaming)
local quick_state = {
  buf = nil,
  win = nil,
  job_id = nil,
  spinner_timer = nil,
  augroup = nil,
  -- Streaming: line buffer, visible text, thinking (gray), completion, throttle
  stream_buffer = "",
  stream_visible = "",
  stream_thinking = "",
  stream_phase = "loading", -- loading -> thinking -> result
  stream_complete = false,
  stream_stderr = {},
  stream_exit_code = nil,
  redraw_timer = nil,
  redraw_interval_ms = 80,
  content_spinner_timer = nil,
  spinner_frame = 1,
  stream_filetype = "text",
  -- Edit vs Ask: "edit" = tools enabled (--approve-mcps), "ask" = read-only
  mode = "edit",
  -- Tool activity (Edit mode): call_id -> { path, completed = { path, linesAdded, linesRemoved, diffString, message } }
  tool_events = {},
  -- Ask mode: count of tool_call events seen (blocked/ignored)
  tool_blocked_count = 0,
  -- Window to restore focus to when closing the popover (Esc / q)
  prev_win = nil,
  -- Fixed editor position for the popover (stops it moving when cursor is inside)
  anchor_editor = nil,
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

-- Quick Edit helpers ---------------------------------------------------------

local function clear_quick_spinner()
  if quick_state.spinner_timer then
    pcall(quick_state.spinner_timer.stop, quick_state.spinner_timer)
    pcall(quick_state.spinner_timer.close, quick_state.spinner_timer)
    quick_state.spinner_timer = nil
  end
end

local function close_quick_popover()
  clear_quick_spinner()

  -- Cancel running Quick Edit job (streaming cancellation)
  if quick_state.job_id and quick_state.job_id > 0 then
    pcall(fn.jobstop, quick_state.job_id)
    quick_state.job_id = nil
  end
  if quick_state.redraw_timer then
    pcall(quick_state.redraw_timer.stop, quick_state.redraw_timer)
    pcall(quick_state.redraw_timer.close, quick_state.redraw_timer)
    quick_state.redraw_timer = nil
  end
  if quick_state.content_spinner_timer then
    pcall(quick_state.content_spinner_timer.stop, quick_state.content_spinner_timer)
    pcall(quick_state.content_spinner_timer.close, quick_state.content_spinner_timer)
    quick_state.content_spinner_timer = nil
  end

  if quick_state.augroup then
    pcall(api.nvim_del_augroup_by_id, quick_state.augroup)
    quick_state.augroup = nil
  end

  if quick_state.win and is_valid_win(quick_state.win) then
    pcall(api.nvim_win_close, quick_state.win, true)
  end
  quick_state.win = nil

  if quick_state.buf and is_valid_buf(quick_state.buf) then
    pcall(api.nvim_buf_delete, quick_state.buf, { force = true })
  end
  quick_state.buf = nil

  -- Restore focus to the window the user was in before opening the popover
  if quick_state.prev_win and is_valid_win(quick_state.prev_win) then
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

-- Capture current window's cursor position in editor coordinates (for fixed popover anchor).
local function quick_edit_anchor_editor()
  local win = api.nvim_get_current_win()
  if not is_valid_win(win) then return nil end
  local pos = api.nvim_win_get_position(win)
  local cur = api.nvim_win_get_cursor(win)
  if not pos or not cur then return nil end
  -- Editor grid is 0-based; cursor (line, col) is 1-based.
  return { row = pos[1] + cur[1] - 1, col = pos[2] + cur[2] - 1 }
end

local function ensure_quick_buf()
  if quick_state.buf and is_valid_buf(quick_state.buf) then return quick_state.buf end

  local buf = api.nvim_create_buf(false, true)
  quick_state.buf = buf

  api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  api.nvim_set_option_value("swapfile", false, { buf = buf })
  api.nvim_set_option_value("modifiable", false, { buf = buf })

  vim.keymap.set("n", "<Esc>", close_quick_popover, {
    buffer = buf,
    silent = true,
    desc = "Close Cursor Agent Quick Edit popover",
  })
  vim.keymap.set("n", "q", close_quick_popover, {
    buffer = buf,
    silent = true,
    desc = "Close Cursor Agent Quick Edit popover",
  })

  return buf
end

local function open_quick_popover(lines, filetype)
  local buf = ensure_quick_buf()

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

  local anchor = quick_state.anchor_editor or quick_edit_anchor_editor()
  if anchor then quick_state.anchor_editor = anchor end
  local config = {
    relative = "editor",
    row = (anchor and anchor.row) or 1,
    col = (anchor and anchor.col) or 1,
    width = math.max(20, width),
    height = math.max(1, height),
    style = "minimal",
    border = "rounded",
    zindex = 80,
  }

  if quick_state.win and is_valid_win(quick_state.win) then
    pcall(api.nvim_win_set_config, quick_state.win, config)
    api.nvim_win_set_buf(quick_state.win, buf)
    api.nvim_set_current_win(quick_state.win)
  else
    quick_state.prev_win = api.nvim_get_current_win()
    if not quick_state.anchor_editor then quick_state.anchor_editor = quick_edit_anchor_editor() end
    config.row = quick_state.anchor_editor and quick_state.anchor_editor.row or 1
    config.col = quick_state.anchor_editor and quick_state.anchor_editor.col or 1
    quick_state.win = api.nvim_open_win(buf, true, config)
  end

  api.nvim_set_option_value(
    "winhighlight",
    "Normal:NormalFloat,FloatBorder:FloatBorder",
    { win = quick_state.win }
  )
  api.nvim_set_option_value("wrap", true, { win = quick_state.win })
  api.nvim_set_option_value("cursorline", false, { win = quick_state.win })
  api.nvim_set_option_value("signcolumn", "no", { win = quick_state.win })
  api.nvim_set_option_value("number", false, { win = quick_state.win })
  api.nvim_set_option_value("relativenumber", false, { win = quick_state.win })

  if quick_state.augroup then
    pcall(api.nvim_del_augroup_by_id, quick_state.augroup)
  end
  quick_state.augroup = api.nvim_create_augroup("CursorAgentQuickEditPopover", { clear = true })
  attach_popover_close_autocmds_after_delay(400)
end

-- Attach close-on-cursor/mode autocmds after a short delay so the popover isn't
-- closed by the first events fired when the input prompt dismisses.
local function attach_popover_close_autocmds_after_delay(delay_ms)
  delay_ms = delay_ms or 400
  vim.defer_fn(function()
    if not quick_state.win or not is_valid_win(quick_state.win) then return end
    if not quick_state.augroup or not quick_state.buf then return end
    -- Close when user leaves the popover buffer (e.g. switches window); does not fire when navigating inside
    api.nvim_create_autocmd("BufLeave", {
      group = quick_state.augroup,
      buffer = quick_state.buf,
      callback = function()
        vim.schedule(close_quick_popover)
      end,
      once = true,
    })
  end, delay_ms)
end

-- Stream reader: take first complete line from buffer (by newline); return line and rest.
local function stream_take_line(buf, flush_remainder)
  local i = buf:find("\n")
  if i then
    local line = buf:sub(1, i - 1):gsub("\r$", "")
    return line, buf:sub(i + 1)
  end
  if flush_remainder and buf ~= "" then
    return buf:gsub("\r$", ""), ""
  end
  return nil, buf
end

-- Extract first complete JSON object from buffer (brace-matching). Handles concatenated
-- objects with no newline (e.g. {"type":"system",...}{"type":"user",...}).
-- Returns (object_string, rest) or (nil, buf) if no complete object.
local function stream_take_json_object(buf)
  buf = buf:gsub("^%s+", "")
  local start = buf:find("{")
  if not start then return nil, buf end
  local depth = 0
  local in_string = false
  local escape = false
  local quote = nil
  for i = start, #buf do
    local c = buf:sub(i, i)
    if escape then
      escape = false
    elseif c == "\\" and in_string then
      escape = true
    elseif in_string then
      if c == quote then in_string = false end
    elseif c == '"' or c == "'" then
      in_string = true
      quote = c
    elseif c == "{" then
      depth = depth + 1
    elseif c == "}" then
      depth = depth - 1
      if depth == 0 then
        return buf:sub(start, i), buf:sub(i + 1)
      end
    end
  end
  return nil, buf
end

-- JSON line parser: decode one line, return table or nil (ignore malformed).
local function stream_parse_line(line)
  if type(line) ~= "string" or line == "" then return nil end
  local ok, obj = pcall(vim.json.decode, line)
  if not ok or type(obj) ~= "table" then return nil end
  return obj
end

-- Event reducer: stream-json protocol (NDJSON from agent CLI).
-- Matches: agent <prompt> --output-format stream-json --print --stream-partial-output [--approve-mcps]
-- Returns (append_visible, append_thinking, is_stream_complete, tool_event).
-- tool_event: { type = "started"|"completed"|"blocked", call_id?, path?, ... } for tool_call; nil otherwise.
local function stream_reduce_event(obj)
  local t = obj.type
  local subtype = obj.subtype
  local nil_te = nil

  -- system — hidden
  if t == "system" then return nil, nil, false, nil_te end
  -- user — hidden
  if t == "user" then return nil, nil, false, nil_te end
  -- thinking: delta stream as gray; completed ignored
  if t == "thinking" then
    if subtype == "delta" and type(obj.text) == "string" and obj.text ~= "" then
      return nil, obj.text, false, nil_te
    end
    return nil, nil, false, nil_te
  end

  -- assistant: stream message.content[].text
  if t == "assistant" then
    local msg = obj.message
    if type(msg) == "table" and type(msg.content) == "table" then
      local out = {}
      for _, part in ipairs(msg.content) do
        if type(part) == "table" and part.type == "text" and type(part.text) == "string" then
          table.insert(out, part.text)
        end
      end
      if #out > 0 then return table.concat(out), nil, false, nil_te end
    end
    return nil, nil, false, nil_te
  end

  -- tool_call: Edit mode = surface; Ask mode = blocked/ignored
  if t == "tool_call" then
    local tc = obj.tool_call
    local call_id = obj.call_id
    if type(tc) == "table" and type(tc.editToolCall) == "table" then
      local etc = tc.editToolCall
      local args = type(etc.args) == "table" and etc.args or {}
      local path = args.path or ""

      if quick_state.mode == "ask" then
        quick_state.tool_blocked_count = (quick_state.tool_blocked_count or 0) + 1
        return nil, nil, false, { type = "blocked", path = path }
      end

      -- Edit mode
      if subtype == "started" then
        return nil, nil, false, { type = "started", call_id = call_id, path = path }
      end
      if subtype == "completed" then
        local res = etc.result
        if type(res) == "table" then
          if type(res.error) == "table" or (type(res.error) == "string" and res.error ~= "") then
            local errMsg = type(res.error) == "table" and (res.error.message or res.error.code or "Error") or res.error
            return nil, nil, false, {
              type = "completed",
              call_id = call_id,
              path = path,
              completed = { error = true, message = errMsg },
            }
          end
          if type(res.success) == "table" then
            local s = res.success
            local text = s.afterFullFileContent or s.diffString or s.message
            local append = (type(text) == "string" and text ~= "") and text or nil
            return append, nil, false, {
              type = "completed",
              call_id = call_id,
              path = s.path or path,
              linesAdded = s.linesAdded,
              linesRemoved = s.linesRemoved,
              diffString = s.diffString,
              message = s.message,
            }
          end
        end
      end
    end
    return nil, nil, false, nil_te
  end

  -- result: terminal event
  if t == "result" then
    local text = obj.result
    if type(text) == "string" and text ~= "" then
      return text, nil, true, nil_te
    end
    return nil, nil, true, nil_te
  end

  return nil, nil, false, nil_te
end

-- Throttled UI renderer: tool panel + thinking + body.
local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local QUICK_EDIT_THINKING_HL = "CursorAgentQuickEditThinking"
local QUICK_EDIT_TOOL_HL = "CursorAgentQuickEditTool"

local function stream_do_redraw()
  if not quick_state.buf or not is_valid_buf(quick_state.buf) then return end

  local function text_to_lines(text)
    if type(text) ~= "string" or text == "" then return {} end
    local out = {}
    for s in (text .. "\n"):gmatch("(.-)\n") do
      table.insert(out, s)
    end
    return out
  end

  local mode = quick_state.mode or "edit"
  local lines = {}
  local spinner_frame = SPINNER_FRAMES[quick_state.spinner_frame or 1]

  -- Tool activity panel (Edit: started/completed/error; Ask: blocked count)
  local tool_lines = {}
  if mode == "ask" and (quick_state.tool_blocked_count or 0) > 0 then
    tool_lines = { ("[Tool calls ignored in Ask mode: %d]"):format(quick_state.tool_blocked_count) }
  elseif mode == "edit" and quick_state.tool_events and #quick_state.tool_events > 0 then
    for _, ev in ipairs(quick_state.tool_events) do
      local name = (ev.path and ev.path:match("([^/]+)$")) or ev.path or "file"
      if ev.completed then
        local c = ev.completed
        if c.error then
          local msg = (type(c.message) == "string" and c.message ~= "") and c.message or "Error"
          tool_lines[#tool_lines + 1] = ("✗ editToolCall: %s — %s"):format(name, msg)
        else
          local add = c.linesAdded or 0
          local rem = c.linesRemoved or 0
          local summary = c.message or ("+%d -%d"):format(add, rem)
          local diff = c.diffString and c.diffString:sub(1, 60)
          if diff and #(c.diffString or "") > 60 then diff = diff .. "…" end
          tool_lines[#tool_lines + 1] = ("✓ editToolCall: %s — %s"):format(name, summary)
          if diff and diff ~= "" then tool_lines[#tool_lines + 1] = "  " .. diff end
        end
      else
        tool_lines[#tool_lines + 1] = ("%s editToolCall started: %s"):format(spinner_frame, name)
      end
    end
  end
  if #tool_lines > 0 then
    table.insert(lines, "--- Tool activity ---")
    for _, l in ipairs(tool_lines) do
      table.insert(lines, l)
    end
    table.insert(lines, "")
  end

  local thinking_lines = text_to_lines(quick_state.stream_thinking)
  local num_header = 0
  local num_tool = #tool_lines > 0 and (2 + #tool_lines) or 0
  local thinking_start_0 = num_header + num_tool

  if #thinking_lines > 0 then
    table.insert(lines, spinner_frame .. " Thinking")
    for _, l in ipairs(thinking_lines) do
      table.insert(lines, l)
    end
    table.insert(lines, "")
  end

  local visible_text = quick_state.stream_visible
  -- Normalize: trim leading/trailing newlines and collapse 3+ newlines to 2 (avoids extra blank lines)
  if visible_text ~= "" then
    visible_text = visible_text:gsub("^\n+", ""):gsub("\n+$", ""):gsub("\n\n\n+", "\n\n")
  end
  local visible_lines = {}
  if visible_text == "" then
    -- During thinking phase, show only thinking spinner/text (no extra processing placeholder).
    if quick_state.stream_phase ~= "thinking" or #thinking_lines == 0 then
      visible_text = "Processing..."
      visible_lines = text_to_lines(visible_text)
    end
  else
    visible_lines = text_to_lines(visible_text)
  end
  for _, l in ipairs(visible_lines) do
    table.insert(lines, l)
  end

  local num_thinking = #thinking_lines > 0 and (1 + #thinking_lines) or 0
  local thinking_end_0 = thinking_start_0 + num_thinking - 1

  -- nvim_buf_set_lines forbids newlines in any line; sanitize so each entry is one display line
  for i, l in ipairs(lines) do
    lines[i] = (l or ""):gsub("[\r\n]+", " ")
  end

  local max_width = math.max(20, math.floor(vim.o.columns * 0.5))
  local max_height = math.max(5, math.floor(vim.o.lines * 0.4))
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 2, max_width)
  local height = math.min(#lines, max_height)

  api.nvim_set_option_value("modifiable", true, { buf = quick_state.buf })
  api.nvim_buf_set_lines(quick_state.buf, 0, -1, false, lines)
  api.nvim_set_option_value("modifiable", false, { buf = quick_state.buf })

  -- Highlights: tool section, thinking region
  if not quick_state.thinking_ns then
    quick_state.thinking_ns = api.nvim_create_namespace("CursorAgentQuickEditThinking")
  end
  api.nvim_buf_clear_namespace(quick_state.buf, quick_state.thinking_ns, 0, -1)
  if num_tool > 0 then
    pcall(api.nvim_set_hl, 0, QUICK_EDIT_TOOL_HL, { ctermfg = 8, guifg = "#78716c" })
    for line = 0, num_tool - 1 do
      api.nvim_buf_add_highlight(quick_state.buf, quick_state.thinking_ns, QUICK_EDIT_TOOL_HL, line, 0, -1)
    end
  end
  if num_thinking > 0 then
    -- Gray text for thinking (explicit so theme does not override)
    pcall(api.nvim_set_hl, 0, QUICK_EDIT_THINKING_HL, { ctermfg = 246, guifg = "#9ca3af" })
    for line = thinking_start_0, thinking_end_0 do
      api.nvim_buf_add_highlight(quick_state.buf, quick_state.thinking_ns, QUICK_EDIT_THINKING_HL, line, 0, -1)
    end
  end

  if quick_state.win and is_valid_win(quick_state.win) then
    local anchor = quick_state.anchor_editor
    pcall(api.nvim_win_set_config, quick_state.win, {
      relative = "editor",
      row = anchor and anchor.row or 1,
      col = anchor and anchor.col or 1,
      width = math.max(20, width),
      height = math.max(1, height),
      style = "minimal",
      border = "rounded",
      zindex = 80,
    })
  end
end

local function stream_schedule_redraw()
  if quick_state.redraw_timer then return end
  quick_state.redraw_timer = uv.new_timer()
  quick_state.redraw_timer:start(
    quick_state.redraw_interval_ms,
    0,
    vim.schedule_wrap(function()
      if quick_state.redraw_timer then
        pcall(quick_state.redraw_timer.stop, quick_state.redraw_timer)
        pcall(quick_state.redraw_timer.close, quick_state.redraw_timer)
        quick_state.redraw_timer = nil
      end
      stream_do_redraw()
    end)
  )
end

-- Immediate redraw (e.g. on exit / error) so final state is always visible.
local function stream_redraw_now()
  if quick_state.redraw_timer then
    pcall(quick_state.redraw_timer.stop, quick_state.redraw_timer)
    pcall(quick_state.redraw_timer.close, quick_state.redraw_timer)
    quick_state.redraw_timer = nil
  end
  vim.schedule(stream_do_redraw)
end

local function stop_content_spinner()
  if quick_state.content_spinner_timer then
    pcall(quick_state.content_spinner_timer.stop, quick_state.content_spinner_timer)
    pcall(quick_state.content_spinner_timer.close, quick_state.content_spinner_timer)
    quick_state.content_spinner_timer = nil
  end
end

local function has_pending_tool_calls()
  if quick_state.mode ~= "edit" or not quick_state.tool_events then return false end
  for _, ev in ipairs(quick_state.tool_events) do
    if not ev.completed then return true end
  end
  return false
end

local function start_content_spinner()
  if quick_state.content_spinner_timer then return end
  quick_state.content_spinner_timer = uv.new_timer()
  quick_state.content_spinner_timer:start(
    0,
    80,
    vim.schedule_wrap(function()
      if not quick_state.buf or not is_valid_buf(quick_state.buf) then
        stop_content_spinner()
        return
      end
      local thinking_active = (quick_state.stream_thinking or "") ~= ""
      local pending_tools = has_pending_tool_calls()
      if not thinking_active and not pending_tools then
        stop_content_spinner()
        return
      end
      quick_state.spinner_frame = ((quick_state.spinner_frame or 1) % #SPINNER_FRAMES) + 1
      stream_do_redraw()
    end)
  )
end

-- Process one line (parse JSON, update stream_visible/stream_thinking/tool_events, maybe set complete).
local function stream_process_line(line)
  local function enter_result_phase()
    if quick_state.stream_phase == "result" then return end
    quick_state.stream_phase = "result"
    quick_state.stream_thinking = ""
    quick_state.tool_events = {}
    quick_state.tool_blocked_count = 0
    quick_state.stream_visible = ""
    stop_content_spinner()
    clear_quick_spinner()
  end

  local obj = stream_parse_line(line)
  if obj then
    local append_visible, append_thinking, done, tool_event = stream_reduce_event(obj)
    -- Stop loading spinner as soon as we have any content to show (avoids flicker)
    if (append_visible and #append_visible > 0) or (append_thinking and #append_thinking > 0) or (tool_event and tool_event.call_id) then
      clear_quick_spinner()
    end

    if append_thinking and #append_thinking > 0 and quick_state.stream_phase ~= "result" then
      if quick_state.stream_phase ~= "thinking" then
        -- Enter thinking phase: clear stale text from earlier phases.
        quick_state.stream_phase = "thinking"
        quick_state.stream_visible = ""
        quick_state.tool_events = {}
        quick_state.tool_blocked_count = 0
        quick_state.spinner_frame = 1
      end
      quick_state.stream_thinking = quick_state.stream_thinking .. append_thinking
      start_content_spinner()
      stream_schedule_redraw()
    end

    if append_visible and #append_visible > 0 then
      -- First visible output starts result phase: clear thinking/tool text and all spinners.
      enter_result_phase()
      if quick_state.stream_visible == "" then
        quick_state.stream_visible = append_visible
      elseif append_visible:sub(1, #quick_state.stream_visible) == quick_state.stream_visible then
        -- Some stream events contain cumulative snapshots; replace instead of append.
        quick_state.stream_visible = append_visible
      elseif #append_visible <= #quick_state.stream_visible
        and quick_state.stream_visible:sub(-#append_visible) == append_visible then
        -- Exact suffix already present; skip duplicate chunk.
      else
        quick_state.stream_visible = quick_state.stream_visible .. append_visible
      end
      stream_schedule_redraw()
    end

    if tool_event and quick_state.stream_phase ~= "result" then
      if tool_event.type == "blocked" then
        stream_schedule_redraw()
      elseif tool_event.call_id then
        quick_state.tool_events = quick_state.tool_events or {}
        if tool_event.type == "started" then
          table.insert(quick_state.tool_events, { call_id = tool_event.call_id, path = tool_event.path, completed = nil })
          start_content_spinner()
        elseif tool_event.type == "completed" then
          for _, ev in ipairs(quick_state.tool_events) do
            if ev.call_id == tool_event.call_id then
              ev.completed = tool_event.completed or {
                path = tool_event.path,
                linesAdded = tool_event.linesAdded,
                linesRemoved = tool_event.linesRemoved,
                diffString = tool_event.diffString,
                message = tool_event.message,
              }
              break
            end
          end
        end
        stream_schedule_redraw()
      end
    end
    if done then
      -- Final result: clear thinking and tool activity so only the result remains, and stop all spinners.
      quick_state.stream_phase = "result"
      quick_state.stream_thinking = ""
      quick_state.tool_events = {}
      quick_state.tool_blocked_count = 0
      stop_content_spinner()
      clear_quick_spinner()
      -- Replace any intermediate streamed content with the final result text if present
      if append_visible and #append_visible > 0 then
        quick_state.stream_visible = append_visible
      end
      quick_state.stream_complete = true
      stream_redraw_now()
    end
  else
    -- Partial JSON: if line looks like truncated JSON, don't treat as plain text (leave for next chunk)
    if line ~= "" and not (line:match("^%s*{") and not line:match("}%s*$")) then
      enter_result_phase()
      quick_state.stream_visible = quick_state.stream_visible .. line .. "\n"
      stream_schedule_redraw()
    end
  end
end

-- Process stream_buffer: extract complete JSON objects (by newline or brace-matching) and process each.
-- Handles concatenated objects with no newline (e.g. {"type":"system",...}{"type":"user",...}).
local function stream_process_buffer(flush_remaining)
  while true do
    -- 1) Prefer extracting a complete JSON object (handles no-newline concatenation)
    local obj_str, rest = stream_take_json_object(quick_state.stream_buffer)
    if obj_str then
      quick_state.stream_buffer = rest
      stream_process_line(obj_str)
      goto continue
    end
    -- 2) Take by newline
    local line, line_rest = stream_take_line(quick_state.stream_buffer, false)
    if not line then
      if flush_remaining and quick_state.stream_buffer ~= "" then
        -- Flush: try JSON object one more time, then try parse remainder
        obj_str, rest = stream_take_json_object(quick_state.stream_buffer)
        if obj_str then
          quick_state.stream_buffer = rest
          stream_process_line(obj_str)
          goto continue
        end
        line = quick_state.stream_buffer:gsub("\r$", "")
        quick_state.stream_buffer = ""
        if line ~= "" then
          stream_process_line(line)
        end
      end
      break
    end
    quick_state.stream_buffer = line_rest
    -- Line might be a single JSON object or multiple concatenated; try parse then try extract
    local obj = stream_parse_line(line)
    if obj then
      stream_process_line(line)
    else
      -- Try to pull complete JSON objects out of this line
      local remainder = line
      while true do
        obj_str, rest = stream_take_json_object(remainder)
        if not obj_str then break end
        stream_process_line(obj_str)
        remainder = rest
      end
      if remainder ~= "" then
        -- Truncated JSON (starts with { but no closing }): put back for next chunk
        if remainder:match("^%s*{") and not remainder:match("}%s*$") then
          quick_state.stream_buffer = remainder .. quick_state.stream_buffer
        else
          -- Garbage or complete non-JSON: route through line processor for phase handling.
          stream_process_line(remainder)
        end
      end
    end
    ::continue::
  end
end

-- Open popover for streaming: loading header, read-only, filetype; mode = "edit"|"ask".
local function open_quick_popover_streaming(filetype, mode)
  local buf = ensure_quick_buf()
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
  stop_content_spinner()

  api.nvim_set_option_value("filetype", quick_state.stream_filetype, { buf = buf })
  api.nvim_set_option_value("modifiable", true, { buf = buf })
  api.nvim_buf_set_lines(buf, 0, -1, false, { "Processing Quick Edit..." })
  api.nvim_set_option_value("modifiable", false, { buf = buf })

  if not quick_state.anchor_editor then quick_state.anchor_editor = quick_edit_anchor_editor() end
  local anchor = quick_state.anchor_editor
  local config = {
    relative = "editor",
    row = anchor and anchor.row or 1,
    col = anchor and anchor.col or 1,
    width = 36,
    height = 3,
    style = "minimal",
    border = "rounded",
    zindex = 80,
  }

  if quick_state.win and is_valid_win(quick_state.win) then
    pcall(api.nvim_win_set_config, quick_state.win, config)
    api.nvim_win_set_buf(quick_state.win, buf)
    api.nvim_set_current_win(quick_state.win)
  else
    quick_state.prev_win = api.nvim_get_current_win()
    quick_state.win = api.nvim_open_win(buf, true, config)
  end

  api.nvim_set_option_value(
    "winhighlight",
    "Normal:NormalFloat,FloatBorder:FloatBorder",
    { win = quick_state.win }
  )
  api.nvim_set_option_value("wrap", true, { win = quick_state.win })
  api.nvim_set_option_value("cursorline", false, { win = quick_state.win })
  api.nvim_set_option_value("signcolumn", "no", { win = quick_state.win })
  api.nvim_set_option_value("number", false, { win = quick_state.win })
  api.nvim_set_option_value("relativenumber", false, { win = quick_state.win })

  if quick_state.augroup then
    pcall(api.nvim_del_augroup_by_id, quick_state.augroup)
  end
  quick_state.augroup = api.nvim_create_augroup("CursorAgentQuickEditPopover", { clear = true })
  attach_popover_close_autocmds_after_delay(400)
end

local function start_quick_spinner()
  clear_quick_spinner()

  local index = 1

  quick_state.spinner_timer = uv.new_timer()
  quick_state.spinner_timer:start(
    0,
    80,
    vim.schedule_wrap(function()
      if not quick_state.buf or not is_valid_buf(quick_state.buf) or not quick_state.win or not is_valid_win(quick_state.win) then
        clear_quick_spinner()
        return
      end
      local frame = SPINNER_FRAMES[index]
      index = (index % #SPINNER_FRAMES) + 1

      api.nvim_set_option_value("modifiable", true, { buf = quick_state.buf })
      api.nvim_buf_set_lines(quick_state.buf, 0, -1, false, { frame .. " Processing Quick Edit..." })
      api.nvim_set_option_value("modifiable", false, { buf = quick_state.buf })
    end)
  )
end

local function capture_visual_selection()
  local start_pos = fn.getpos "'<"
  local end_pos = fn.getpos "'>"

  if not start_pos or not end_pos or start_pos[2] == 0 or end_pos[2] == 0 then
    notify("Quick Edit requires a visual selection.", vim.log.levels.WARN)
    return nil
  end

  local bufnr = api.nvim_get_current_buf()
  local vmode = fn.visualmode() or "v"

  local srow, scol = start_pos[2], start_pos[3]
  local erow, ecol = end_pos[2], end_pos[3]

  if srow > erow or (srow == erow and scol > ecol) then
    srow, erow = erow, srow
    scol, ecol = ecol, scol
  end

  local lines = {}
  local mode_normalized

  if vmode == "V" then
    mode_normalized = "line"
    lines = api.nvim_buf_get_lines(bufnr, srow - 1, erow, false)
  elseif vmode == "\022" then
    mode_normalized = "block"
    local start_col = math.min(scol, ecol) - 1
    local end_col = math.max(scol, ecol) - 1
    for row = srow - 1, erow - 1 do
      local text = api.nvim_buf_get_text(bufnr, row, start_col, row, end_col + 1, {})
      table.insert(lines, text[1] or "")
    end
  else
    mode_normalized = "char"
    local text = api.nvim_buf_get_text(bufnr, srow - 1, scol - 1, erow - 1, ecol, {})
    lines = text
  end

  if not lines or #lines == 0 then
    notify("Quick Edit: visual selection was empty.", vim.log.levels.WARN)
    return nil
  end

  return {
    bufnr = bufnr,
    mode = mode_normalized,
    start_row = srow,
    start_col = scol,
    end_row = erow,
    end_col = ecol,
    lines = lines,
    filetype = vim.bo[bufnr].filetype or "text",
  }
end

-- Input popup state (separate from preview so we can close it after submit)
local input_popup = { buf = nil, win = nil, augroup = nil }

local function close_quick_edit_input_popup()
  if input_popup.augroup then
    pcall(api.nvim_del_augroup_by_id, input_popup.augroup)
    input_popup.augroup = nil
  end
  if input_popup.win and is_valid_win(input_popup.win) then
    pcall(api.nvim_win_close, input_popup.win, true)
  end
  input_popup.win = nil
  if input_popup.buf and is_valid_buf(input_popup.buf) then
    pcall(api.nvim_buf_delete, input_popup.buf, { force = true })
  end
  input_popup.buf = nil
end

-- Custom input popup: Enter = Edit (tools), Shift+Enter = Ask Question (read-only). on_submit(prompt, mode).
local function open_quick_edit_input_popup(selection, on_submit)
  if input_popup.buf and is_valid_buf(input_popup.buf) then
    close_quick_edit_input_popup()
  end

  local buf = api.nvim_create_buf(false, true)
  input_popup.buf = buf
  api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  api.nvim_set_option_value("swapfile", false, { buf = buf })
  api.nvim_buf_set_lines(buf, 0, -1, false, { "" })

  local input_title = " Quick Edit  [Enter: Edit | Shift+Enter: Ask Question] "
  local title_width = vim.fn.strdisplaywidth(input_title) + 2
  local width = math.min(math.max(70, title_width), math.max(50, vim.o.columns - 10))
  local config = {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = 3,
    style = "minimal",
    border = "rounded",
    title = input_title,
    title_pos = "center",
    zindex = 90,
  }
  input_popup.win = api.nvim_open_win(buf, true, config)
  api.nvim_set_option_value("wrap", true, { win = input_popup.win })
  api.nvim_set_option_value("number", false, { win = input_popup.win })
  api.nvim_set_option_value("relativenumber", false, { win = input_popup.win })
  api.nvim_set_option_value("signcolumn", "no", { win = input_popup.win })

  local function submit(mode)
    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    -- Preserve full prompt exactly as typed.
    local prompt = table.concat(lines, "\n")
    -- Anchor response popover at the input box position (same place)
    if input_popup.win and is_valid_win(input_popup.win) then
      local pos = api.nvim_win_get_position(input_popup.win)
      if pos then
        quick_state.anchor_editor = { row = pos[1], col = pos[2] }
      end
    end
    close_quick_edit_input_popup()
    if not prompt or not prompt:match("%S") then
      notify("Quick Edit cancelled (empty prompt).", vim.log.levels.INFO)
      return
    end
    on_submit(prompt, mode)
  end

  vim.keymap.set("n", "<CR>", function() submit("edit") end, { buffer = buf, silent = true, desc = "Send Edit (Enter)" })
  vim.keymap.set("n", "<S-CR>", function() submit("ask") end, { buffer = buf, silent = true, desc = "Send Ask Question (Shift+Enter)" })
  vim.keymap.set("i", "<CR>", function() submit("edit") end, { buffer = buf, silent = true, desc = "Send Edit (Enter)" })
  vim.keymap.set("i", "<S-CR>", function() submit("ask") end, { buffer = buf, silent = true, desc = "Send Ask Question (Shift+Enter)" })
  vim.keymap.set("n", "<Esc>", close_quick_edit_input_popup, { buffer = buf, silent = true })
  vim.keymap.set("i", "<Esc>", close_quick_edit_input_popup, { buffer = buf, silent = true })

  input_popup.augroup = api.nvim_create_augroup("CursorAgentQuickEditInput", { clear = true })
  api.nvim_create_autocmd("WinClosed", {
    group = input_popup.augroup,
    callback = function(args)
      if tonumber(args.match) == input_popup.win then
        close_quick_edit_input_popup()
      end
    end,
  })

  vim.schedule(function()
    vim.cmd.startinsert()
  end)
end

-- mode: "edit" = with --approve-mcps (tools), "ask" = without (read-only)
local function build_quick_edit_command(prompt, mode)
  local cmd = state.opts and state.opts.command or defaults.command

  if type(cmd) == "table" then
    cmd = vim.tbl_extend("force", {}, cmd)
  elseif type(cmd) == "string" then
    cmd = { cmd }
  else
    cmd = { "agent" }
  end

  -- jobstart(argv) passes this as one positional argument (equivalent to: agent "<prompt>")
  local prompt_arg = type(prompt) == "string" and prompt or tostring(prompt or "")
  table.insert(cmd, prompt_arg)
  table.insert(cmd, "--output-format")
  table.insert(cmd, "stream-json")
  table.insert(cmd, "--print")
  table.insert(cmd, "--stream-partial-output")
  if mode == "edit" then
    table.insert(cmd, "--approve-mcps")
  end

  return cmd
end

local function build_quick_edit_prompt_with_reference(prompt, selection)
  local prompt_text = type(prompt) == "string" and prompt or tostring(prompt or "")
  if not selection or not selection.bufnr then return prompt_text end

  local line_start = selection.start_row or selection.end_row
  local line_end = selection.end_row or selection.start_row
  if not line_start or not line_end then return prompt_text end

  local reference = create_reference(selection.bufnr, line_start, line_end)
  if not reference or reference == "" then return prompt_text end

  if prompt_text == "" then return reference end
  return reference .. " " .. prompt_text
end

local function start_quick_edit_job(prompt, selection, mode)
  if not ensure_command_is_available() then return end

  if quick_state.job_id and quick_state.job_id > 0 then
    pcall(fn.jobstop, quick_state.job_id)
    quick_state.job_id = nil
  end

  mode = mode or "edit"
  quick_state.stream_buffer = ""
  open_quick_popover_streaming(selection and selection.filetype or "text", mode)
  start_quick_spinner()

  local prompt_with_reference = build_quick_edit_prompt_with_reference(prompt, selection)
  local cmd = build_quick_edit_command(prompt_with_reference, mode)

  local job_id = fn.jobstart(cmd, {
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data, _)
      if not data or quick_state.stream_complete then return end
      for _, chunk in ipairs(data) do
        quick_state.stream_buffer = quick_state.stream_buffer .. (chunk or "")
      end
      stream_process_buffer(false)
    end,
    on_stderr = function(_, data, _)
      if not data then return end
      for _, line in ipairs(data) do
        if line and line ~= "" then
          table.insert(quick_state.stream_stderr, line)
        end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        -- Flush any remaining stdout (last line often has no trailing newline)
        stream_process_buffer(true)
        clear_quick_spinner()
        quick_state.job_id = nil
        quick_state.stream_exit_code = code

        if code ~= 0 or #quick_state.stream_stderr > 0 then
          local err_head = ("[Quick Edit] agent exited with code %d"):format(code)
          if #quick_state.stream_stderr > 0 then
            quick_state.stream_visible = quick_state.stream_visible
              .. "\n\n"
              .. err_head
              .. "\n[stderr]\n"
              .. table.concat(quick_state.stream_stderr, "\n")
          else
            quick_state.stream_visible = quick_state.stream_visible .. "\n\n" .. err_head
          end
          quick_state.stream_filetype = "text"
        elseif quick_state.stream_visible == "" then
          quick_state.stream_visible = "No response from agent (exit 0). Check agent output format or try without --output-format stream-json."
          quick_state.stream_filetype = "text"
        end

        stream_redraw_now()
      end)
    end,
  })

  if type(job_id) ~= "number" or job_id <= 0 then
    clear_quick_spinner()
    open_quick_popover({ "Failed to start `agent` for Quick Edit." }, "text")
    return
  end

  quick_state.job_id = job_id

  -- Quick Edit sends file context via @file:start-end in the prompt argument (no stdin payload).
  fn.chanclose(job_id, "stdin")
end

local function run_quick_edit()
  local selection = capture_visual_selection()
  if not selection then return end

  open_quick_edit_input_popup(selection, function(prompt, mode)
    start_quick_edit_job(prompt, selection, mode)
  end)
end

-- End Quick Edit helpers -----------------------------------------------------

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
    "CursorAgentQuickEdit",
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

  api.nvim_create_user_command("CursorAgentQuickEdit", function()
    M.quick_edit()
  end, {
    desc = "Run Quick Edit on the current visual selection (preview-only)",
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
  if not M.restart() then return false end
  if not send_to_agent(reference .. " ") then return false end
  notify(("Started new session and added reference: %s"):format(reference), vim.log.levels.INFO)
  return true
end

--- Quick Edit entry point: capture visual selection, prompt for change, and
--- show the agent's proposed edit in a floating preview window.
function M.quick_edit()
  if not state.setup_done then M.setup() end
  run_quick_edit()
end

function M.is_running() return is_job_running() end

return M

