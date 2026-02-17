# cursorcli.nvim

Cursor CLI integration for Neovim.

**Repository:** [cursorcli.nvim](https://github.com/your-user/cursorcli.nvim) — This plugin provides a floating terminal UI around the `agent` CLI (Cursor CLI), plus helpers to send file and selection references into an interactive chat session.

## Features

- Floating window terminal for the `agent` CLI.
- **Multiple chats**: create, rename, and switch between several agent chats (each with its own terminal session).
- **Fuzzy finder with live preview**: Telescope-like picker (via [snacks.nvim](https://github.com/folke/snacks.nvim) when available) to select a chat; preview shows the last lines of each chat. Create a new chat or switch to an existing one from the picker.
- **Open by layout**: `<leader>af` float, `<leader>av` vertical split, `<leader>ah` horizontal split; **restart** to start a new session in the current chat. Resume and list sessions via `agent ls`.
- **Open with layout**: `:CursorCliOpenWithLayout [float|vsplit|hsplit]` (or no argument to prompt); useful regardless of your default `position` in config.
- Add file/line range references to the agent from the current buffer or a visual selection, in the form `@path:start-end`.
- **Fix error at cursor**: send a message asking the agent to fix the diagnostic/error at the cursor, with the error text in a ``` code block and `@file:start-end` for the location.
- **Add to new session (CAPS)**: with `<Leader>aA` — in **normal** mode, start a new session and send the error at cursor (same format as above); in **visual** mode, start a new session and send the highlighted code in a ``` block plus `@file:start-end`.
- **Quick Edit (very early)**: visual selection + prompt in a floating popover, streaming output, and Edit/Ask modes.

## Requirements

- Neovim 0.9+ (Lua API used).
- `agent` binary available in your `$PATH` (or a compatible CLI you configure via `command`).

### Optional: snacks.nvim

If [folke/snacks.nvim](https://github.com/folke/snacks.nvim) is installed and loaded, this plugin uses:

- **Snacks.notifier** for notifications (consistent styling and history).
- **Snacks.picker** for the chat fuzzy finder (live preview of chat content, fuzzy search).
- **Snacks.input** for the rename prompt (better input UI).

The plugin works fully without snacks (falls back to `vim.notify`, `vim.ui.select`, and `vim.ui.input`); no extra dependency is required.

## Installation

Using `lazy.nvim`:

```lua
{
  "your-user/cursorcli.nvim",
  config = function()
    require("cursorcli").setup {
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
    { "<leader>af", "<Cmd>CursorCliOpenWithLayout float<CR>",   desc = "Open Cursor CLI (floating window)",   mode = "n" },
    { "<leader>av", "<Cmd>CursorCliOpenWithLayout vsplit<CR>", desc = "Open Cursor CLI (vertical split)",   mode = "n" },
    { "<leader>ah", "<Cmd>CursorCliOpenWithLayout hsplit<CR>", desc = "Open Cursor CLI (horizontal split)", mode = "n" },
    { "<leader>ac", function() require("cursorcli").close() end,  desc = "Close Cursor CLI terminal",     mode = "n" },
    { "<leader>an", function() require("cursorcli").new_chat() end, desc = "New Cursor CLI chat", mode = "n" },
    { "<leader>as", function() require("cursorcli").select_chat() end, desc = "Select chat (fuzzy finder with preview)", mode = "n" },
    { "<leader>ar", function() require("cursorcli").rename_chat() end, desc = "Rename current Cursor CLI chat", mode = "n" },
    { "<leader>aR", function() require("cursorcli").resume() end, desc = "Resume last Cursor CLI chat", mode = "n" },
    { "<leader>ax", function() require("cursorcli").restart() end, desc = "Restart Cursor CLI (new session in current chat)", mode = "n" },
    { "<leader>al", function() require("cursorcli").list_sessions() end, desc = "List Cursor CLI sessions (agent ls)", mode = "n" },
    { "<leader>aa", function() require("cursorcli").add_visual_selection() end,
      desc = "Add visual selection to Cursor CLI chat", mode = "x" },
    { "<leader>aA", function() require("cursorcli").request_fix_error_at_cursor_in_new_session() end,
      desc = "New session: send error at cursor", mode = "n" },
    { "<leader>aA", function() require("cursorcli").add_visual_selection_to_new_session() end,
      desc = "New session: send visual selection", mode = "x" },
  },
}
```

### AstroNvim

Install from GitHub:

```lua
---@type LazySpec
return {
  "your-user/cursorcli.nvim",
  lazy = true,
  config = function()
    require("cursorcli").setup {
      command = { "agent" },
    }
  end,
}
```

For local development, use a `dir` spec instead:

```lua
dir = vim.fn.stdpath("config") .. "/cursorcli.nvim",
name = "cursorcli.nvim",
```

## Usage

Commands provided by the plugin:

- `:CursorCliOpen` – open or create a chat; useful for scripts.
- `:CursorCliOpenWithLayout [float|vsplit|hsplit]` – open agent as floating window or split; with no argument, prompts to choose (Float / Vertical split / Horizontal split). Suggested keys: `<leader>af` float, `<leader>av` vsplit, `<leader>ah` hsplit.
- `:CursorCliClose` – close the Agent window.
- `:CursorCliRestart` – stop the current session and start a new one in the current chat.
- `:CursorCliResume` – resume the last session (`agent --continue`).
- `:CursorCliNew [name]` – create a new agent chat (optional name).
- `:CursorCliSelect` – open the chat fuzzy finder (live preview when using snacks.nvim). Select a chat to switch, or "New chat" to create one.
- `:CursorCliRename [name]` – rename the current chat; prompts if name omitted (uses Snacks.input when available).
- `:CursorCliListSessions` – run `agent ls` in the Agent window.
- `:CursorCliAddSelection` – add a `@file:start-end` reference for a given line range.
- `:CursorCliFixErrorAtCursor` – send the diagnostic/error at the cursor to the agent in a “please fix” message (error in ``` block, plus `@file:start-end`).
- `:CursorCliFixErrorAtCursorInNewSession` – start a **new** agent session and send the error at cursor (same format).
- `:CursorCliAddVisualSelectionToNewSession` – start a **new** agent session and send the visual selection (code in ``` block + `@file:start-end`).
- `:CursorCliQuickEdit` – open the Quick Edit prompt for the current visual selection.

Helpers and keybindings (when configured):

- **Open by layout**: `<leader>af` float, `<leader>av` vertical split, `<leader>ah` horizontal split.
- **Visual selection**: `require("cursorcli").add_visual_selection()` or e.g. `<leader>aa` – send selection as `@file:start-end`.
- **Fix error at cursor**: `:CursorCliFixErrorAtCursor` or `require("cursorcli").request_fix_error_at_cursor()` – send error at cursor and ask agent to fix it.
- **New session with CAPS**: `<leader>aA` – in normal mode, new session + error at cursor; in visual mode, new session + highlighted code and `@file:start-end`.

- Call `require("cursorcli").add_visual_selection()` (or use a mapped key such as `<leader>aa`) to send a reference for the current visual selection.

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

`require("cursorcli").setup(opts)` accepts:

- `command` (`string | string[]`, default: `{ "agent" }`): the CLI to run.
- `auto_insert` (`boolean`, default: `true`): enter insert mode after opening the terminal.
- `notify` (`boolean`, default: `true`): enable notification messages via `vim.notify`.
- `path.relative_to_cwd` (`boolean`, default: `true`): emit paths relative to the current working directory when building `@file:start-end` references.
- `terminal` (optional): `default_name` (string, default: `"Agent"`), `auto_number` (boolean, default: `true`) for naming new chats (e.g. "Agent 1", "Agent 2").
- `position` (`string`, default: `"float"`): where to open the agent window. Use `"float"` for a centered floating window (default), or `"right"`, `"left"`, `"bottom"`, `"top"` for a split on that side.
- `split_size` (`number`, default: `0.4`): when `position` is a split, size as a fraction of the editor (0–1) or absolute columns/lines (≥1). Example: `0.4` = 40% width for right/left, 40% height for top/bottom.
- `float` (used when `position == "float"`):
  - `width` (`number`): absolute columns or a fraction of the editor width.
  - `height` (`number`): absolute lines or a fraction of the editor height.
  - `border`, `title`, `title_pos`, `zindex`, `winblend`, `winhighlight`: standard Neovim window options.

## Plugin structure

The plugin is split into modules under `lua/cursorcli/`:

- `init.lua` — setup and public API (toggle, open, close, new_chat, select_chat, rename_chat, add_selection, quick_edit, etc.).
- `config.lua` — defaults and shared state (quick edit; agent state is per-chat in `chats.lua`).
- `chats.lua` — multi-chat state: create, list, switch, rename; each chat has id, name, buf, win, job_id.
- `picker.lua` — chat fuzzy finder with live preview (Snacks.picker when available; fallback `vim.ui.select`). Uses Snacks.input for rename prompt when available.
- `notify.lua` — notifications (uses Snacks.notifier when available, else `vim.notify`).
- `util.lua`, `references.lua`, `diagnostics.lua` — helpers and path/reference building.
- `agent/` — terminal session: window, terminal buffer, session lifecycle, autocmds (all per-chat).
- `quick_edit/` — Quick Edit: stream parsing, popover, input popup, selection capture, job runner.
- `commands.lua` — user commands (`:CursorCliToggle`, `:CursorCliNew`, `:CursorCliSelect`, `:CursorCliRename`, etc.).

