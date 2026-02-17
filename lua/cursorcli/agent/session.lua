local api = vim.api
local fn = vim.fn
local uv = vim.uv or vim.loop
local config = require("cursorcli.config")
local notify = require("cursorcli.notify")
local references = require("cursorcli.references")
local util = require("cursorcli.util")
local chats = require("cursorcli.chats")
local window = require("cursorcli.agent.window")
local terminal = require("cursorcli.agent.terminal")

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

--- Start agent in a chat (create buf, open window, termopen). Uses chat.buf, chat.win, chat.job_id.
function M.start_agent_session(chat_id, resume_last, extra_args, close_cb, layout_override)
  if not M.ensure_command_is_available() then
    return false
  end

  local chat = chats.get(chat_id)
  if not chat then
    return false
  end

  if util.is_valid_buf(chat.buf) then
    window.delete_buffer(chat_id)
  end

  chat.buf = api.nvim_create_buf(false, false)
  api.nvim_buf_set_var(chat.buf, "cursorcli_chat_id", chat_id)
  terminal.configure_terminal_buffer(chat.buf, close_cb, chat_id)

  local open_opts = layout_override and { position = layout_override } or nil
  if not window.open_window(chat_id, close_cb, open_opts) then
    notify.notify("Unable to open Cursor CLI terminal window.", vim.log.levels.ERROR)
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

  local job_id = api.nvim_buf_call(chat.buf, function()
    return fn.termopen(cmd, {
      cwd = cwd,
      on_exit = function(_, code)
        vim.schedule(function()
          chats.set_job_id(chat_id, nil)
          if code ~= 0 then
            notify.notify(("Cursor CLI exited with code %d"):format(code), vim.log.levels.WARN)
          else
            notify.notify("Cursor CLI exited.", vim.log.levels.INFO)
          end
        end)
      end,
    })
  end)

  if type(job_id) ~= "number" or job_id <= 0 then
    notify.notify("Failed to start Cursor CLI terminal job.", vim.log.levels.ERROR)
    return false
  end

  chats.set_job_id(chat_id, job_id)
  return true
end

--- Ensure chat has a running session or start one. Reuse existing window if same chat and job running.
--- layout_override: optional "float"|"right"|"left"|"bottom"|"top" for this open only.
function M.ensure_session(chat_id, resume_last, extra_args, close_cb, layout_override)
  local chat = chats.get(chat_id)
  if not chat then
    return false
  end

  local reuse = not resume_last and not (extra_args and #extra_args > 0)
  if reuse and terminal.is_job_running(chat_id) and util.is_valid_buf(chat.buf) then
    local open_opts = layout_override and { position = layout_override } or nil
    return window.open_window(chat_id, close_cb, open_opts)
  end
  return M.start_agent_session(chat_id, resume_last, extra_args, close_cb, layout_override)
end

function M.send_to_agent(text, chat_id)
  chat_id = chat_id or chats.get_active_id()
  if not chat_id or not terminal.is_job_running(chat_id) then
    notify.notify("Cursor CLI is not running.", vim.log.levels.ERROR)
    return false
  end

  local chat = chats.get(chat_id)
  local sent = fn.chansend(chat.job_id, text)
  if type(sent) ~= "number" or sent <= 0 then
    notify.notify("Failed sending text to Cursor CLI.", vim.log.levels.ERROR)
    return false
  end

  return true
end

function M.close(chat_id)
  chat_id = chat_id or chats.get_active_id()
  if chat_id then
    window.close_window(chat_id)
  end
  return true
end

return M
