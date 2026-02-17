local api = vim.api
local uv = vim.uv or vim.loop
local config = require("cursorcli.config")
local util = require("cursorcli.util")

local M = {}

local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local QUICK_EDIT_THINKING_HL = "CursorCliQuickEditThinking"
local QUICK_EDIT_TOOL_HL = "CursorCliQuickEditTool"

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

local function stream_take_json_object(buf)
  buf = buf:gsub("^%s+", "")
  local start = buf:find("{")
  if not start then
    return nil, buf
  end
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
      if c == quote then
        in_string = false
      end
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

local function stream_parse_line(line)
  if type(line) ~= "string" or line == "" then
    return nil
  end
  local ok, obj = pcall(vim.json.decode, line)
  if not ok or type(obj) ~= "table" then
    return nil
  end
  return obj
end

local function stream_reduce_event(obj)
  local quick_state = config.get_quick_state()
  local t = obj.type
  local subtype = obj.subtype
  local nil_te = nil

  if t == "system" then
    return nil, nil, false, nil_te
  end
  if t == "user" then
    return nil, nil, false, nil_te
  end
  if t == "thinking" then
    if subtype == "delta" and type(obj.text) == "string" and obj.text ~= "" then
      return nil, obj.text, false, nil_te
    end
    return nil, nil, false, nil_te
  end

  if t == "assistant" then
    local msg = obj.message
    if type(msg) == "table" and type(msg.content) == "table" then
      local out = {}
      for _, part in ipairs(msg.content) do
        if type(part) == "table" and part.type == "text" and type(part.text) == "string" then
          table.insert(out, part.text)
        end
      end
      if #out > 0 then
        return table.concat(out), nil, false, nil_te
      end
    end
    return nil, nil, false, nil_te
  end

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

  if t == "result" then
    local text = obj.result
    if type(text) == "string" and text ~= "" then
      return text, nil, true, nil_te
    end
    return nil, nil, true, nil_te
  end

  return nil, nil, false, nil_te
end

