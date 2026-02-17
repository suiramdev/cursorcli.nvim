local api = vim.api

local M = {}

function M.setup(agent_module)
  local command_names = {
    "CursorCliOpen",
    "CursorCliOpenWithLayout",
    "CursorCliClose",
    "CursorCliToggle",
    "CursorCliRestart",
    "CursorCliResume",
    "CursorCliListSessions",
    "CursorCliNew",
    "CursorCliSelect",
    "CursorCliRename",
    "CursorCliAddSelection",
    "CursorCliFixErrorAtCursor",
    "CursorCliFixErrorAtCursorInNewSession",
    "CursorCliAddVisualSelectionToNewSession",
    "CursorCliQuickEdit",
  }

  for _, name in ipairs(command_names) do
    pcall(api.nvim_del_user_command, name)
  end

  api.nvim_create_user_command("CursorCliOpen", function()
    agent_module.open()
  end, { desc = "Open Cursor CLI terminal" })
  api.nvim_create_user_command("CursorCliOpenWithLayout", function(opts)
    local arg = opts.args and opts.args:match("%S+") and opts.args:match("%S+") or nil
    if arg then
      agent_module.open({ layout = arg })
    else
      vim.ui.select(
        { "Float", "Vertical split", "Horizontal split" },
        { prompt = "Open agent as:" },
        function(choice)
          if not choice then
            return
          end
          local layout = (choice == "Float" and "float")
            or (choice == "Vertical split" and "vsplit")
            or (choice == "Horizontal split" and "hsplit")
          agent_module.open({ layout = layout })
        end
      )
    end
  end, { desc = "Open Cursor CLI as float or split (arg: float|vsplit|hsplit)", nargs = "?" })
  api.nvim_create_user_command("CursorCliClose", function()
    agent_module.close()
  end, { desc = "Close Cursor CLI terminal" })
  api.nvim_create_user_command("CursorCliToggle", function()
    agent_module.toggle()
  end, { desc = "Toggle Cursor CLI terminal" })
  api.nvim_create_user_command("CursorCliRestart", function()
    agent_module.restart()
  end, { desc = "Restart Cursor CLI terminal" })
  api.nvim_create_user_command("CursorCliResume", function()
    agent_module.resume()
  end, { desc = "Resume last Cursor CLI chat session" })
  api.nvim_create_user_command("CursorCliListSessions", function()
    agent_module.list_sessions()
  end, { desc = "List Cursor CLI sessions (interactive CLI)" })
  api.nvim_create_user_command("CursorCliNew", function(opts)
    local name = opts.args and opts.args ~= "" and opts.args or nil
    agent_module.new_chat(name)
  end, { desc = "Create new Cursor CLI chat", nargs = "?" })
  api.nvim_create_user_command("CursorCliSelect", function()
    agent_module.select_chat()
  end, { desc = "Select Cursor CLI chat (fuzzy finder with preview)" })
  api.nvim_create_user_command("CursorCliRename", function(opts)
    local name = opts.args and opts.args ~= "" and opts.args or nil
    agent_module.rename_chat(name)
  end, { desc = "Rename current Cursor CLI chat", nargs = "?" })

  api.nvim_create_user_command("CursorCliAddSelection", function(command_opts)
    agent_module.add_selection(command_opts.line1, command_opts.line2)
  end, {
    range = true,
    desc = "Add @file:start-end reference to Cursor CLI chat",
  })
  api.nvim_create_user_command("CursorCliFixErrorAtCursor", function()
    agent_module.request_fix_error_at_cursor()
  end, { desc = "Send error at cursor to Cursor CLI and ask to fix it" })
  api.nvim_create_user_command("CursorCliFixErrorAtCursorInNewSession", function()
    agent_module.request_fix_error_at_cursor_in_new_session()
  end, { desc = "Start new session and send error at cursor to Cursor CLI" })
  api.nvim_create_user_command("CursorCliAddVisualSelectionToNewSession", function()
    agent_module.add_visual_selection_to_new_session()
  end, { desc = "Start new session and send visual selection (code + @file ref) to Cursor CLI" })
  api.nvim_create_user_command("CursorCliQuickEdit", function()
    agent_module.quick_edit()
  end, { desc = "Run Quick Edit on the current visual selection (preview-only)" })
end

return M
