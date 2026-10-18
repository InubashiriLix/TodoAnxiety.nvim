package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
vim.env.XDG_STATE_HOME = vim.fn.tempname()
require("todo.config").setup({
    db_path = vim.fn.tempname() .. ".db",
    reminders = { enabled = false },
    ai = { enabled = true, api_key = "mock-flow" },
})
local store = require("todo.store").open(require("todo.config").get().db_path)
local ws = require("todo.workspace").new(store)
local svc = require("todo.service").new(store)
local planner = require("todo.planning").new(ws, svc)
local today = "2026-10-18"
local yesterday = "2026-10-17"
local function task(title, date, plan_date)
    local value = assert(svc:create({ title = title, description = title .. " description" }))
    if plan_date then
        planner:add(value.sync_uuid, plan_date)
    end
    return value
end
local a = task("Today task", today, today)
local b = task("Yesterday leftover", yesterday, yesterday)
local c = task("Unplanned active", today)
local ai = require("todo.ai").new(ws, svc, {
    transport = function(_, cb)
        cb("not used")
        return { running = false, cancel = function() end }
    end,
})
local daily = require("todo.ai.daily")
local today_ctl = daily.new(ws, svc, ai, today, { view = "today" })
local uuids = {}
for _, entry in ipairs(today_ctl.state.queue) do
    uuids[entry.uuid] = true
    assert(entry.selected == false, "AI planning must start with nothing selected")
end
assert(uuids[a.sync_uuid] and uuids[b.sync_uuid], "today scope must include today's plan and yesterday leftovers")
assert(not uuids[c.sync_uuid], "today scope must not include every active task")

local active_ctl = daily.new(ws, svc, ai, today, { view = "active", task_uuids = { c.sync_uuid } })
assert(active_ctl.id ~= today_ctl.id, "view sessions must be isolated")
assert(#active_ctl.state.queue == 1 and active_ctl.state.queue[1].uuid == c.sync_uuid)
active_ctl.state.queue[1].selected = true
active_ctl:save()
local marks = require("todo.ui.task_mark").marks(ws, svc, today, "active")
assert(marks.ai[c.sync_uuid], "AI selection marks must include selected tasks")

local round = require("todo.ai.questions").normalize({
    questions = {
        { id = "q1", header = "One", question = "First?", options = { { id = "a", label = "A" }, { id = "b", label = "B" }, { id = "c", label = "C" } } },
        { id = "q2", header = "Two", question = "Second?", options = { { id = "a", label = "A" }, { id = "b", label = "B" }, { id = "c", label = "C" } } },
    },
}, 4)
assert(not require("todo.ai.questions").validate(round))
round.answers.q1 = { selected = { a = true }, notes = {} }
assert(not require("todo.ai.questions").validate(round), "one unanswered question still blocks")
round.answers.q2 = { selected = {}, notes = { a = "explain without selecting" } }
assert(require("todo.ai.questions").validate(round), "an option note counts as an explanation")

local owner = require("todo.ui.daily").open({ date = today, view = "today" })
assert(owner.show_composer == false, "empty supplementary composer starts hidden")
assert(owner.controller.id == today_ctl.id)
require("todo.ui.daily").close()
print("ok - daily scope (today + yesterday), per-view sessions, AI marks, answer validation and hidden empty composer")
vim.cmd("qa!")
