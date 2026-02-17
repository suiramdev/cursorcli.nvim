local api = vim.api

local M = {}

function M.setup(agent_module)
  local command_names = {
    "CursorAgentOpen",
    "CursorAgentClose",
    "CursorAgentToggle",
    "CursorAgentRestart",
    "CursorAgentResume",
    "CursorAgentListSessions",
    "CursorAgentAddSelection",
    "CursorAgentFixErrorAtCursor",
    "CursorAgentFixErrorAtCursorInNewSession",
    "CursorAgentAddVisualSelectionToNewSession",
    "CursorAgentQuickEdit",
  }

  for _, name in ipairs(command_names) do
    pcall(api.nvim_del_user_command, name)
  end

  api.nvim_create_user_command("CursorAgentOpen", function()
    agent_module.open()
  end, { desc = "Open Cursor Agent terminal" })
  api.nvim_create_user_command("CursorAgentClose", function()
    agent_module.close()
  end, { desc = "Close Cursor Agent terminal" })
  api.nvim_create_user_command("CursorAgentToggle", function()
    agent_module.toggle()
  end, { desc = "Toggle Cursor Agent terminal" })
  api.nvim_create_user_command("CursorAgentRestart", function()
    agent_module.restart()
  end, { desc = "Restart Cursor Agent terminal" })
  api.nvim_create_user_command("CursorAgentResume", function()
    agent_module.resume()
  end, { desc = "Resume last Cursor Agent chat session" })
  api.nvim_create_user_command("CursorAgentListSessions", function()
    agent_module.list_sessions()
  end, { desc = "List Cursor Agent sessions (interactive CLI)" })

  api.nvim_create_user_command("CursorAgentAddSelection", function(command_opts)
    agent_module.add_selection(command_opts.line1, command_opts.line2)
  end, {
    range = true,
    desc = "Add @file:start-end reference to Cursor Agent chat",
  })
  api.nvim_create_user_command("CursorAgentFixErrorAtCursor", function()
    agent_module.request_fix_error_at_cursor()
  end, { desc = "Send error at cursor to Cursor Agent and ask to fix it" })
  api.nvim_create_user_command("CursorAgentFixErrorAtCursorInNewSession", function()
    agent_module.request_fix_error_at_cursor_in_new_session()
  end, { desc = "Start new session and send error at cursor to Cursor Agent" })
  api.nvim_create_user_command("CursorAgentAddVisualSelectionToNewSession", function()
    agent_module.add_visual_selection_to_new_session()
  end, { desc = "Start new session and send visual selection (code + @file ref) to Cursor Agent" })
  api.nvim_create_user_command("CursorAgentQuickEdit", function()
    agent_module.quick_edit()
  end, { desc = "Run Quick Edit on the current visual selection (preview-only)" })
end

return M
