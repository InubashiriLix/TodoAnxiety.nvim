package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
vim.env.XDG_STATE_HOME = vim.fn.tempname()
require("todo.config").setup({
    db_path = vim.fn.tempname() .. ".db",
    reminders = { enabled = false },
    ai = { enabled = false },
})
local store = require("todo.store").open(require("todo.config").get().db_path)
local ws = require("todo.workspace").new(store)
local svc = require("todo.service").new(store)
local routines = require("todo.routines")
local planner = require("todo.planning").new(ws, svc)

local daily, _ = routines.create(ws, svc, {
    title = "Morning review",
    description = "Check the day",
    start_date = "2026-10-19",
    time = "09:00",
    recurrence = { kind = "daily", every = 1 },
    auto_today = true,
}, "2026-10-19")
assert(daily)
assert(#svc:list("active") == 1, "daily routine should materialise one task")
assert(#planner:today("2026-10-19").items == 1, "auto_today should add the occurrence")
assert(routines.run(ws, svc, "2026-10-19") == 0, "the same day must not duplicate")
assert(routines.run(ws, svc, "2026-10-20") == 1)
assert(#svc:list("active") == 2)
local occurrence = svc.store:list({ archived = false })[1]
assert(occurrence.due_time == "09:00" and occurrence.reminder, "occurrence keeps time and reminder")

local weekly = {
    title = "Weekly review",
    start_date = "2026-10-19",
    time = "18:00",
    recurrence = { kind = "weekly", every = 2, weekdays = { 2, 4 } },
    auto_today = false,
}
local id = routines.create(ws, svc, weekly, "2026-10-19")
assert(routines.matches(weekly.recurrence, weekly.start_date, "2026-10-19"))
assert(not routines.matches(weekly.recurrence, weekly.start_date, "2026-10-20"))
assert(routines.matches(weekly.recurrence, weekly.start_date, "2026-11-02"), "every two weeks skips the off week")
local dates = routines.occurrences(weekly.recurrence, weekly.start_date, 3)
assert(#dates == 3 and dates[1] == "2026-10-19" and dates[2] == "2026-10-21", vim.inspect(dates))

local monthly = { kind = "monthly", every = 1, day_of_month = 31 }
assert(routines.matches(monthly, "2026-01-31", "2026-01-31"))
assert(not routines.matches(monthly, "2026-01-31", "2026-02-28"))
assert(routines.matches(monthly, "2026-01-31", "2026-03-31"))
local last = { kind = "monthly", every = 1, day_of_month = -1 }
assert(routines.matches(last, "2026-01-31", "2026-02-28"))

routines.set_enabled(ws, svc, id, false)
routines.set_enabled(ws, svc, daily, false)
assert(routines.run(ws, svc, "2026-11-02") == 0, "disabled routines do not materialise")
routines.delete(ws, id)
assert(not routines.get(ws, id))

store:close()
print("ok - routines materialise daily/weekly/monthly occurrences once and respect enable/delete")
vim.cmd("qa!")
