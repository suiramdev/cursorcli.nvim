local api = vim.api
local fn = vim.fn
local config = require("cursorcli.config")
local notify = require("cursorcli.notify")
local util = require("cursorcli.util")

local M = {}

function M.capture_visual_selection()
  local start_pos = fn.getpos("'<")
  local end_pos = fn.getpos("'>")

  if not start_pos or not end_pos or start_pos[2] == 0 or end_pos[2] == 0 then
    notify.notify("Quick Edit requires a visual selection.", vim.log.levels.WARN)
    return nil
  end

  local bufnr = api.nvim_get_current_buf()
  local path = api.nvim_buf_get_name(bufnr)
  local vmode = fn.visualmode() or "v"

  local srow, scol = start_pos[2], start_pos[3]
  local erow, ecol = end_pos[2], end_pos[3]

  if srow > erow or (srow == erow and scol > ecol) then
    srow, erow = erow, srow
    scol, ecol = ecol, scol
  end

  local lines = {}

  if vmode == "V" then
    lines = api.nvim_buf_get_lines(bufnr, srow - 1, erow, false)
  elseif vmode == "\022" then
    local start_col = math.min(scol, ecol) - 1
    local end_col = math.max(scol, ecol) - 1
    for row = srow - 1, erow - 1 do
      local text = api.nvim_buf_get_text(bufnr, row, start_col, row, end_col + 1, {})
      table.insert(lines, text[1] or "")
    end
  else
    lines = api.nvim_buf_get_text(bufnr, srow - 1, scol - 1, erow - 1, ecol, {})
  end

  if not lines or #lines == 0 then
    notify.notify("Quick Edit: visual selection was empty.", vim.log.levels.WARN)
    return nil
  end

  return {
    bufnr = bufnr,
    path = path,
    file_mtime = (path ~= "" and fn.getftime(path)) or -1,
    start_row = srow,
    start_col = scol,
    end_row = erow,
    end_col = ecol,
    lines = lines,
    filetype = vim.bo[bufnr].filetype or "text",
  }
end

function M.refresh_quick_edit_source_buffer(selection, mode)
  if mode ~= "edit" then
    return
  end
  if not selection or not selection.path or selection.path == "" then
    return
  end

  local fn = vim.fn
  local before_mtime = tonumber(selection.file_mtime or -1) or -1
  local after_mtime = fn.getftime(selection.path)
  if type(after_mtime) ~= "number" or after_mtime < 0 then
    return
  end
  if before_mtime >= 0 and after_mtime <= before_mtime then
    return
  end

  local bufnr = selection.bufnr
  if not util.is_valid_buf(bufnr) then
    notify.notify("Quick Edit updated file on disk. Reopen it to load latest changes.", vim.log.levels.INFO)
    return
  end

  if api.nvim_get_option_value("modified", { buf = bufnr }) then
    notify.notify("Quick Edit updated file on disk, but buffer has unsaved changes; skipping reload.", vim.log.levels.WARN)
    return
  end

  local reloaded = false
  local wins = fn.win_findbuf(bufnr)
  for _, win in ipairs(wins) do
    if util.is_valid_win(win) then
      local ok = pcall(api.nvim_win_call, win, function()
        local view = fn.winsaveview()
        vim.cmd("silent! keepalt keepjumps edit!")
        pcall(fn.winrestview, view)
      end)
      if ok then
        reloaded = true
        break
      end
    end
  end

  if not reloaded then
    reloaded = pcall(api.nvim_buf_call, bufnr, function()
      vim.cmd("silent! keepalt keepjumps edit!")
    end)
  end

  if not reloaded then
    notify.notify("Quick Edit finished, but failed to refresh edited file buffer.", vim.log.levels.WARN)
  end
end

return M
