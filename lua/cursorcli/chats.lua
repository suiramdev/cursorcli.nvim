-- Multi-chat (agent session) state.
-- Each chat has: id, name, buf, win, job_id, created_at.
-- active_id = currently shown chat; last_id = last active for toggle.

local config = require("cursorcli.config")

local M = {}

local state = {
  chats = {},
  active_id = nil,
  last_id = nil,
  counter = 0,
}

local function generate_id()
  state.counter = state.counter + 1
  return ("chat-%d"):format(state.counter)
end

local function default_name()
  local opts = config.opts()
  local name = (opts and opts.terminal and opts.terminal.default_name) or "Agent"
  if opts and opts.terminal ~= nil and opts.terminal.auto_number == false then
    return name
  end
  return ("%s %d"):format(name, state.counter)
end

function M.create(name)
  local id = generate_id()
  if not name or name == "" then
    name = default_name()
  end
  state.chats[id] = {
    id = id,
    name = name,
    buf = nil,
    win = nil,
    job_id = nil,
    created_at = os.time(),
  }
  state.active_id = id
  state.last_id = id
  return id
end

function M.get(id)
  return state.chats[id]
end

function M.get_active()
  return state.active_id and state.chats[state.active_id] or nil
end

function M.get_active_id()
  return state.active_id
end

function M.get_last_id()
  return state.last_id
end

function M.list()
  local list = {}
  for _, chat in pairs(state.chats) do
    table.insert(list, chat)
  end
  table.sort(list, function(a, b)
    return a.created_at > b.created_at
  end)
  return list
end

function M.rename(id, new_name)
  local chat = state.chats[id]
  if not chat or not new_name or new_name == "" then
    return false
  end
  chat.name = new_name
  return true
end

function M.set_buf(id, buf)
  local chat = state.chats[id]
  if chat then
    chat.buf = buf
  end
end

function M.set_win(id, win)
  local chat = state.chats[id]
  if chat then
    chat.win = win
  end
end

function M.set_job_id(id, job_id)
  local chat = state.chats[id]
  if chat then
    chat.job_id = job_id
  end
end

function M.clear_buf_win_job(id)
  local chat = state.chats[id]
  if chat then
    chat.buf = nil
    chat.win = nil
    chat.job_id = nil
  end
end

function M.set_active(id)
  if state.chats[id] then
    state.active_id = id
    state.last_id = id
    state.chats[id].last_active = os.time()
  end
end

function M.switch_to(id)
  if not state.chats[id] then
    return false
  end
  M.set_active(id)
  return true
end

function M.delete(id)
  local chat = state.chats[id]
  if not chat then
    return false
  end
  state.chats[id] = nil
  if state.active_id == id then
    state.active_id = nil
  end
  if state.last_id == id then
    local list = M.list()
    state.last_id = (list[1] and list[1].id) or nil
  end
  return true
end

function M.has_chats()
  return next(state.chats) ~= nil
end

function M.count()
  local n = 0
  for _ in pairs(state.chats) do
    n = n + 1
  end
  return n
end

--- Find chat that owns the given buffer (by scanning chats).
function M.find_by_buf(bufnr)
  for _, chat in pairs(state.chats) do
    if chat.buf == bufnr then
      return chat
    end
  end
  return nil
end

--- Find chat that owns the given window.
function M.find_by_win(winid)
  for _, chat in pairs(state.chats) do
    if chat.win == winid then
      return chat
    end
  end
  return nil
end

return M
