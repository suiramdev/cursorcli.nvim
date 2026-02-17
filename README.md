# cursor-agent.nvim

Cursor Agent integration for Neovim.

**Repository:** [suiramdev/cursor-nvim](https://github.com/suiramdev/cursor-nvim) This plugin provides a floating terminal UI around the `agent` CLI (Cursor CLI Agent), plus helpers to send file and selection references into an interactive chat session.

## Features

- Floating window terminal for the `agent` CLI.
- **Toggle** to open the agent (or create a session if none) or close the window; **restart** to start a new session. Resume and list sessions via `agent ls`.
- Add file/line range references to the agent from the current buffer or a visual selection, in the form `@path:start-end`.
- **Fix error at cursor**: send a message asking the agent to fix the diagnostic/error at the cursor, with the error text in a ``` code block and `@file:start-end` for the location.
- **Add to new session (CAPS)**: with `<Leader>aA` — in **normal** mode, start a new session and send the error at cursor (same format as above); in **visual** mode, start a new session and send the highlighted code in a ``` block plus `@file:start-end`.
- **Quick Edit (very early)**: visual selection + prompt in a floating popover, streaming output, and Edit/Ask modes.

## Requirements

- Neovim 0.9+ (Lua API used).
- `agent` binary available in your `$PATH` (or a compatible CLI you configure via `command`).

### Optional: snacks.nvim

If [folke/snacks.nvim](https://github.com/folke/snacks.nvim) is installed and loaded, this plugin uses `Snacks.notifier` for notifications (consistent styling and history). The plugin works fully without snacks; no extra dependency is required.

## Installation

Using `lazy.nvim`:

```lua
{
  "suiramdev/cursor-nvim",
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
    { "<leader>at", function() require("cursor_agent").toggle() end, desc = "Toggle agent (open/create if none)", mode = "n" },
    { "<leader>ac", function() require("cursor_agent").close() end,  desc = "Close Cursor Agent terminal",     mode = "n" },
    { "<leader>ar", function() require("cursor_agent").restart() end,desc = "Restart Cursor Agent (new session)", mode = "n" },
    { "<leader>aR", function() require("cursor_agent").resume() end, desc = "Resume last Cursor Agent chat",mode = "n" },
    { "<leader>as", function() require("cursor_agent").list_sessions() end,
      desc = "List Cursor Agent sessions", mode = "n" },
    { "<leader>aa", function() require("cursor_agent").add_visual_selection() end,
      desc = "Add visual selection to Cursor Agent chat", mode = "x" },
    { "<leader>af", function() require("cursor_agent").request_fix_error_at_cursor() end,
      desc = "Ask Cursor Agent to fix error at cursor", mode = "n" },
    { "<leader>aA", function() require("cursor_agent").request_fix_error_at_cursor_in_new_session() end,
      desc = "New session: send error at cursor", mode = "n" },
    { "<leader>aA", function() require("cursor_agent").add_visual_selection_to_new_session() end,
      desc = "New session: send visual selection", mode = "x" },
  },
}
```

### AstroNvim

Install from GitHub:

```lua
---@type LazySpec
return {
  "suiramdev/cursor-nvim",
  lazy = true,
  config = function()
    require("cursor_agent").setup {
      command = { "agent" },
    }
  end,
}
```

For local development, use a `dir` spec instead:

```lua
dir = vim.fn.stdpath("config") .. "/cursor-agent.nvim",
name = "cursor-agent.nvim",
```

## Usage

Commands provided by the plugin:

- `:CursorAgentToggle` – open the agent (create a session if none) or close the window. Main way to open.
- `:CursorAgentOpen` – same as toggle “on” (open or create); useful for scripts.
- `:CursorAgentClose` – close the Agent window.
- `:CursorAgentRestart` – stop the current session and start a new one. Kept as the explicit “new session” action.
- `:CursorAgentResume` – resume the last session (`agent --continue`).
- `:CursorAgentListSessions` – run `agent ls` in the Agent window.
- `:CursorAgentAddSelection` – add a `@file:start-end` reference for a given line range.
- `:CursorAgentFixErrorAtCursor` – send the diagnostic/error at the cursor to the agent in a “please fix” message (error in ``` block, plus `@file:start-end`).
- `:CursorAgentFixErrorAtCursorInNewSession` – start a **new** agent session and send the error at cursor (same format).
- `:CursorAgentAddVisualSelectionToNewSession` – start a **new** agent session and send the visual selection (code in ``` block + `@file:start-end`).
- `:CursorAgentQuickEdit` – open the Quick Edit prompt for the current visual selection.

Helpers and keybindings (when configured):

- **Visual selection**: `require("cursor_agent").add_visual_selection()` or e.g. `<leader>aa` – send selection as `@file:start-end`.
- **Fix error at cursor**: `require("cursor_agent").request_fix_error_at_cursor()` or e.g. `<leader>af` – send error at cursor and ask agent to fix it.
- **New session with CAPS**: `<leader>aA` – in normal mode, new session + error at cursor; in visual mode, new session + highlighted code and `@file:start-end`.

- Call `require("cursor_agent").add_visual_selection()` (or use a mapped key such as `<leader>aa`) to send a reference for the current visual selection.

### Quick Edit (very early)

> ⚠️ **Very early feature:** Quick Edit is still experimental and may contain bugs or rough edges.
> If you hit issues, please report them in GitHub issues with repro steps and (if possible) popover/error output.

Quick Edit sends your prompt with context in the first argument, in this format:

- `agent "@<file path>:<line start>-<line end> <prompt>" --output-format stream-json --print --stream-partial-output`
- In **Edit** mode, `--approve-mcps` is also added.
- In **Ask Question** mode (Shift+Enter), `--approve-mcps` is not added.

Notes:

- The `@file:start-end` reference is built from the current visual selection.
- Selection context is sent in the prompt argument itself (not via stdin).

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

## Plugin structure

The plugin is split into modules under `lua/cursor_agent/`:

- `init.lua` — setup and public API (toggle, open, close, add_selection, quick_edit, etc.).
- `config.lua` — defaults and shared state (agent + quick edit).
- `notify.lua` — notifications (uses Snacks.notifier when available, else `vim.notify`).
- `util.lua`, `references.lua`, `diagnostics.lua` — helpers and path/reference building.
- `agent/` — terminal session: window, terminal buffer, session lifecycle, autocmds.
- `quick_edit/` — Quick Edit: stream parsing, popover, input popup, selection capture, job runner.
- `commands.lua` — user commands (`:CursorAgentToggle`, etc.).

