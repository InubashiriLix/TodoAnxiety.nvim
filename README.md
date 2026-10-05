# todo.nvim

![Neovim](https://img.shields.io/badge/Neovim-0.10%2B-blue?logo=neovim)
![License](https://img.shields.io/badge/license-WTFPL-blue)

[English](README.md) | [简体中文](README.zh-CN.md)

A focused, local task manager for Neovim with a responsive dashboard, structured
task forms, and SQLite persistence. Tasks can be ranked by a transparent
combination of deadline and priority, so the emergency view answers “what
should I do next?”

<https://github.com/user-attachments/assets/2d69b477-6317-413d-8381-6ce3469251cc>

## Contents

- [Requirements](#requirements)
- [Usage](#usage)
- [Dashboard and form](#dashboard-and-form)
- [Configuration](#configuration)
- [Multi-device sync](#multi-device-sync)
- [Emergency ranking](#emergency-ranking)
- [Data and lifecycle](#data-and-lifecycle)
- [Development](#development)

## Requirements

- Neovim 0.10+
- [`kkharji/sqlite.lua`](https://github.com/kkharji/sqlite.lua)
- [`MunifTanjim/nui.nvim`](https://github.com/MunifTanjim/nui.nvim)
- [`folke/which-key.nvim`](https://github.com/folke/which-key.nvim) v3 (optional,
  for the dedicated keymap icon column)
- A system SQLite shared library (`libsqlite3.so`, `libsqlite3.dylib`, or
  `sqlite3.dll`)
- Neovim's bundled `markdown`/`markdown_inline` treesitter parsers, for
  markdown rendering in the detail pane and description editor (present in
  stock Neovim; if missing, rendering silently falls back to plain text)

> **Known incompatibility:** since the detail pane and description editor set
> `filetype = markdown`, any installed markdown-rendering plugin that attaches
> via `FileType markdown` will try to render them too. This is usually
> harmless, but plugins that defer their setup with a timer and don't
> re-check buffer validity when it fires can error if the popup is closed in
> that window (e.g. `mdmath.nvim`, which defers ~100ms). todo.nvim reuses one
> long-lived buffer for both detail surfaces to shrink that race, but cannot
> eliminate it for every third-party plugin. If you hit an error like this,
> it's worth reporting to that plugin, or setting `ui.markdown = false` to
> opt the detail pane out of `filetype = markdown` entirely.

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
:Todo notice Take a shower    " create a notice
:Todo open notices            " list active notices
:Todo tags                    " open the tag manager
:Todo done 42                " complete task 42
:Todo archive 42             " archive while keeping the task recoverable
:Todo delete 42              " permanently delete an archived task
:Todo restore 42
```

All commands use the single `:Todo` entry point:

```text
open [float|sidebar] [active|emergency|by_urgency|by_time|by_tag|notices|archived]
toggle [float|sidebar]
add [title]
notice [title]
tags
sync [status]
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
| `<leader>Tn` | Add a notice             |

The dashboard footer shows common context-sensitive actions. Press `?` to show
the complete help. Existing global mappings are never overwritten.

The `/` search input closes as soon as focus moves away from it. A floating
dashboard also closes whenever focus enters a regular editing window, while
its own detail, menu, search, and tag-manager windows are treated as part of
todo.nvim. A sidebar remains available after focus returns to the editor.
Window-navigation mappings such as `Ctrl-j/k` are never overridden.

In the archived view, select a task and press `D` to open a confirmation menu;
Cancel is selected by default to prevent an accidental Enter from deleting it.
`:Todo delete [id]` provides the command equivalent. Only archived tasks can be
permanently deleted, and deletion cannot be undone.

## Dashboard and form

The floating dashboard uses a task list and fixed detail pane when at least 100
columns are available. Narrow floats and the sidebar use two-line task cards;
press Enter to open the selected task in a detail popup.

The detail pane and popup render the task as markdown: title, status,
priority, deadline, urgency, and tags as a field list, followed by the
description exactly as typed. `filetype` is set to `markdown`, so a rendering
plugin such as `MeanderingProgrammer/render-markdown.nvim`, if installed,
attaches automatically; without one, Neovim's built-in treesitter highlighting
still applies. Set `ui.markdown = false` to disable this and see the raw
markdown source instead. The description field in the add/edit form is the
same filetype, so writing lists, checkboxes, or fenced code there highlights
live and shows up rendered in the detail pane afterward.

### Views

Seven tabs are available; `[` and `]` cycle them, `v` opens a picker, and the
active tab is highlighted in the header. Tabs wrap onto extra header lines when
the window is too narrow to fit them on one.

| Tab | Grouping |
| --- | --- |
| Active | Open and closed tasks grouped by status |
| Emergency | Urgency-ranked flat list of candidates only |
| By level | Every open task grouped by urgency band: overdue, urgent, high, attention, priority only |
| By time left | Every open task ordered by time remaining, grouped into overdue, due today, this week, later, no deadline. Cards show a relative `in 3d 4h` label |
| By tag | A tree with one root per tag plus Untagged; a task with several tags appears under each of them |
| Notices | Reminders ordered by next trigger |
| Archived | Archived tasks, newest first |

Every section header can be folded: `<Tab>` or `za` toggles the section holding
the cursor, `zR` expands all, and `zM` collapses all. Folds are remembered per
view for as long as the panel stays open. `j` and `k` walk section headers as
well as tasks, so the tag view navigates like a tree. Search and the status,
priority, and tag filters apply on top of whichever view is active.

Escape unwinds one layer at a time. In the search box it clears the query,
closes the input, and returns the cursor to the list, from either Normal or
Insert mode. In a menu, help popup, or detail overlay it closes that window. On
the list it clears any active filters, or closes the panel when none are set.

Notices handle short-lived reminders such as “take a shower in five minutes.”
Create one with `:Todo notice [title]`; its trigger accepts `30s`, `5m`, `2h`,
or an exact date, and `c` opens the keyboard calendar and unrestricted time
editor. Recurrence supports once, daily, weekdays, selected weekdays, and every
N minutes, hours, or days. The repeat interval remembers its last value. Press
`t` on that field for a four-part days/hours/minutes/seconds picker, or keep
typing compact values such as `5m` directly.

When due, todo.nvim plays a sound and focuses a reminder popup: `d` completes
the occurrence, `s` snoozes by a relative duration, `a` archives permanently,
and `q` closes only the current popup. Unhandled items continue at their own
repeat interval. Missed reminders fire immediately when Neovim starts or the
machine resumes; no sound can play while Neovim is completely stopped.

The add/edit form uses separate controls instead of parsing a text buffer:

- A title input with inline validation
- A visible P0–P3 priority selector (`0`–`3`, arrow keys, or Enter menu) and a
  four-part status selector (`1`–`4`, arrow keys, or Enter menu)
- A keyboard calendar for choosing the date and an unrestricted time editor:
  type `HHMM` directly, adjust by one or five minutes/hours, or keep the task
  date-only. The picker shows date, hour, and minute together and rolls the date
  when crossing midnight. No fixed time presets or hidden mouse-only date buttons.
- A dedicated tag panel for selecting, creating, renaming, deleting, filtering,
  and inspecting usage counts; press Enter on an empty tag field, then use
  `j`/`k` and Enter/Space to toggle tags. You can also
  manage tags globally with `:Todo tags`/`<leader>Tg`. Deleting a tag removes
  that tag from every associated task after confirmation; tasks are not deleted.
- An independent multi-line description editor

Use Tab and Shift-Tab to move between fields, `<C-s>` to save, and `q` or Escape
in Normal mode, or `<C-q>` from either mode, to close. In Insert mode Escape
still only leaves Insert, so it never closes a field you are typing in. Unsaved
forms ask whether to save, discard, or continue editing. todo.nvim registers no mouse mappings; every plugin action
uses one visible keyboard path. When a form is opened from a dashboard,
the dashboard is suspended and restored afterward so the two interfaces never
overlap.

## Configuration

```lua
require("todo").setup({
  db_path = vim.fn.stdpath("data") .. "/todo.nvim/todo.db",
  language = "en", -- "en" or "zh-CN"
  -- Optional manual sync. Use a dedicated private, empty Git repository.
  -- Configure Git credentials on each device, then run :Todo sync.
  sync = {
    enabled = false, -- Change to true after setting your remote.
    remote = "", -- e.g. "git@github.com:YOUR_NAME/private-todos.git"
    branch = "main", -- Same remote and branch on every device.
  },
  ui = {
    default_mode = "float", -- "float" or "sidebar"
    -- "active", "emergency", "by_urgency", "by_time", "by_tag", "notices", or
    -- "archived"
    default_view = "active",
    -- Render the detail pane and description editor as markdown.
    markdown = true,
    float = { width = 0.80, height = 0.75, border = "rounded" },
    sidebar = { width = 42, side = "right" },
  },
  -- Each entry is the full key string, or false to disable.
  keymaps = {
    toggle = "<leader>Tt",
    add = "<leader>Ta",
    open_float = "<leader>Tf",
    open_sidebar = "<leader>Ts",
    open_emergency = "<leader>Te",
    manage_tags = "<leader>Tg",
    add_notice = "<leader>Tn",
  },
  -- Optional which-key v3 icon metadata.
  -- A plain string is also accepted; use false or "" to disable one icon.
  icons = {
    toggle = { icon = "\u{f204}", color = "yellow" },
    add = { icon = "\u{f067}", color = "green" },
    open_float = { icon = "\u{eb7f}", color = "blue" },
    open_sidebar = { icon = "\u{f03c7}", color = "cyan" },
    open_emergency = { icon = "\u{f071}", color = "orange" },
    manage_tags = { icon = "\u{f02c}", color = "purple" },
    add_notice = { icon = "\u{f0f3}", color = "orange" },
  },
  reminders = {
    enabled = true,
    sound = {
      path = "/path/to/reminder.ogg",
      command = { "mpv", "--no-video", "--really-quiet" },
    },
  },
})
```

When which-key v3 is available, todo.nvim passes these values through
`which-key.add()` as native `icon` metadata. The popup therefore renders a
separate, aligned, color-highlighted icon column. Without which-key, the
mappings still work and their descriptions remain clean text.

The sound command is executed as an argv list without a shell. Set `command`
to `false` to auto-detect `mpv`, `ffplay`, `paplay`, or `afplay`; an empty path,
unreadable file, or missing player falls back to the terminal bell. A repeat
interval is required when a regular task has a deadline; tasks without a
deadline do not create reminders.

The plugin stores one global database rather than one database per project.
Back up the configured `.db` file after closing Neovim, or use SQLite's backup
tools while it is open.

## Multi-device sync

Optional Git sync works with a local SQLite database on each macOS or Linux
device. Install Git 2.28+ and use the same updated plugin version everywhere.
Only `:Todo sync` accesses the remote: there is no background, startup, focus,
or shutdown sync. You can keep editing offline.

1. Create a dedicated **private, empty Git repository**, without a README,
   license, or `.gitignore`. Do not use the plugin source repository.
2. Configure Git authentication on each device. For SSH, complete the initial
   host-key verification in a terminal and load your key into an agent. For
   HTTPS, use your Git credential helper. Sync cannot answer interactive prompts.
3. On the device containing your existing todos, add this to your setup and run
   `:Todo sync`:

   ```lua
   require("todo").setup({
     sync = {
       enabled = true, -- disabled by default
       remote = "git@github.com:YOUR_NAME/private-todos.git",
       branch = "main",
     },
   })
   ```

4. On your Mac or another device, install the plugin and dependencies, use the
   same sync configuration with a fresh local database, then run `:Todo sync`.
   No database copying or manual Git checkout is needed.
5. Run `:Todo sync` on the device you are leaving, then on the device you are
   switching to. Both devices may also edit offline and sync later.

`:Todo sync status` reports the last success, pending local records, latest
error, and cache path. It does **not** check the remote. `:checkhealth todo`
checks Git and local paths without accessing the network. The equivalent Lua
entry points are `require("todo").sync()` and `require("todo").sync_status()`.

While syncing, a non-focusable card shows preparation, download, merge, local
update, upload, elapsed time, and retries. It remains visible throughout network
waits, independently of notification plugins. Completion stays visible for eight
seconds and reports this run's uploaded/downloaded change records (not task
counts); an unchanged sync explicitly says everything is up to date. Failures
remain visible for fifteen seconds. Final results also appear in `:messages`.
Edits still pending after completion are called out for the next manual sync.

Tasks, notices, tags, archives, deletions, reminder rules, occurrence completion,
and snoozes sync. Sound paths, UI preferences, last-used input values, and bell
delivery progress stay local. Both devices can ring while disconnected. Due
date text keeps its existing local-time meaning; scheduled reminder instants
are shared as Unix timestamps. Daily/weekly recurrence is advanced using the
timezone of the device completing the occurrence.

Concurrent edits use the newer **whole task**, including its tags and reminder
configuration. There is no field-by-field merge. Millisecond timestamps,
logical sequence numbers, and device identities provide a deterministic order;
incorrect device clocks can still affect concurrent offline edits. UUIDs
identify tasks across devices; numeric IDs in `:Todo done 42` are local and
may differ. An open form refuses to overwrite a task changed since it opened;
copy unsaved text and reopen it before saving.

The plugin stores immutable JSON transactions in Git and keeps the SQLite
database local. Its managed Git directory is `<db_path>.sync`. Do not edit or
commit files there manually, and do not place the live database in a synced
folder. Tag deletion suppresses old associations; recreating that name does
not restore them. Deleting tasks removes them from current lists but **retains
their old content in SQLite sync history and Git history**. History pruning
and encryption beyond your Git transport/provider are not included.

Network/authentication failures retain pending records. Fix authentication or
connectivity and run `:Todo sync` again. A sync process has a 30-second timeout
per Git command, retries concurrent pushes up to three attempts, and never
force-pushes. Changes made during a running sync can remain pending until the
next invocation. Invalid or unsupported remote data leaves the database
unchanged for that import batch; preserve the database and inspect the reported
record/format error rather than overwriting either copy.

Schema v3 adds UUIDs and a durable change journal even with sync disabled. An
existing database gets a consistent `<db_path>.pre-sync-<uuid>.db` backup before
migration; keep it if you need to roll back to an older plugin version. Disabling
sync preserves local use. For cache recovery, close Neovim, move only
`<db_path>.sync` aside, then reopen and sync; the database journal rebuilds it.
Keep the same remote and branch for a database; use a separate `db_path` for a
different sync repository. Initialize secondary devices from an empty database,
since independently migrated copies of an old database get different UUIDs.

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

Tasks have a title, multi-line markdown description, status, P0–P3 priority,
optional deadline, and zero or more tags. Statuses are `todo`, `in_progress`,
`done`, and `cancelled`. Tasks can be archived, restored, and—only after they
have been archived—permanently deleted. Notices and task deadlines persist
their reminder state. Existing databases migrate to schema v3 without enabling
sound for old tasks until a reminder interval is saved.

## Development

Run the dependency-free headless suite with:

```sh
bash scripts/test.sh
```

SQLite integration tests run when `kkharji/sqlite.lua` is available on
`runtimepath`; NUI integration tests similarly require `nui.nvim`. The test
script automatically detects the usual lazy.nvim paths, or accepts
`TODO_SQLITE_PATH` and `TODO_NUI_PATH`.

With SQLite available, the suite also runs two-device sync tests against local
bare Git repositories, without GitHub credentials or network access. CI runs
on Linux and macOS with Neovim 0.10.4 and the current stable release.
