local api = vim.api
local fn = vim.fn
local config = require("cursorcli.config")
local notify = require("cursorcli.notify")
local references = require("cursorcli.references")
local diagnostics = require("cursorcli.diagnostics")
local util = require("cursorcli.util")
local chats = require("cursorcli.chats")
local session = require("cursorcli.agent.session")
local terminal = require("cursorcli.agent.terminal")
local window = require("cursorcli.agent.window")
local autocmds = require("cursorcli.agent.autocmds")
local commands = require("cursorcli.commands")
local quick_edit_job = require("cursorcli.quick_edit.job")
local picker = require("cursorcli.picker")

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

local function close_cb()
  session.close()
end

--- Normalize layout: "vsplit" -> "right", "hsplit" -> "bottom".
local function normalize_layout(layout)
  if not layout or layout == "" then
    return nil
  end
  local L = layout:lower()
  if L == "vsplit" then
    return "right"
  end
  if L == "hsplit" then
    return "bottom"
  end
  return layout
end

function M.open(opts)
  if not config.setup_done() then
    M.setup()
  end
  local layout_override = opts and normalize_layout(opts.layout)
  local active_id = chats.get_active_id()
  if not active_id then
    active_id = chats.create(nil)
  end
  if not session.ensure_session(active_id, false, nil, close_cb, layout_override) then
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
  local active = chats.get_active()
  if active and util.is_valid_win(active.win) then
    M.close()
    return true
  end
  return M.open()
end

function M.resume()
  if not config.setup_done() then
    M.setup()
  end
  local active_id = chats.get_active_id()
  if not active_id then
    active_id = chats.create(nil)
  end
  if not session.ensure_session(active_id, true, nil, close_cb) then
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
  local active_id = chats.get_active_id()
  if not active_id then
    active_id = chats.create(nil)
  end
  if not session.ensure_session(active_id, false, { "ls" }, close_cb) then
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
  local active_id = chats.get_active_id()
  if active_id and terminal.is_job_running(active_id) then
    local chat = chats.get(active_id)
    if chat and chat.job_id then
      pcall(fn.jobstop, chat.job_id)
    end
  end
  if active_id then
    window.delete_buffer(active_id)
  end
  return M.open()
end

function M.new_chat(name)
  if not config.setup_done() then
    M.setup()
  end
  local id = chats.create(name)
  session.ensure_session(id, false, nil, close_cb)
  if config.opts().auto_insert then
    vim.schedule(function()
      vim.cmd.startinsert()
    end)
  end
  return id
end

function M.select_chat()
  if not config.setup_done() then
    M.setup()
  end
  if not chats.has_chats() then
    M.new_chat(nil)
    return
  end
  picker.pick_chat()
end

function M.rename_chat(name)
  if not config.setup_done() then
    M.setup()
  end
  local active = chats.get_active()
  if not active then
    notify.notify("No active chat to rename. Create one first.", vim.log.levels.WARN)
    return false
  end
  if name and name:match("%S") then
    if chats.rename(active.id, name) then
      notify.notify("Chat renamed to: " .. name, vim.log.levels.INFO)
      return true
    end
    return false
  end
  picker.rename_prompt(active.name, function(new_name)
    if new_name and chats.rename(active.id, new_name) then
      notify.notify("Chat renamed to: " .. new_name, vim.log.levels.INFO)
    end
  end)
  return true
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
  notify.notify("Sent fix-error request to Cursor CLI.", vim.log.levels.INFO)
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
  notify.notify("Sent fix-error request to new Cursor CLI session.", vim.log.levels.INFO)
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