function M.stream_do_redraw()
  local quick_state = config.get_quick_state()
  if not quick_state.buf or not util.is_valid_buf(quick_state.buf) then
    return
  end

  local function text_to_lines(text)
    if type(text) ~= "string" or text == "" then
      return {}
    end
    local out = {}
    for s in (text .. "\n"):gmatch("(.-)\n") do
      table.insert(out, s)
    end
    return out
  end

  local mode = quick_state.mode or "edit"
  local lines = {}
  local spinner_frame = SPINNER_FRAMES[quick_state.spinner_frame or 1]

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
          if diff and #(c.diffString or "") > 60 then
            diff = diff .. "…"
          end
          tool_lines[#tool_lines + 1] = ("✓ editToolCall: %s — %s"):format(name, summary)
          if diff and diff ~= "" then
            tool_lines[#tool_lines + 1] = "  " .. diff
          end
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
  local num_tool = #tool_lines > 0 and (2 + #tool_lines) or 0
  local thinking_start_0 = num_tool

  if #thinking_lines > 0 then
    table.insert(lines, spinner_frame .. " Thinking")
    for _, l in ipairs(thinking_lines) do
      table.insert(lines, l)
    end
    table.insert(lines, "")
  end

  local visible_text = quick_state.stream_visible
  if visible_text ~= "" then
    visible_text = visible_text:gsub("^\n+", ""):gsub("\n+$", ""):gsub("\n\n\n+", "\n\n")
  end
  local visible_lines = {}
  if visible_text == "" then
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

  if not quick_state.thinking_ns then
    quick_state.thinking_ns = api.nvim_create_namespace("CursorCliQuickEditThinking")
  end
  api.nvim_buf_clear_namespace(quick_state.buf, quick_state.thinking_ns, 0, -1)
  if num_tool > 0 then
    pcall(api.nvim_set_hl, 0, QUICK_EDIT_TOOL_HL, { ctermfg = 8, guifg = "#78716c" })
    for line = 0, num_tool - 1 do
      api.nvim_buf_add_highlight(quick_state.buf, quick_state.thinking_ns, QUICK_EDIT_TOOL_HL, line, 0, -1)
    end
  end
  if num_thinking > 0 then
    pcall(api.nvim_set_hl, 0, QUICK_EDIT_THINKING_HL, { ctermfg = 246, guifg = "#9ca3af" })
    for line = thinking_start_0, thinking_end_0 do
      api.nvim_buf_add_highlight(quick_state.buf, quick_state.thinking_ns, QUICK_EDIT_THINKING_HL, line, 0, -1)
    end
  end

  if quick_state.win and util.is_valid_win(quick_state.win) then
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

function M.clear_quick_spinner()
  local quick_state = config.get_quick_state()
  if quick_state.spinner_timer then
    pcall(quick_state.spinner_timer.stop, quick_state.spinner_timer)
    pcall(quick_state.spinner_timer.close, quick_state.spinner_timer)
    quick_state.spinner_timer = nil
  end
end

function M.stop_redraw_timer()
  local quick_state = config.get_quick_state()
  if quick_state.redraw_timer then
    pcall(quick_state.redraw_timer.stop, quick_state.redraw_timer)
    pcall(quick_state.redraw_timer.close, quick_state.redraw_timer)
    quick_state.redraw_timer = nil
  end
end

function M.stop_content_spinner()
  local quick_state = config.get_quick_state()
  if quick_state.content_spinner_timer then
    pcall(quick_state.content_spinner_timer.stop, quick_state.content_spinner_timer)
    pcall(quick_state.content_spinner_timer.close, quick_state.content_spinner_timer)
    quick_state.content_spinner_timer = nil
  end
end

local function has_pending_tool_calls()
  local quick_state = config.get_quick_state()
  if quick_state.mode ~= "edit" or not quick_state.tool_events then
    return false
  end
  for _, ev in ipairs(quick_state.tool_events) do
    if not ev.completed then
      return true
    end
  end
  return false
end

local function start_content_spinner()
  local quick_state = config.get_quick_state()
  if quick_state.content_spinner_timer then
    return
  end
  quick_state.content_spinner_timer = uv.new_timer()
  quick_state.content_spinner_timer:start(
    0,
    80,
    vim.schedule_wrap(function()
      if not quick_state.buf or not util.is_valid_buf(quick_state.buf) then
        M.stop_content_spinner()
        return
      end
      local thinking_active = (quick_state.stream_thinking or "") ~= ""
      local pending_tools = has_pending_tool_calls()
      if not thinking_active and not pending_tools then
        M.stop_content_spinner()
        return
      end
      quick_state.spinner_frame = ((quick_state.spinner_frame or 1) % #SPINNER_FRAMES) + 1
      M.stream_do_redraw()
    end)
  )
end

local function stream_schedule_redraw()
  local quick_state = config.get_quick_state()
  if quick_state.redraw_timer then
    return
  end
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
      M.stream_do_redraw()
    end)
  )
end

local function stream_process_line(line)
  local quick_state = config.get_quick_state()

  local function enter_result_phase()
    if quick_state.stream_phase == "result" then
      return
    end
    quick_state.stream_phase = "result"
    quick_state.stream_thinking = ""
    quick_state.tool_events = {}
    quick_state.tool_blocked_count = 0
    quick_state.stream_visible = ""
    M.stop_content_spinner()
    M.clear_quick_spinner()
  end

  local obj = stream_parse_line(line)
  if obj then
    local append_visible, append_thinking, done, tool_event = stream_reduce_event(obj)
    if (append_visible and #append_visible > 0) or (append_thinking and #append_thinking > 0) or (tool_event and tool_event.call_id) then
      M.clear_quick_spinner()
    end

    if append_thinking and #append_thinking > 0 and quick_state.stream_phase ~= "result" then
      if quick_state.stream_phase ~= "thinking" then
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
      enter_result_phase()
      if quick_state.stream_visible == "" then
        quick_state.stream_visible = append_visible
      elseif append_visible:sub(1, #quick_state.stream_visible) == quick_state.stream_visible then
        quick_state.stream_visible = append_visible
      elseif #append_visible <= #quick_state.stream_visible and quick_state.stream_visible:sub(-#append_visible) == append_visible then
        -- skip duplicate
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
      quick_state.stream_phase = "result"
      quick_state.stream_thinking = ""
      quick_state.tool_events = {}
      quick_state.tool_blocked_count = 0
      M.stop_content_spinner()
      M.clear_quick_spinner()
      if append_visible and #append_visible > 0 then
        quick_state.stream_visible = append_visible
      end
      quick_state.stream_complete = true
      M.stream_redraw_now()
    end
  else
    if line ~= "" and not (line:match("^%s*{") and not line:match("}%s*$")) then
      enter_result_phase()
      quick_state.stream_visible = quick_state.stream_visible .. line .. "\n"
      stream_schedule_redraw()
    end
  end
end

function M.stream_process_buffer(flush_remaining)
  local quick_state = config.get_quick_state()
  while true do
    local obj_str, rest = stream_take_json_object(quick_state.stream_buffer)
    if obj_str then
      quick_state.stream_buffer = rest
      stream_process_line(obj_str)
      goto continue
    end
    local line, line_rest = stream_take_line(quick_state.stream_buffer, false)
    if not line then
      if flush_remaining and quick_state.stream_buffer ~= "" then
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
    local obj = stream_parse_line(line)
    if obj then
      stream_process_line(line)
    else
      local remainder = line
      while true do
        obj_str, rest = stream_take_json_object(remainder)
        if not obj_str then
          break
        end
        stream_process_line(obj_str)
        remainder = rest
      end
      if remainder ~= "" then
        if remainder:match("^%s*{") and not remainder:match("}%s*$") then
          quick_state.stream_buffer = remainder .. quick_state.stream_buffer
        else
          stream_process_line(remainder)
        end
      end
    end
    ::continue::
  end
end

function M.stream_redraw_now()
  M.stop_redraw_timer()
  vim.schedule(M.stream_do_redraw)
end

function M.start_quick_spinner()
  local quick_state = config.get_quick_state()
  M.clear_quick_spinner()

  local index = 1
  quick_state.spinner_timer = uv.new_timer()
  quick_state.spinner_timer:start(
    0,
    80,
    vim.schedule_wrap(function()
      if not quick_state.buf or not util.is_valid_buf(quick_state.buf) or not quick_state.win or not util.is_valid_win(quick_state.win) then
        M.clear_quick_spinner()
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

return M
