local api = vim.api
local fn = vim.fn
local config = require("cursor_agent.config")
local notify = require("cursor_agent.notify")
local references = require("cursor_agent.references")
local diagnostics = require("cursor_agent.diagnostics")
local util = require("cursor_agent.util")
local session = require("cursor_agent.agent.session")
local terminal = require("cursor_agent.agent.terminal")
local window = require("cursor_agent.agent.window")
local autocmds = require("cursor_agent.agent.autocmds")
local commands = require("cursor_agent.commands")
local quick_edit_job = require("cursor_agent.quick_edit.job")

local M = {}

function M.setup(opts)
  if config.setup_done() then
    if opts then
      config.merge_opts(opts)
    end
    return M
  end

  config.merge_opts(opts)
  autocmds.setup()
  commands.setup(M)
  config.set_setup_done(true)
  return M
end

function M.open()
  if not config.setup_done() then
    M.setup()
  end
  if not session.ensure_session(false, nil, session.close) then
    return false
  end
  if config.opts().auto_insert then
    vim.schedule(function()
      vim.cmd.startinsert()
    end)
  end
  return true
end

function M.close()
  return session.close()
end

function M.toggle()
  if not config.setup_done() then
    M.setup()
  end
  local state = config.get_state()
  if util.is_valid_win(state.win) then
    M.close()
    return true
  end
  return M.open()
end

function M.resume()
  if not config.setup_done() then
    M.setup()
  end
  if not session.ensure_session(true, nil, session.close) then
    return false
  end
  if config.opts().auto_insert then
    vim.schedule(function()
      vim.cmd.startinsert()
    end)
  end
  return true
end

function M.list_sessions()
  if not config.setup_done() then
    M.setup()
  end
  if not session.ensure_session(false, { "ls" }, session.close) then
    return false
  end
  if config.opts().auto_insert then
    vim.schedule(function()
      vim.cmd.startinsert()
    end)
  end
  return true
end

function M.restart()
  if not config.setup_done() then
    M.setup()
  end

  if terminal.is_job_running() then
    pcall(fn.jobstop, config.get_state().job_id)
  end
  config.get_state().job_id = nil

  window.delete_buffer()
  return M.open()
end

function M.add_selection(line_start, line_end, bufnr)
  if not config.setup_done() then
    M.setup()
  end

  local target_buf = bufnr or api.nvim_get_current_buf()
  local first = tonumber(line_start)
  local last = tonumber(line_end)

  if not first or not last then
    local line = api.nvim_win_get_cursor(0)[1]
    first = line
    last = line
  end

  local reference = references.create_reference(target_buf, first, last)
  if not reference then
    return false
  end

  if not M.open() then
    return false
  end
  if not session.send_to_agent(reference .. " ") then
    return false
  end

  notify.notify(("Added reference: %s"):format(reference), vim.log.levels.INFO)
  return true
end

function M.add_visual_selection()
  local start_pos = fn.getpos("'<")
  local end_pos = fn.getpos("'>")

  if not start_pos or not end_pos or start_pos[2] == 0 or end_pos[2] == 0 then
    notify.notify("No visual selection found.", vim.log.levels.WARN)
    return false
  end

  return M.add_selection(start_pos[2], end_pos[2], api.nvim_get_current_buf())
end

function M.request_fix_error_at_cursor()
  if not config.setup_done() then
    M.setup()
  end
  local message = diagnostics.build_fix_error_message_at_cursor()
  if not message then
    notify.notify("No diagnostic/error at cursor position.", vim.log.levels.WARN)
    return false
  end
  if not M.open() then
    return false
  end
  if not session.send_to_agent(message .. "\n") then
    return false
  end
  notify.notify("Sent fix-error request to Cursor Agent.", vim.log.levels.INFO)
  return true
end

function M.request_fix_error_at_cursor_in_new_session()
  if not config.setup_done() then
    M.setup()
  end
  local message = diagnostics.build_fix_error_message_at_cursor()
  if not message then
    notify.notify("No diagnostic/error at cursor position.", vim.log.levels.WARN)
    return false
  end
  if not M.restart() then
    return false
  end
  if not session.send_to_agent(message .. "\n") then
    return false
  end
  notify.notify("Sent fix-error request to new Cursor Agent session.", vim.log.levels.INFO)
  return true
end

function M.add_visual_selection_to_new_session()
  if not config.setup_done() then
    M.setup()
  end
  local start_pos = fn.getpos("'<")
  local end_pos = fn.getpos("'>")
  if not start_pos or not end_pos or start_pos[2] == 0 or end_pos[2] == 0 then
    notify.notify("No visual selection found.", vim.log.levels.WARN)
    return false
  end
  local bufnr = api.nvim_get_current_buf()
  local reference = references.create_reference(bufnr, start_pos[2], end_pos[2])
  if not reference then
    return false
  end
  if not M.restart() then
    return false
  end
  if not session.send_to_agent(reference .. " ") then
    return false
  end
  notify.notify(("Started new session and added reference: %s"):format(reference), vim.log.levels.INFO)
  return true
end

function M.quick_edit()
  if not config.setup_done() then
    M.setup()
  end
  quick_edit_job.run_quick_edit()
end

function M.is_running()
  return terminal.is_job_running()
end

return M
