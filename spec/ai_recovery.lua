package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
vim.env.XDG_STATE_HOME = vim.fn.tempname()
require("todo.config").setup({ reminders = { enabled = false }, ai = { enabled = true, api_key = "mock-recovery" } })
vim.notify = function() end
local evidence = require("todo.ai.evidence")
assert(evidence.matches("Check every morning and evening", { "Check every morning\r\n  and evening" }))
assert(not evidence.matches("Check on the 23rd", { "Check on the 22nd" }))
assert(not evidence.matches("finished", { "not done" }))
assert(not evidence.matches("one two", { "one", "two" }))
assert(not evidence.matches(" \n ", { "text" }))
assert(not evidence.matches({}, { "text" }))
local store = require("todo.store").open(vim.fn.tempname() .. ".db")
local ws = require("todo.workspace").new(store)
local svc = require("todo.service").new(store)
for i = 1, 2 do
    assert(svc:create({ title = "Service " .. i, description = "Activate service\nWait for payment confirmation." }))
end
local requests, failed, edited = {}, false, false
local function result(snapshot, quote)
    return {
        action = "item_review",
        message = "Check payment",
        summary = "Understood",
        understanding = {
            goal_clear = true,
            goal = "Activate service",
            deliverable = "Service active",
            unknowns = {},
            evidence = { quote },
        },
        review = { minutes = 10, next_action = "Check payment", completion = "Payment confirmed" },
        changes = {},
    }
end
local ai = require("todo.ai").new(ws, svc, {
    transport = function(opts, cb)
        local body = vim.deepcopy(opts.body)
        requests[#requests + 1] = body
        local n = #requests
        local snapshot = vim.json.decode(body.messages[2].content:match("Workspace snapshot:\n(.*)"))
        local response
        if snapshot.reviews then
            local changes = {}
            for i, t in ipairs(snapshot.tasks) do
                changes[#changes + 1] =
                    { kind = "plan_add", task_ref = t.task_ref, after = { minutes = 10, group = "next", position = i } }
            end
            response = { action = "draft", summary = "Complete", changes = changes }
        elseif n == 1 or n == 5 then
            response = {
                action = "question",
                message = "When should we check?",
                understanding = {
                    goal_clear = true,
                    goal = "Activate service",
                    deliverable = "Service active",
                    unknowns = { "When" },
                    evidence = { "Activate service" },
                },
                questions = {
                    {
                        id = "when",
                        intent = "estimate",
                        question = "When?",
                        options = {
                            { id = "wait", label = "Mostly waiting" },
                        },
                    },
                },
            }
        elseif n == 2 or n == 3 then
            if n == 3 then
                local repair = body.messages[#body.messages].content
                assert(repair:find("Repair understanding.evidence", 1, true), repair)
                assert(repair:find("Check every morning", 1, true), "repair must offer current answer excerpts")
            end
            response = result(snapshot, "Expected completion on the 23rd") -- a paraphrase is not a quotation
        elseif n == 6 then
            failed = true
            vim.defer_fn(function()
                cb("HTTP 503", nil)
            end, 5)
            return { running = true, cancel = function() end }
        else
            response = result(snapshot, n == 4 and "Check every morning and evening" or "Activate service")
            if n == 7 then
                local sent = vim.json.encode(body.messages)
                assert(sent:find("Updated follow-up at noon", 1, true))
                assert(
                    not sent:find("Original follow-up", 1, true),
                    "edited failed answer must replace the pending submission"
                )
                edited = true
            end
        end
        local usage = n == 4 and { prompt_tokens = 10, completion_tokens = 5, prompt_cache_hit_tokens = "invalid" }
            or { prompt_tokens = 10, completion_tokens = 5 }
        vim.defer_fn(function()
            cb(nil, {
                choices = { { finish_reason = "stop", message = { content = vim.json.encode(response) } } },
                usage = usage,
            })
        end, 5)
        return { running = true, cancel = function() end }
    end,
})
local ctl = require("todo.ai.daily").new(ws, svc, ai, "2026-10-17")
local function wait()
    assert(
        vim.wait(5000, function()
            return not ctl.busy
        end, 5),
        "request hung"
    )
end
ctl.state.intent = "Spend the morning on activation"
ctl.state.locks_confirmed = true
assert(ctl:prepare())
ctl:start()
wait()
local first = ctl:current()
local round = ctl:item(first).round
round.answers.when = { selected = {}, notes = { wait = "Check every morning\n  and evening" } }
local transcript = require("todo.ai.questions").transcript(round)
assert(not transcript:find("unknown / skipped", 1, true), "notes must count as supplied information")
ctl:submit("", round)
wait()
assert(#requests == 3 and ctl.state.status == "paused" and ctl.state.last_error)
local session = ctl:item(first)
assert(session.round.status == "pending" and session.pending_request)
assert(session.questions == 1, "failed responses must not consume question rounds")
local messages = #session.messages
-- Upgrade recovery for an already failed session from the previous version.
session.pending_request = nil
session.round.status = "submitted"
ws:put("conversation", session.id, session)
ctl:start()
wait() -- retry saved answer, then advance to the second task
assert(#requests == 5 and ctl.state.status == "awaiting", ctl.state.last_error)
session = ctl:item(first)
assert(
    session.review and not session.pending_request and #session.messages == messages + 1,
    "retry duplicated a user message"
)
assert(ai:usage(ctl.id).unknown >= 1, "malformed provider usage must be unknown, never crash")
local second = ctl:current()
assert(first.uuid ~= second.uuid)
round = ctl:item(second).round
round.answers.when = { selected = {}, notes = {}, custom = "Original follow-up" }
ctl:submit("", round)
wait()
assert(failed and ctl.state.status == "paused")
-- Simulate reopening after failure, then editing and resubmitting the same round.
package.loaded["todo.ai.daily"] = nil
ctl = require("todo.ai.daily").new(ws, svc, ai, "2026-10-17")
round = ctl:item(second).round
assert(round.status == "pending")
round.answers.when.custom = "Updated follow-up at noon"
ctl:submit("", round)
wait()
assert(edited and #requests == 8 and ctl.state.status == "review", ctl.state.last_error)
assert(select(1, ctl:counts()) == 2)
local draft = assert(ws:get("draft", ctl.state.draft_id))
assert(#draft.changes == 2)
assert(#ctl.planner:today(ctl.date).items == 0, "generation must not silently apply plans")
local selected = {}
for _, change in ipairs(draft.changes) do
    selected[change.id] = true
end
ctl.planner:apply(draft, selected)
assert(#ctl.planner:today(ctl.date).items == 2)
assert(svc:undo())
assert(#ctl.planner:today(ctl.date).items == 0)
store:close()
print(
    "ok - evidence repair, bounded failure, note-only answers, retry/reopen/edit, malformed usage, two-task completion, approval and undo"
)
vim.cmd("qa!")
