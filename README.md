# cursor-agent.nvim

Cursor Agent integration for Neovim. This plugin provides a floating terminal UI around the `agent` CLI (Cursor CLI Agent), plus helpers to send file and selection references into an interactive chat session.

## Features

- Floating window terminal for the `agent` CLI.
- Session management helpers:
  - Open, close, toggle, restart, and resume sessions.
  - List previous sessions via `agent ls`.
- Add file/line range references to the agent from the current buffer or a visual selection, in the form `@path:start-end`.
- **Fix error at cursor**: send a message asking the agent to fix the diagnostic/error at the cursor, with the error text in a ``` code block and `@file:start-end` for the location.

## Requirements

- Neovim 0.9+ (Lua API used).
- `agent` binary available in your `$PATH` (or a compatible CLI you configure via `command`).

## Installation

Using `lazy.nvim`:

```lua
{
  "your-user/cursor-agent.nvim",
  config = function()
    require("cursor_agent").setup {
      -- By default this runs `agent` in the current working directory.
      command = { "agent" },
      -- Optional tweaks:
      -- auto_insert = true, -- jump into insert mode after opening
      -- notify = true,      -- use vim.notify for status messages
      -- path = { relative_to_cwd = true },
      -- float = { width = 0.9, height = 0.8, border = "rounded" },
    }
  end,
  keys = {
    { "<leader>at", function() require("cursor_agent").toggle() end, desc = "Toggle Cursor Agent terminal", mode = "n" },
    { "<leader>ao", function() require("cursor_agent").open() end,   desc = "Open Cursor Agent terminal",   mode = "n" },
    { "<leader>ac", function() require("cursor_agent").close() end,  desc = "Close Cursor Agent terminal",  mode = "n" },
    { "<leader>ar", function() require("cursor_agent").restart() end,desc = "Restart Cursor Agent terminal",mode = "n" },
    { "<leader>aR", function() require("cursor_agent").resume() end, desc = "Resume last Cursor Agent chat",mode = "n" },
    { "<leader>as", function() require("cursor_agent").list_sessions() end,
      desc = "List Cursor Agent sessions", mode = "n" },
    { "<leader>aa", function() require("cursor_agent").add_visual_selection() end,
      desc = "Add visual selection to Cursor Agent chat", mode = "x" },
    { "<leader>af", function() require("cursor_agent").request_fix_error_at_cursor() end,
      desc = "Ask Cursor Agent to fix error at cursor", mode = "n" },
  },
}
```

### AstroNvim

In an AstroNvim v5 config that uses `lazy.nvim`, you can use a local checkout during development:

```lua
---@type LazySpec
return {
  dir = vim.fn.stdpath("config") .. "/cursor-agent.nvim",
  name = "cursor-agent.nvim",
  lazy = true,
  config = function()
    require("cursor_agent").setup {
      command = { "agent" },
    }
  end,
}
```

Once the plugin is published on GitHub, replace `dir = ...` with `"your-user/cursor-agent.nvim"`.

## Usage

Commands provided by the plugin:

- `:CursorAgentOpen` – open an Agent session in a floating terminal.
- `:CursorAgentClose` – close the Agent window.
- `:CursorAgentToggle` – toggle the Agent window.
- `:CursorAgentRestart` – stop the current session and start a new one.
- `:CursorAgentResume` – resume the last session (`agent --continue`).
- `:CursorAgentListSessions` – run `agent ls` in the Agent window.
- `:CursorAgentAddSelection` – add a `@file:start-end` reference for a given line range.
- `:CursorAgentFixErrorAtCursor` – send the diagnostic/error at the cursor to the agent in a “please fix” message (error in ``` block, plus `@file:start-end`).

Helpers and keybindings (when configured):

- **Visual selection**: `require("cursor_agent").add_visual_selection()` or e.g. `<leader>aa` – send selection as `@file:start-end`.
- **Fix error at cursor**: `require("cursor_agent").request_fix_error_at_cursor()` or e.g. `<leader>af` – send error at cursor and ask agent to fix it.

- Call `require("cursor_agent").add_visual_selection()` (or use a mapped key such as `<leader>aa`) to send a reference for the current visual selection.

## Configuration

`require("cursor_agent").setup(opts)` accepts:

- `command` (`string | string[]`, default: `{ "agent" }`): the CLI to run.
- `auto_insert` (`boolean`, default: `true`): enter insert mode after opening the terminal.
- `notify` (`boolean`, default: `true`): enable notification messages via `vim.notify`.
- `path.relative_to_cwd` (`boolean`, default: `true`): emit paths relative to the current working directory when building `@file:start-end` references.
- `float`:
  - `width` (`number`): absolute columns or a fraction of the editor width.
  - `height` (`number`): absolute lines or a fraction of the editor height.
  - `border`, `title`, `title_pos`, `zindex`, `winblend`, `winhighlight`: standard Neovim window options.

