local fn = vim.fn
local config = require("cursorcli.config")
local references = require("cursorcli.references")
local popover = require("cursorcli.quick_edit.popover")
local stream = require("cursorcli.quick_edit.stream")
local selection = require("cursorcli.quick_edit.selection")
local session = require("cursorcli.agent.session")

local M = {}

local function build_quick_edit_command(prompt, mode)
  local opts = config.opts()
  local cmd = (opts and opts.command) or { "agent" }

  if type(cmd) == "table" then
    cmd = vim.tbl_extend("force", {}, cmd)
  elseif type(cmd) == "string" then
    cmd = { cmd }
  else
    cmd = { "agent" }
  end

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

local function build_quick_edit_prompt_with_reference(prompt, sel)
  local prompt_text = type(prompt) == "string" and prompt or tostring(prompt or "")
  if not sel or not sel.bufnr then
    return prompt_text
  end

  local line_start = sel.start_row or sel.end_row
  local line_end = sel.end_row or sel.start_row
  if not line_start or not line_end then
    return prompt_text
  end

  local reference = references.create_reference(sel.bufnr, line_start, line_end)
  if not reference or reference == "" then
    return prompt_text
  end

  if prompt_text == "" then
    return reference
  end
  return reference .. " " .. prompt_text
end

function M.start_quick_edit_job(prompt, sel, mode)
  if not session.ensure_command_is_available() then
    return
  end

  local quick_state = config.get_quick_state()
  if quick_state.job_id and quick_state.job_id > 0 then
    pcall(fn.jobstop, quick_state.job_id)
    quick_state.job_id = nil
  end

  mode = mode or "edit"
  quick_state.stream_buffer = ""
  popover.open_quick_popover_streaming(sel and sel.filetype or "text", mode)
  stream.start_quick_spinner()

  local prompt_with_reference = build_quick_edit_prompt_with_reference(prompt, sel)
  local cmd = build_quick_edit_command(prompt_with_reference, mode)

  local job_id = fn.jobstart(cmd, {
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data, _)
      if not data or quick_state.stream_complete then
        return
      end
      for _, chunk in ipairs(data) do
        quick_state.stream_buffer = quick_state.stream_buffer .. (chunk or "")
      end
      stream.stream_process_buffer(false)
    end,
    on_stderr = function(_, data, _)
      if not data then
        return
      end
      for _, line in ipairs(data) do
        if line and line ~= "" then
          table.insert(quick_state.stream_stderr, line)
        end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        stream.stream_process_buffer(true)
        stream.clear_quick_spinner()
        quick_state.job_id = nil
        quick_state.stream_exit_code = code
        selection.refresh_quick_edit_source_buffer(sel, mode)

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

        stream.stream_redraw_now()
      end)
    end,
  })

  if type(job_id) ~= "number" or job_id <= 0 then
    stream.clear_quick_spinner()
    popover.open_quick_popover({ "Failed to start `agent` for Quick Edit." }, "text")
    return
  end

  quick_state.job_id = job_id
  fn.chanclose(job_id, "stdin")
end

function M.run_quick_edit()
  local sel = selection.capture_visual_selection()
  if not sel then
    return
  end

  local input = require("cursorcli.quick_edit.input")
  input.open_quick_edit_input_popup(sel, function(prompt, mode)
    M.start_quick_edit_job(prompt, sel, mode)
  end)
end

return M
