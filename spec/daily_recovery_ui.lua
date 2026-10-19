package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
vim.env.XDG_STATE_HOME = vim.fn.tempname()
require("todo.config").setup({
    db_path = vim.fn.tempname() .. ".db",
    reminders = { enabled = false },
    ai = { enabled = true, api_key = "mock-ui-retry" },
})
local todo = require("todo")
local svc = todo._service()
local first = assert(svc:create({ title = "Activation", description = "Activate the service." }))
local second = assert(svc:create({ title = "Second activation", description = "Activate the service." }))
local planner = require("todo.planning").new(svc.store.workspace, svc)
planner:add(first.sync_uuid)
planner:add(second.sync_uuid)
local calls = 0
local note_sent = false
local ai = require("todo.ai").new(svc.store.workspace, svc, {
    transport = function(opts, cb)
        calls = calls + 1
        local index = calls
        if vim.json.encode(opts.body.messages):find("Check each morning and evening.", 1, true) then
            note_sent = true
        end
        local context = vim.json.decode(opts.body.messages[2].content:match("Workspace snapshot:\n(.*)"))
        vim.defer_fn(function()
            if index == 2 or index == 4 or index == 6 then
                cb("HTTP 503", nil)
                return
            end
            local result
            if index == 1 then
                result = {
                    action = "question",
                    message = "When?",
                    questions = {
                        { id = "q", question = "When to check?", options = { { id = "a", label = "Waiting" }, { id = "b", label = "Actively following up" }, { id = "c", label = "Blocked" } } },
                    },
                }
            elseif context.reviews then
                result = { action = "draft", summary = "Ready", changes = {} }
            else
                result = {
                    action = "item_review",
                    summary = "Understood",
                    review = { minutes = 10, next_action = "Check payment", completion = "Active" },
                    changes = {},
                }
            end
            result.understanding = {
                goal_clear = true,
                goal = "Activate",
                deliverable = "Service active",
                unknowns = {},
                evidence = { "Activate the service." },
            }
            cb(nil, {
                choices = { { finish_reason = "stop", message = { content = vim.json.encode(result) } } },
                usage = { prompt_tokens = 5, completion_tokens = 5 },
            })
        end, 20)
        return {
            running = true,
            cancel = function()
                cb("cancelled")
            end,
        }
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
    vim.wait(70)
end
local function done(status)
    assert(
        vim.wait(5000, function()
            return not ctl.busy
        end, 5),
        "request remained busy"
    )
    assert(ctl.state.status == status, ctl.state.last_error or ctl.state.status)
    vim.wait(70)
end
press("<Space>")
press("j")
press("<Space>")
press("<CR>w")
done("awaiting")
local round = ctl.cache.rounds[ctl:item_id(ctl:current())]
round.answers.q = { selected = { a = true }, notes = { a = "Check each morning and evening." } }
ctl:submit(nil, round)
done("paused")
assert(calls == 2 and ctl.state.last_error)
assert(note_sent, "option notes must reach the outgoing AI request")
ui.close()
o = todo.plan()
vim.api.nvim_set_current_win(o.questions.winid)
press("e")
vim.cmd("stopinsert")
assert(vim.api.nvim_buf_get_lines(o.composer.bufnr, 0, -1, false)[1] == "Check each morning and evening.")
press("<CR>r")
done("paused")
assert(calls == 4, "second task should pause on its first request")
local previous_key = o.composing_key
local previous_note = "Check each morning and evening."
assert(vim.api.nvim_buf_get_lines(o.composer.bufnr, 0, -1, false)[1] == previous_note)
assert(o.contexts[previous_key].entry.uuid ~= ctl:current().uuid, "fixture needs a retained previous-task editor")
press("w")
done("paused")
assert(calls == 6, "continue must retry the second task, then attempt final assembly")
assert(not ctl:current(), "assembly has no current task")
press("w")
done("review")
assert(calls == 7, "continue must retry assembly without submitting an empty answer")
assert(not ctl.state.last_error)
assert(ctl.cache.drafts[previous_key] == previous_note, "continue discarded the old option note")
local session = ctl:item(ctl.state.queue[1])
local user_count = 0
for _, m in ipairs(session.messages) do
    if m.role == "user" then
        user_count = user_count + 1
    end
end
assert(user_count == 2, "retry duplicated the user answer")
assert(session.messages[3].display:find("Check each morning and evening.", 1, true))
local second = ctl:item(ctl.state.queue[2])
local second_users = 0
for _, m in ipairs(second.messages) do
    if m.role == "user" then
        second_users = second_users + 1
        assert(not m.content:find(previous_note, 1, true), "old note leaked into the next task")
    end
end
assert(second_users == 1, "continue duplicated the next task's workflow message")
ui.close()
assert(#vim.api.nvim_list_wins() == 1, "recovery leaked a window")
print("ok - UI note/preview, failed submit/reopen/retry, continue with retained task notes and failed final assembly")
vim.cmd("qa!")
