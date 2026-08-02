# todo.nvim

[English](README.md) | [简体中文](README.zh-CN.md)

A focused, local task manager for Neovim with a responsive dashboard, structured
task forms, and SQLite persistence. Tasks can be ranked by a transparent
combination of deadline and priority, so the emergency view answers “what
should I do next?”


https://github.com/user-attachments/assets/2d69b477-6317-413d-8381-6ce3469251cc


## Requirements

- Neovim 0.10+
- [`kkharji/sqlite.lua`](https://github.com/kkharji/sqlite.lua)
- [`MunifTanjim/nui.nvim`](https://github.com/MunifTanjim/nui.nvim)
- A system SQLite shared library (`libsqlite3.so`, `libsqlite3.dylib`, or
  `sqlite3.dll`)

Example with lazy.nvim:

```lua
{
  "InubashiriLix/TodoAnxiety.nvim",
  dependencies = {
    "kkharji/sqlite.lua",
    "MunifTanjim/nui.nvim",
  },
  config = function()
    require("todo").setup()
  end,
}
```

Run `:checkhealth todo` after installation.

## Usage

```vim
:Todo                         " open the active-task float
:Todo open sidebar emergency " emergency view in the sidebar
:Todo add Write release notes " prefill a new-task form
:Todo tags                    " open the tag manager
:Todo done 42                " complete task 42
:Todo archive 42             " archive while keeping the task recoverable
:Todo delete 42              " permanently delete an archived task
:Todo restore 42
```

All commands use the single `:Todo` entry point:

```text
open [float|sidebar] [active|emergency|archived]
toggle [float|sidebar]
add [title]
tags
edit [id]
start|done|cancel|reopen [id]
archive|restore|delete [id]
close
```

When an ID is omitted inside a todo panel, the task under the cursor is used.

Default global mappings:

| Mapping      | Action                   |
| ------------ | ------------------------ |
| `<leader>Tt` | Toggle the default panel |
| `<leader>Ta` | Add a task               |
| `<leader>Tf` | Open the floating panel  |
| `<leader>Ts` | Open the sidebar         |
| `<leader>Te` | Open the emergency view  |
| `<leader>Tg` | Manage tags              |

The dashboard footer shows common context-sensitive actions. Press `?` to show
the complete help. Existing global mappings are never overwritten.

In the archived view, select a task and press `D` to open a confirmation menu;
Cancel is selected by default to prevent an accidental Enter from deleting it.
`:Todo delete [id]` provides the command equivalent. Only archived tasks can be
permanently deleted, and deletion cannot be undone.

## Dashboard and form

The floating dashboard uses a task list and fixed detail pane when at least 100
columns are available. Narrow floats and the sidebar use two-line task cards;
press Enter to open the selected task in a detail popup. Active tasks are grouped
by status, while the emergency view retains urgency ordering.

The add/edit form uses separate controls instead of parsing a text buffer:

- A title input with inline validation
- A visible P0–P3 priority selector (`0`–`3`, arrow keys, or Enter menu) and a
  four-part status selector (`1`–`4`, arrow keys, or Enter menu)
- A keyboard calendar for choosing the date and an unrestricted time editor:
  type `HHMM` directly, adjust by one or five minutes/hours, or keep the task
  date-only. No fixed time presets or hidden mouse-only date buttons.
- A dedicated tag panel for selecting, creating, renaming, deleting, filtering,
  and inspecting usage counts; press Enter on an empty tag field, then use
  `j`/`k` and Enter/Space to toggle tags. You can also
  manage tags globally with `:Todo tags`/`<leader>Tg`. Deleting a tag removes
  that tag from every associated task after confirmation; tasks are not deleted.
- An independent multi-line description editor

Use Tab and Shift-Tab to move between fields, `<C-s>` to save, and `q` in Normal
mode or `<C-q>` from either mode to close. Escape only leaves Insert mode and is
never used as a form-close action. Unsaved forms ask whether to save, discard,
or continue editing. todo.nvim registers no mouse mappings; every plugin action
uses one visible keyboard path. When a form is opened from a dashboard,
the dashboard is suspended and restored afterward so the two interfaces never
overlap.

## Configuration

```lua
require("todo").setup({
  db_path = vim.fn.stdpath("data") .. "/todo.nvim/todo.db",
  language = "en", -- "en" or "zh-CN"
  ui = {
    default_mode = "float", -- "float" or "sidebar"
    default_view = "active", -- "active", "emergency", or "archived"
    float = { width = 0.80, height = 0.75, border = "rounded" },
    sidebar = { width = 42, side = "right" },
  },
  keymaps = {
    enabled = true,
    prefix = "<leader>T",
  },
})
```

The plugin stores one global database rather than one database per project.
Back up the configured `.db` file after closing Neovim, or use SQLite's backup
tools while it is open.

## Emergency ranking

Only unarchived `todo` and `in_progress` tasks are candidates. Every task with a
deadline is included; P0 and P1 tasks without a deadline are included too.

Deadline scores are 120 for overdue, 80 within 24 hours, 60 within three days,
40 within seven days, 20 later, and 0 without a deadline. Priority adds 30 for
P0, 20 for P1, 10 for P2, and 0 for P3. The UI shows a level and explanation,
not the numeric score. Overdue work always stays ahead of non-overdue work.

Deadlines accept `YYYY-MM-DD` or `YYYY-MM-DD HH:mm` in local time. A date without
a time means 23:59:59 on that date.

## Data and lifecycle

Tasks have a title, multi-line plain-text description, status, P0–P3 priority,
optional deadline, and zero or more tags. Statuses are `todo`, `in_progress`,
`done`, and `cancelled`. Tasks can be archived, restored, and—only after they
have been archived—permanently deleted. Reminders, recurring tasks, subtasks,
sync, and project scoping are deliberately outside the first release.

## Development

Run the dependency-free headless suite with:

```sh
bash scripts/test.sh
```

SQLite integration tests run when `kkharji/sqlite.lua` is available on
`runtimepath`; NUI integration tests similarly require `nui.nvim`. The test
script automatically detects the usual lazy.nvim paths, or accepts
`TODO_SQLITE_PATH` and `TODO_NUI_PATH`.
