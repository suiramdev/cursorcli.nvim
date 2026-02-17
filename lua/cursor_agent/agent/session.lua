local api = vim.api
local fn = vim.fn
local uv = vim.uv or vim.loop
local config = require("cursor_agent.config")
local notify = require("cursor_agent.notify")
local references = require("cursor_agent.references")
local util = require("cursor_agent.util")
local window = require("cursor_agent.agent.window")
local terminal = require("cursor_agent.agent.terminal")

local M = {}

local function executable_for_command(command)
  if type(command) == "table" then
    return command[1]
  end
  if type(command) == "string" then
    return command:match("^%s*(%S+)")
  end
  return nil
end

function M.ensure_command_is_available()
  local opts = config.opts()
  local executable = executable_for_command(opts.command)
  if not executable or executable == "" then
    notify.notify("Invalid command. Set `command` to `agent` or a valid command table.", vim.log.levels.ERROR)
    return false
  end

  if fn.executable(executable) ~= 1 then
    notify.notify(("Command `%s` is not executable or not in PATH."):format(executable), vim.log.levels.ERROR)
    return false
  end

  return true
end

function M.start_agent_session(resume_last, extra_args, close_cb)
  if not M.ensure_command_is_available() then
    return false
  end

  local state = config.get_state()
  if util.is_valid_buf(state.buf) then
    window.delete_buffer()
  end

  state.buf = api.nvim_create_buf(false, false)
  terminal.configure_terminal_buffer(state.buf, close_cb)

  if not window.open_window(close_cb) then
    notify.notify("Unable to open Cursor Agent terminal window.", vim.log.levels.ERROR)
    return false
  end

  local cwd = uv.cwd()
  local cmd = config.opts().command
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
            notify.notify(("Cursor Agent exited with code %d"):format(code), vim.log.levels.WARN)
          else
            notify.notify("Cursor Agent exited.", vim.log.levels.INFO)
          end
        end)
      end,
    })
  end)

  if type(job_id) ~= "number" or job_id <= 0 then
    notify.notify("Failed to start Cursor Agent terminal job.", vim.log.levels.ERROR)
    return false
  end

  state.job_id = job_id
  return true
end

function M.ensure_session(resume_last, extra_args, close_cb)
  local reuse = not resume_last and not (extra_args and #extra_args > 0)
  if reuse and terminal.is_job_running() and util.is_valid_buf(config.get_state().buf) then
    return window.open_window(close_cb)
  end
  return M.start_agent_session(resume_last, extra_args, close_cb)
end

function M.send_to_agent(text)
  if not terminal.is_job_running() then
    notify.notify("Cursor Agent is not running.", vim.log.levels.ERROR)
    return false
  end

  local state = config.get_state()
  local sent = fn.chansend(state.job_id, text)
  if type(sent) ~= "number" or sent <= 0 then
    notify.notify("Failed sending text to Cursor Agent.", vim.log.levels.ERROR)
    return false
  end

  return true
end

function M.close()
  window.close_window()
  return true
end

return M
