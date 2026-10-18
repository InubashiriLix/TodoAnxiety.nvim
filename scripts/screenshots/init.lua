-- Screenshot entry point. Keeps all demo state under scripts/screenshots/.demo
-- and never touches the real database configured by the user.
local root = vim.fn.getcwd()

local function add_rtp(path)
    if path and path ~= "" and vim.fn.isdirectory(path) == 1 then
        vim.opt.rtp:append(path)
    end
end

add_rtp(root)
add_rtp(vim.env.TODO_NUI_PATH or vim.fn.expand("~/.local/share/nvim/lazy/nui.nvim"))
add_rtp(vim.env.TODO_SQLITE_PATH or vim.fn.expand("~/.local/share/nvim/lazy/sqlite.lua"))
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. root .. "/scripts/?.lua;" .. package.path

vim.g.mapleader = " "
vim.o.background = "dark"
vim.o.termguicolors = true
vim.o.number = false
vim.o.relativenumber = false
vim.o.signcolumn = "no"
vim.o.laststatus = 0
vim.o.ruler = false
vim.o.showcmd = false
vim.o.more = false
vim.o.wrap = true
vim.o.scrolloff = 0
vim.o.sidescrolloff = 0
vim.o.fillchars = "eob: "
vim.o.guicursor = "a:Normal"
pcall(function()
    vim.o.cmdheight = 0
end)
vim.notify = function() end

local demo = root .. "/scripts/screenshots/.demo"
if vim.env.TODO_DEMO_RESET ~= "0" then
    vim.fn.delete(demo, "rf")
end
vim.fn.mkdir(demo, "p")

local language = vim.env.TODO_DEMO_LANG or "zh-CN"
local screen = vim.env.TODO_DEMO_SCREEN or "active"

local todo = require("todo")
todo.setup({
    db_path = demo .. "/todo.db",
    language = language,
    core = { bin = root .. "/core/target/release/todo-core" },
    keymaps = { enabled = false },
    reminders = { enabled = false },
    ai = {
        enabled = true,
        provider = "deepseek",
        api_key = "demo-key-not-used",
        max_rounds = 10,
        max_requests = 20,
    },
    ui = {
        default_mode = "float",
        default_view = "active",
        markdown = true,
        float = { width = 0.94, height = 0.88, border = "rounded" },
        sidebar = { width = 46, side = "right" },
    },
    planning = { capacity_minutes = 480 },
})

local seed = require("screenshots.seed").seed(todo)
local tasks = seed.tasks

local function open(view, id)
    todo.open({ mode = "float", view = view, selected_id = id })
end

local function cursor_to_end()
    vim.defer_fn(function()
        local win = vim.api.nvim_get_current_win()
        local buf = vim.api.nvim_win_get_buf(win)
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local line = lines[#lines] or ""
        vim.api.nvim_win_set_cursor(win, { math.max(1, #lines), #line })
    end, 700)
end

if screen == "active" then
    open("active", tasks.release.id)
elseif screen == "emergency" then
    open("emergency", tasks.sync.id)
elseif screen == "by_urgency" then
    open("by_urgency", tasks.ai.id)
elseif screen == "by_time" then
    open("by_time", tasks.release.id)
elseif screen == "by_tag" then
    open("by_tag", tasks.readme.id)
elseif screen == "notices" then
    open("notices", tasks.notice.id)
elseif screen == "archived" then
    open("archived", tasks.archived.id)
elseif screen == "today" then
    todo.today()
elseif screen == "plan" then
    todo.plan()
elseif screen == "routines" then
    todo.routines()
elseif screen == "tags" then
    todo.tags()
elseif screen == "edit" then
    todo.edit(tasks.ai.id)
    cursor_to_end()
elseif screen == "notice" then
    todo.notice({ title = language == "zh-CN" and "喝水" or "Drink water" })
    cursor_to_end()
elseif screen == "routine_form" then
    local value = seed.routine.value
    require("todo.ui.notice_form").open({
        title = value.title,
        description = value.description,
        tags = value.tags,
        due_date = value.start_date,
        due_time = value.time,
        reminder = {
            repeat_interval_seconds = 3600,
            recurrence = value.recurrence,
            scheduled_at = 0,
            next_reminder_at = 0,
        },
    }, function() end, { routine = true })
    cursor_to_end()
elseif screen == "chat" then
    require("todo.ui.planner").chat({ session_id = seed.session.id })
elseif screen == "help" then
    open("active", tasks.release.id)
    vim.defer_fn(function()
        vim.api.nvim_feedkeys("?", "xt", false)
    end, 300)
else
    error("unknown TODO_DEMO_SCREEN: " .. screen)
end

-- Keep the last frame stable for VHS/ffmpeg. The timer also lets the layout
-- finish reflowing after the initial render.
vim.defer_fn(function()
    vim.cmd("redraw")
end, 400)
