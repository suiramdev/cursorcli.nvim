local api = vim.api
local config = require("cursorcli.config")
local notify = require("cursorcli.notify")
local util = require("cursorcli.util")

local M = {}

local input_popup = { buf = nil, win = nil, augroup = nil }

function M.close_quick_edit_input_popup()
  if input_popup.augroup then
    pcall(api.nvim_del_augroup_by_id, input_popup.augroup)
    input_popup.augroup = nil
  end
  if input_popup.win and util.is_valid_win(input_popup.win) then
    pcall(api.nvim_win_close, input_popup.win, true)
  end
  input_popup.win = nil
  if input_popup.buf and util.is_valid_buf(input_popup.buf) then
    pcall(api.nvim_buf_delete, input_popup.buf, { force = true })
  end
  input_popup.buf = nil
end

function M.open_quick_edit_input_popup(selection, on_submit)
  local quick_state = config.get_quick_state()

  if input_popup.buf and util.is_valid_buf(input_popup.buf) then
    M.close_quick_edit_input_popup()
  end

  local buf = api.nvim_create_buf(false, true)
  input_popup.buf = buf
  api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  api.nvim_set_option_value("swapfile", false, { buf = buf })
  api.nvim_buf_set_lines(buf, 0, -1, false, { "" })

  local input_title = " Quick Edit  [Enter: Edit | Shift+Enter: Ask Question] "
  local title_width = vim.fn.strdisplaywidth(input_title) + 2
  local width = math.min(math.max(70, title_width), math.max(50, vim.o.columns - 10))
  local win_config = {
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
  input_popup.win = api.nvim_open_win(buf, true, win_config)
  api.nvim_set_option_value("wrap", true, { win = input_popup.win })
  api.nvim_set_option_value("number", false, { win = input_popup.win })
  api.nvim_set_option_value("relativenumber", false, { win = input_popup.win })
  api.nvim_set_option_value("signcolumn", "no", { win = input_popup.win })

  local function submit(mode)
    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    local prompt = table.concat(lines, "\n")
    if input_popup.win and util.is_valid_win(input_popup.win) then
      local pos = api.nvim_win_get_position(input_popup.win)
      if pos then
        quick_state.anchor_editor = { row = pos[1], col = pos[2] }
      end
    end
    M.close_quick_edit_input_popup()
    if not prompt or not prompt:match("%S") then
      notify.notify("Quick Edit cancelled (empty prompt).", vim.log.levels.INFO)
      return
    end
    on_submit(prompt, mode)
  end

  vim.keymap.set("n", "<CR>", function() submit("edit") end, { buffer = buf, silent = true, desc = "Send Edit (Enter)" })
  vim.keymap.set("n", "<S-CR>", function() submit("ask") end, { buffer = buf, silent = true, desc = "Send Ask Question (Shift+Enter)" })
  vim.keymap.set("i", "<CR>", function() submit("edit") end, { buffer = buf, silent = true, desc = "Send Edit (Enter)" })
  vim.keymap.set("i", "<S-CR>", function() submit("ask") end, { buffer = buf, silent = true, desc = "Send Ask Question (Shift+Enter)" })
  vim.keymap.set("n", "<Esc>", M.close_quick_edit_input_popup, { buffer = buf, silent = true })
  vim.keymap.set("i", "<Esc>", M.close_quick_edit_input_popup, { buffer = buf, silent = true })

  input_popup.augroup = api.nvim_create_augroup("CursorCliQuickEditInput", { clear = true })
  api.nvim_create_autocmd("WinClosed", {
    group = input_popup.augroup,
    callback = function(args)
      if tonumber(args.match) == input_popup.win then
        M.close_quick_edit_input_popup()
      end
    end,
  })

  vim.schedule(function()
    vim.cmd.startinsert()
  end)
end

return M
