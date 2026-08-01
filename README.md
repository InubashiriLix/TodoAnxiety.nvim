# todo.nvim

A focused, local task manager for Neovim with a native floating UI, a sidebar,
and SQLite persistence. Tasks can be ranked by a transparent combination of
deadline and priority, so the emergency view answers “what should I do next?”

中文简介：这是一个使用 SQLite 本地存储的 Neovim TODO 插件，提供浮窗、
侧栏、紧急度排序、搜索筛选以及中英文界面。数据完全保存在本机。

## Requirements

- Neovim 0.10+
- [`kkharji/sqlite.lua`](https://github.com/kkharji/sqlite.lua)
- A system SQLite shared library (`libsqlite3.so`, `libsqlite3.dylib`, or
  `sqlite3.dll`)

Example with lazy.nvim:

```lua
{
  "your-name/todo.nvim",
  dependencies = { "kkharji/sqlite.lua" },
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
:Todo done 42                " complete task 42
:Todo archive 42             " archive; never permanently deletes
:Todo restore 42
```

All commands use the single `:Todo` entry point:

```text
open [float|sidebar] [active|emergency|archived]
toggle [float|sidebar]
add [title]
edit [id]
start|done|cancel|reopen [id]
archive|restore [id]
close
```

When an ID is omitted inside a todo panel, the task under the cursor is used.

Default global mappings:

| Mapping | Action |
| --- | --- |
| `<leader>Tt` | Toggle the default panel |
| `<leader>Ta` | Add a task |
| `<leader>Tf` | Open the floating panel |
| `<leader>Ts` | Open the sidebar |
| `<leader>Te` | Open the emergency view |

The panel advertises its buffer-local actions on the second line. Press `?` to
show them again. Existing global mappings are never overwritten.

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
`done`, and `cancelled`. Archive and restore are supported; permanent deletion,
reminders, recurring tasks, subtasks, sync, and project scoping are deliberately
outside the first release.

## Development

Run the dependency-free headless suite with:

```sh
bash scripts/test.sh
```

SQLite integration tests run when `kkharji/sqlite.lua` is available on
`runtimepath`; otherwise that one group is reported as skipped.
