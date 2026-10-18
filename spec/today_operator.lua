package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
vim.env.XDG_STATE_HOME = vim.fn.tempname()
require("todo.config").setup({
    db_path = vim.fn.tempname() .. ".db",
    reminders = { enabled = false },
    ai = { enabled = false },
})
local todo = require("todo")
local svc = todo._service()
local planner = require("todo.planning").new(svc.store.workspace, svc)
for index = 1, 5 do
    assert(svc:create({ title = "Range " .. index, priority = 2 }))
end
local panel = require("todo.ui.panel")
panel.open({ mode = "float", view = "active" })
vim.wait(80)
local function press(keys)
    vim.fn.feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt")
    vim.wait(80)
end
local function count()
    return #planner:today(planner:date()).items
end
local function clear()
    planner:transaction("Clear", function()
        local p = planner:today(planner:date())
        p.items = {}
        svc.store.workspace:put("plan", p.date, p)
    end)
    panel.refresh()
    vim.wait(50)
    press("gg")
    press("j")
end
local function expected_from(direction)
    local state = panel.inspect_state()
    local total = 0
    local first, last = state.cursor_row, direction > 0 and #state.rows or 1
    local step = direction
    for index = first, last, step do
        if state.rows[index] and state.rows[index].kind == "task" then
            total = total + 1
        end
    end
    return total
end
-- Plain t still toggles the current task immediately.
press("t")
assert(count() == 1, "plain t must toggle the current task, got " .. count())
clear()
-- Tj marks current + one below (2 items).
press("Tj")
assert(count() == 2, "Tj must mark two tasks, got " .. count())
-- T3j marks three tasks from the current row.
clear()
press("T3j")
assert(count() == 3, "T3j must mark three tasks, got " .. count())
-- Tgg marks current through the first task.
clear()
press("j")
press("j")
local expected_up = expected_from(-1)
press("Tgg")
assert(count() == expected_up, "Tgg must mark current through first: " .. count() .. " vs " .. expected_up)
-- TG marks current through the last task.
clear()
press("j")
press("j")
local expected_down = expected_from(1)
press("TG")
assert(count() == expected_down, "TG must mark current through last: " .. count() .. " vs " .. expected_down)
panel.close()
print("ok - t toggles one task; T supports Tj, T3j, Tgg and TG")
vim.cmd("qa!")
