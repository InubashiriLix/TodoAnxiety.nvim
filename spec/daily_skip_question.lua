package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
vim.env.XDG_STATE_HOME = vim.fn.tempname()
require("todo.config").setup({
    db_path = vim.fn.tempname() .. ".db",
    reminders = { enabled = false },
    ai = { enabled = true, api_key = "mock-skip-question" },
})
local todo = require("todo")
local svc = todo._service()
local ws = svc.store.workspace
local task = assert(svc:create({ title = "Skip question test", description = "Original description" }))
require("todo.planning").new(ws, svc):add(task.sync_uuid)
local bodies = {}
local asked = false
local ai = require("todo.ai").new(ws, svc, {
    transport = function(opts, cb)
        local body = vim.deepcopy(opts.body)
        bodies[#bodies + 1] = body
        local sent = vim.json.encode(body)
        local result
        if sent:find("DAILY FINAL PLANNING", 1, true) then
            local snapshot = vim.json.decode(body.messages[2].content:match("Workspace snapshot:\n(.*)"))
            local changes = {}
            for index, item in ipairs(snapshot.tasks) do
                changes[#changes + 1] = {
                    kind = "plan_add",
                    task_ref = item.task_ref,
                    after = { minutes = 10, group = "next", position = index },
                }
            end
            result = { action = "draft", summary = "Final plan", changes = changes }
        elseif not asked then
            asked = true
            result = {
                message = "Two questions",
                action = "question",
                understanding = {
                    goal_clear = false,
                    goal = "",
                    deliverable = "",
                    unknowns = { "Goal", "Timing" },
                    evidence = {},
                },
                questions = {
                    {
                        id = "q1",
                        intent = "goal",
                        header = "Goal",
                        question = "What is the goal?",
                        options = {
                            { id = "a1", label = "Goal A" },
                            { id = "b1", label = "Goal B" },
                            { id = "c1", label = "Goal C" },
                        },
                    },
                    {
                        id = "q2",
                        intent = "scope",
                        header = "Scope",
                        question = "What is in scope?",
                        options = {
                            { id = "a2", label = "Scope A" },
                            { id = "b2", label = "Scope B" },
                            { id = "c2", label = "Scope C" },
                        },
                    },
                },
            }
        else
            result = {
                message = "Reviewed",
                action = "item_review",
                summary = "Reviewed",
                understanding = {
                    goal_clear = true,
                    goal = "Skip question test",
                    deliverable = "Delivered",
                    unknowns = {},
                    evidence = { "Skip question test" },
                },
                review = { minutes = 10, next_action = "Do it", completion = "Done" },
                changes = {},
            }
        end
        vim.defer_fn(function()
            cb(nil, {
                choices = { { finish_reason = "stop", message = { content = vim.json.encode(result) } } },
                usage = { prompt_tokens = 5, completion_tokens = 5 },
            })
        end, 20)
        return { running = true, cancel = function() end }
    end,
})
todo._ai = function()
    return ai
end
local ui = require("todo.ui.daily")
local o = todo.plan()
local ctl = o.controller
local function press(key)
    vim.fn.feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "xt")
    vim.wait(100)
end
local function wait_done()
    assert(
        vim.wait(5000, function()
            return not ctl.busy
        end, 5),
        "request remained busy"
    )
    vim.wait(120)
end
-- s toggles deferred in preparation, and the same key restores it.
vim.api.nvim_set_current_win(o.questions.winid)
press("<Space>")
press("s")
assert(ctl.state.queue[1].deferred, "s must defer the selected task during preparation")
assert(ctl:progress().deferred == 1)
assert(ctl.state.events[#ctl.state.events].kind == "deferred")
press("s")
assert(not ctl.state.queue[1].deferred, "s must restore a deferred task")
assert(ctl:progress().deferred == 0)
assert(ctl.state.events[#ctl.state.events].kind == "restored")
-- Start and skip the first of two questions.
press("<CR>")
press("w")
wait_done()
assert(ctl.state.status == "awaiting", ctl.state.last_error or ctl.state.status)
vim.api.nvim_set_current_win(o.questions.winid)
press("u")
assert(o.tab == 2, "u must advance to the next question")
local round = ctl.cache.rounds[ctl:item_id(ctl:current())]
assert(round.answers.q1.declined == true, "u must mark the question as declined")
assert(not round.answers.q1.selected.a1, "u must clear any selected option")
-- Answer the second question and submit.
press("<Space>")
press("w")
press("<CR>")
wait_done()
assert(not ctl.state.last_error, ctl.state.last_error)
local sent = false
for _, body in ipairs(bodies) do
    if vim.json.encode(body):find("no answer needed", 1, true) then
        sent = true
    end
end
assert(sent, "skipped questions must be sent as no-answer-needed")
local stored = false
for _, record in ipairs(ws:list("conversation")) do
    if record.value.scope == "daily_item" then
        for _, message in ipairs(record.value.messages or {}) do
            if message.role == "user" and tostring(message.content):find("no answer needed", 1, true) then
                stored = true
            end
        end
    end
end
assert(stored, "skipped question marker must remain in the stored answer")
ui.close()
require("todo.ui.daily").status()
local status_text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
assert(status_text:find("Todo status", 1, true), "status view must render")
assert(status_text:find("phase:", 1, true), "status view must include the phase")
vim.cmd("bwipeout!")
print("ok - u skips only the current question, s defers/restores tasks, and both are visible in events")
vim.cmd("qa!")
