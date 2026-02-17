-- Fuzzy finder for agent chats with live preview (Snacks.picker when available).

local api = vim.api
local chats = require("cursorcli.chats")
local terminal = require("cursorcli.agent.terminal")
local session = require("cursorcli.agent.session")
local notify = require("cursorcli.notify")
local config = require("cursorcli.config")
local util = require("cursorcli.util")

local M = {}

local PREVIEW_MAX_LINES = 80

local function format_chat_display(chat)
  local status_icon = "●"
  local status_text = "running"
  if not terminal.is_job_running(chat.id) then
    status_icon = "○"
    status_text = "stopped"
  end
  local age_seconds = os.time() - (chat.created_at or os.time())
  local age_str
  if age_seconds < 60 then
    age_str = age_seconds .. "s ago"
  elseif age_seconds < 3600 then
    age_str = math.floor(age_seconds / 60) .. "m ago"
  else
    age_str = math.floor(age_seconds / 3600) .. "h ago"
  end
  return ("%s %s (%s, %s)"):format(status_icon, chat.name, status_text, age_str)
end

local function get_chat_preview_text(chat)
  if not chat.buf or not util.is_valid_buf(chat.buf) then
    return ("[%s]\n\nBuffer not available (terminal not running or closed)."):format(chat.name)
  end
  local ok, lines = pcall(api.nvim_buf_get_lines, chat.buf, 0, -1, false)
  if not ok or not lines or #lines == 0 then
    return ("[%s]\n\nNo content."):format(chat.name)
  end
  local start = math.max(1, #lines - PREVIEW_MAX_LINES + 1)
  local slice = {}
  for i = start, #lines do
    slice[#slice + 1] = lines[i]
  end
  return ("[%s] (last %d lines)\n\n%s"):format(chat.name, #slice, table.concat(slice, "\n"))
end

local function has_snacks_picker()
  local ok = pcall(function()
    return type(_G.Snacks) == "table" and type(_G.Snacks.picker) == "table" and type(_G.Snacks.picker.pick) == "function"
  end)
  return ok and type(_G.Snacks) == "table" and type(_G.Snacks.picker) == "table" and type(_G.Snacks.picker.pick) == "function"
end

local function has_snacks_input()
  local ok = pcall(function()
    return type(_G.Snacks) == "table" and type(_G.Snacks.input) == "table" and type(_G.Snacks.input.input) == "function"
  end)
  return ok and type(_G.Snacks) == "table" and type(_G.Snacks.input) == "table" and type(_G.Snacks.input.input) == "function"
end

--- Prompt for a new name; returns the string or nil. Uses Snacks.input when available.
function M.rename_prompt(current_name, callback)
  if type(callback) ~= "function" then
    return
  end
  if has_snacks_input() then
    _G.Snacks.input.input({
      prompt = "Rename chat: ",
      default = current_name or "",
    }, function(value)
      callback(value and value:match("%S") and value or nil)
    end)
  else
    vim.ui.input({
      prompt = "Rename chat: ",
      default = current_name or "",
    }, function(value)
      callback(value and value:match("%S") and value or nil)
    end)
  end
end

--- Open chats picker: select a chat to switch to, or "New chat" to create one.
--- Uses Snacks.picker with live preview when available; falls back to vim.ui.select.
function M.pick_chat(callback)
  callback = callback or function() end

  local list = chats.list()
  local items = {}

  -- "New chat" entry
  table.insert(items, {
    text = "+ New chat",
    value = "__new__",
    idx = 0,
    preview = { text = "Create a new Cursor CLI chat and open it.", ft = "markdown" },
  })

  for i, chat in ipairs(list) do
    table.insert(items, {
      text = format_chat_display(chat),
      value = chat.id,
      idx = i,
      preview = { text = get_chat_preview_text(chat), ft = "terminal" },
    })
  end

  if #items == 1 then
    -- Only "New chat" - no existing chats; create one and open
    if items[1].value == "__new__" then
      local id = chats.create(nil)
      session.ensure_session(id, false, nil, function()
        session.close(id)
      end)
      chats.set_active(id)
      if config.opts().auto_insert then
        vim.schedule(function()
          vim.cmd.startinsert()
        end)
      end
      callback(id)
    end
    return
  end

  if has_snacks_picker() then
    _G.Snacks.picker.pick({
      items = items,
      title = " Cursor CLI Chats ",
      prompt = "Chat: ",
      preview = "preview",
      format = "text",
      confirm = function(picker, item)
        if not item or not item.value then
          return
        end
        picker:close()
        if item.value == "__new__" then
          local id = chats.create(nil)
          session.ensure_session(id, false, nil, function()
            session.close(id)
          end)
          chats.set_active(id)
          if config.opts().auto_insert then
            vim.schedule(function()
              vim.cmd.startinsert()
            end)
          end
          callback(id)
        else
          local prev_id = chats.get_active_id()
          if prev_id and prev_id ~= item.value then
            session.close(prev_id)
          end
          chats.switch_to(item.value)
          session.ensure_session(item.value, false, nil, function()
            session.close(item.value)
          end)
          if config.opts().auto_insert then
            vim.schedule(function()
              vim.cmd.startinsert()
            end)
          end
          callback(item.value)
        end
      end,
    })
    return
  end

  -- Fallback: vim.ui.select
  local choices = {}
  local value_by_idx = {}
  for i, it in ipairs(items) do
    choices[i] = it.text
    value_by_idx[i] = it.value
  end
  vim.ui.select(choices, {
    prompt = "Cursor CLI Chats:",
    format_item = function(item)
      return item
    end,
  }, function(_, idx)
    if not idx then
      return
    end
    local value = value_by_idx[idx]
    if value == "__new__" then
      local id = chats.create(nil)
      session.ensure_session(id, false, nil, function()
        session.close(id)
      end)
      chats.set_active(id)
      if config.opts().auto_insert then
        vim.schedule(function()
          vim.cmd.startinsert()
        end)
      end
      callback(id)
    else
      chats.switch_to(value)
      session.ensure_session(value, false, nil, function()
        session.close(value)
      end)
      if config.opts().auto_insert then
        vim.schedule(function()
          vim.cmd.startinsert()
        end)
      end
      callback(value)
    end
  end)
end

return M
