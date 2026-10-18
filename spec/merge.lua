package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
vim.env.XDG_STATE_HOME = vim.fn.tempname()
require("todo.config").setup({
    db_path = vim.fn.tempname() .. ".db",
    reminders = { enabled = false },
    ai = { enabled = false },
})
local store = require("todo.store").open(require("todo.config").get().db_path)
local svc = require("todo.service").new(store)
local ws = require("todo.workspace").new(store)
local planner = require("todo.planning").new(ws, svc)
local task = assert(svc:create({ title = "Normal task", priority = 2 }))
local notice = assert(svc:create({
    kind = "notice",
    title = "Daily standup",
    trigger = "2026-10-19 09:00",
    reminder_interval = "1m",
    recurrence = { kind = "daily", every = 1 },
}))
local active = svc:list("active")
assert(#active == 2, "active view must include notices and tasks")
assert(#svc:list("notices") == 1, "notices view must remain a dedicated filter")
local stats = svc:stats()
assert(stats.active == 2 and stats.notices == 1, vim.inspect(stats))
planner:add(notice.sync_uuid)
assert(#planner:today().items == 1, "notice can be planned as a task")
assert(#svc:list("today") == 1, "notice appears in Today")
store:close()
print("ok - notices merge into task views while keeping a notices-only management view")
vim.cmd("qa!")
