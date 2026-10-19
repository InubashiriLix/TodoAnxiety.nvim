package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
vim.env.XDG_STATE_HOME = vim.fn.tempname()
require("todo.config").setup({ reminders = { enabled = false }, ai = { enabled = true, api_key = "mock-recovery" } })
vim.notify = function() end
local evidence = require("todo.ai.evidence")
assert(evidence.matches("Check every morning and evening", { "Check every morning\r\n  and evening" }))
assert(evidence.matches("Check every morning and evening", { "Check every morning，and evening" }))
assert(evidence.matches("Use 「page content」", { 'Use "page content"' }))
assert(not evidence.matches("Check on the 23rd", { "Check on the 22nd" }))
assert(not evidence.matches("finished", { "not done" }))
assert(not evidence.matches("one two", { "one", "two" }))
assert(not evidence.matches(" \n ", { "text" }))
assert(not evidence.matches({}, { "text" }))
assert(not evidence.matches("1.5 days", { "15 days" }), "punctuation-only matching must not merge numbers")
local store = require("todo.store").open(vim.fn.tempname() .. ".db")
local ws = require("todo.workspace").new(store)
local svc = require("todo.service").new(store)
local seed = {}
for i = 1, 2 do
    local value = assert(
        svc:create({ title = "Service " .. i, description = "Activate service\nWait for payment confirmation." })
    )
    seed[#seed + 1] = value.sync_uuid
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
        elseif n == 1 or n == 4 then
            response = {
                action = "question",
                message = "When should we check?",
                understanding = {
                    goal_clear = true,
                    goal = "Activate service",
                    deliverable = "Service active",
                    unknowns = { "When", "Who", "Where", "Why", "How", "Cost", "Risk", "Priority", "Scope", "Backup" },
                    evidence = {
                        "Activate service",
                        "Activate service",
                        "Activate service",
                        "Activate service",
                        "Activate service",
                        "Activate service",
                        "Activate service",
                        "Activate service",
                    },
                },
                questions = {
                    {
                        id = "when",
                        intent = "estimate",
                        question = "When?",
                        options = {
                            { id = "wait", label = "Mostly waiting" },
                            { id = "active", label = "Actively progressing" },
                            { id = "blocked", label = "Blocked by someone else" },
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
        elseif n == 5 then
            failed = true
            vim.defer_fn(function()
                cb("HTTP 503", nil)
            end, 5)
            return { running = true, cancel = function() end }
        else
            response = result(snapshot, "Check every morning and evening")
            if n == 6 then
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
local ctl = require("todo.ai.daily").new(ws, svc, ai, "2026-10-17", { view = "active", task_uuids = seed })
local function wait()
    assert(
        vim.wait(5000, function()
            return not ctl.busy
        end, 5),
        "request hung"
    )
end
ctl.state.intent = "Spend the morning on activation"
for _, entry in ipairs(ctl.state.queue) do
    entry.selected = true
end
ctl.state.locks_confirmed = true
assert(ctl:prepare())
ctl:start()
wait()
local first = ctl:current()
local first_session = ctl:item(first)
assert(#first_session.understanding.unknowns == 8, "over-limit unknowns must be clamped")
assert(#first_session.understanding.evidence == 6, "over-limit evidence must be clamped")
local round = ctl:item(first).round
round.answers.when = { selected = {}, notes = { wait = "Check every morning\n  and evening" } }
local transcript = require("todo.ai.questions").transcript(round)
assert(not transcript:find("unknown / skipped", 1, true), "notes must count as supplied information")
ctl:submit("", round)
wait()
assert(#requests == 4 and ctl.state.status == "awaiting" and not ctl.state.last_error, ctl.state.last_error or "expected task two question")
local session = ctl:item(first)
assert(session.review, "degraded evidence must still complete the item review")
assert(session.understanding and session.understanding.goal_clear == false, "unverified evidence must be demoted")
assert(session.questions == 1, "degraded evidence must not consume question rounds")
local degraded_note = false
for _, value in ipairs(session.understanding.unknowns) do
    if value:find("could not be verified", 1, true) then
        degraded_note = true
    end
end
assert(degraded_note, "degraded evidence must leave an explicit unknown")
assert(ai:usage(ctl.id).unknown >= 1, "malformed provider usage must be unknown, never crash")
local second = ctl:current()
assert(second and first.uuid ~= second.uuid, "second task must become current")
round = ctl:item(second).round
round.answers.when = { selected = {}, notes = {}, custom = "Original follow-up" }
ctl:submit("", round)
wait()
assert(failed and ctl.state.status == "paused", "task two failure must pause the workflow")
-- Simulate reopening after failure, then editing and resubmitting the same round.
package.loaded["todo.ai.daily"] = nil
ctl = require("todo.ai.daily").new(ws, svc, ai, "2026-10-17", { view = "active", task_uuids = seed })
round = ctl:item(second).round
assert(round and round.status == "pending", "failed round must remain pending: " .. tostring(round and round.status))
round.answers.when.custom = "Updated follow-up at noon"
ctl:submit("", round)
wait()
assert(edited and #requests == 8 and ctl.state.status == "review", ctl.state.last_error or "retry must complete the plan")
local second_session = ctl:item(second)
assert(
    second_session.understanding and second_session.understanding.goal_clear == false,
    "unverified task evidence must degrade instead of blocking"
)
local retried_users = 0
for _, message in ipairs(ctl:item(second).messages) do
    if message.role == "user" and message.origin ~= "workflow" then
        retried_users = retried_users + 1
    end
end
assert(retried_users == 1, "retry duplicated a user message")
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
assert(ws:get("draft", draft.id).status == "applied")
ctl.planner:apply(draft, selected)
assert(#ctl.planner:today(ctl.date).items == 2, "reapplying an applied draft must be idempotent")
assert(svc:undo())
assert(#ctl.planner:today(ctl.date).items == 0)
store:close()
print(
    "ok - evidence repair, bounded failure, note-only answers, retry/reopen/edit, malformed usage, two-task completion, approval and undo"
)
vim.cmd("qa!")
