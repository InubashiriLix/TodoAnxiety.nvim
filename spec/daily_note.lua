package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
vim.env.XDG_STATE_HOME = vim.fn.tempname()
require("todo.config").setup({
    db_path = vim.fn.tempname() .. ".db",
    reminders = { enabled = false },
    ai = { enabled = true, api_key = "mock-daily-note" },
})
local todo = require("todo")
local svc = todo._service()
local ws = svc.store.workspace
local task = assert(svc:create({ title = "Note test", description = "Original description" }))
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
                message = "Need the goal",
                action = "question",
                understanding = {
                    goal_clear = false,
                    goal = "",
                    deliverable = "",
                    unknowns = { "Goal" },
                    evidence = {},
                },
                questions = {
                    {
                        id = "q",
                        intent = "goal",
                        header = "Goal",
                        question = "What is the goal?",
                        options = {
                            { id = "a", label = "Option A" },
                            { id = "b", label = "Option B" },
                            { id = "c", label = "Option C" },
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
                    goal = "Note test",
                    deliverable = "Note delivered",
                    unknowns = {},
                    evidence = { "Note test" },
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
press("<Space>")
press("<CR>")
press("w")
wait_done()
assert(ctl.state.status == "awaiting", ctl.state.last_error or ctl.state.status)
vim.api.nvim_set_current_win(o.questions.winid)
press("e")
assert(vim.api.nvim_get_current_win() == o.composer.winid, "e must open the option note editor")
vim.api.nvim_buf_set_lines(o.composer.bufnr, 0, -1, false, { "NOTE_FROM_E" })
vim.wait(80)
press("<CR>")
local first = ctl:current()
local round = ctl.cache.rounds[ctl:item_id(first)]
assert(round.answers.q.notes.a == "NOTE_FROM_E", "note must be saved before submission")
vim.api.nvim_set_current_win(o.questions.winid)
press("<Space>")
press("w")
press("<CR>")
wait_done()
assert(not ctl.state.last_error, ctl.state.last_error)
local sent = false
for _, body in ipairs(bodies) do
    if vim.json.encode(body):find("NOTE_FROM_E", 1, true) then
        sent = true
    end
end
assert(sent, "note typed with e must reach the AI request")
local stored = false
for _, record in ipairs(ws:list("conversation")) do
    if record.value.scope == "daily_item" then
        for _, message in ipairs(record.value.messages or {}) do
            if message.role == "user" and tostring(message.content):find("NOTE_FROM_E", 1, true) then
                stored = true
            end
        end
    end
end
assert(stored, "note typed with e must remain in the stored answer")
assert(round.answers.q.notes.a == "NOTE_FROM_E", "submission must not clear the saved note")
ui.close()
print("ok - option notes typed with e are stored and sent to the AI")
vim.cmd("qa!")
