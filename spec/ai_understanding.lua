package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
vim.env.XDG_STATE_HOME = vim.fn.tempname()
local config = require("todo.config")
config.setup({ reminders = { enabled = false }, ai = { enabled = true, api_key = "mock-understanding" } })
local store = require("todo.store").open(vim.fn.tempname() .. ".db")
local ws = require("todo.workspace").new(store)
local svc = require("todo.service").new(store)
local task = assert(svc:create({ title = "Backend acceptance", description = "" }))
require("todo.planning").new(ws, svc):add(task.sync_uuid, "2026-10-16")
local calls = 0
local ai = require("todo.ai").new(ws, svc, {
    transport = function(opts, cb)
        calls = calls + 1
        local result = {
            message = "I first need to understand the intended deliverable.",
            action = "question",
            understanding = { goal_clear = false, goal = "", deliverable = "", unknowns = { "Goal" }, evidence = {} },
            questions = {
                {
                    id = "goal",
                    intent = calls == 1 and "progress" or "goal",
                    question = calls == 1 and "How much is done?" or "What should acceptance prove?",
                    options = {},
                },
            },
        }
        if calls == 2 then
            assert(vim.json.encode(opts.body.messages):find("Goal is unclear", 1, true))
        end
        vim.defer_fn(function()
            cb(nil, {
                choices = { { finish_reason = "stop", message = { content = vim.json.encode(result) } } },
                usage = { prompt_tokens = 5, completion_tokens = 5 },
            })
        end, 5)
        return { running = true, cancel = function() end }
    end,
})
local ctl = require("todo.ai.daily").new(ws, svc, ai, "2026-10-16")
ctl.state.locks_confirmed = true
assert(ctl:prepare())
ctl:start()
assert(vim.wait(5000, function()
    return not ctl.busy
end))
assert(not ctl.state.last_error, ctl.state.last_error)
assert(calls == 2 and ctl.state.status == "awaiting")
local session = ctl:item(ctl:current())
assert(not session.understanding.goal_clear and session.round.questions[1].intent == "goal")
assert(session.messages[#session.messages].display:find("first need", 1, true))
print("ok - unclear task rejects progress question, repairs to goal clarification and preserves public understanding")
-- Build can apply ONLY Todo document changes under explicit configuration, with undo.
ctl:set_mode("build")
config.get().ai.permissions.auto_apply_documents = true
ai.opts.transport = function(opts, cb)
    local snapshot = vim.json.decode(opts.body.messages[2].content:match("Workspace snapshot:\n(.*)"))
    local result = snapshot.reviews and { action = "draft", changes = {}, summary = "Done" }
        or {
            action = "item_review",
            message = "Goal confirmed",
            summary = "Acceptance criteria clarified",
            understanding = {
                goal_clear = true,
                goal = "Verify API acceptance",
                deliverable = "Acceptance report",
                unknowns = {},
                evidence = { "Verify API acceptance" },
            },
            review = { minutes = 30, next_action = "Run tests", completion = "Report available" },
            changes = {
                {
                    kind = "description",
                    task_ref = snapshot.tasks[1].task_ref,
                    after = { description = "Verify API acceptance and write a report." },
                },
            },
        }
    vim.defer_fn(function()
        cb(nil, {
            choices = { { finish_reason = "stop", message = { content = vim.json.encode(result) } } },
            usage = { prompt_tokens = 5, completion_tokens = 5 },
        })
    end, 5)
    return { running = true, cancel = function() end }
end
ctl:submit("Verify API acceptance", session.round)
assert(vim.wait(5000, function()
    return not ctl.busy
end))
assert(not ctl.state.last_error, ctl.state.last_error)
assert(ctl.state.status == "review", "document apply must not mark entire workflow applied")
assert(store:get(task.id).description == "Verify API acceptance and write a report.")
assert(#ws:get("draft", ctl.state.draft_id).changes == 0, "already applied document changes must not be applied twice")
assert(svc:undo())
assert(store:get(task.id).description == "")
print("ok - configured build writes only Todo documents, preserves final review and can be undone")
local memory = require("todo.memory").new(ws, svc)
local fresh = store:get(task.id)
local s = {
    id = "memory-test",
    date = "2026-10-16",
    subject_uuid = task.sync_uuid,
    messages = { { id = "source-a", role = "user", content = "Prefer concise answers. Still testing the API." } },
}
memory:capture(s, {
    {
        text = "concise",
        source_id = "source-a",
        quote = "Prefer concise answers.",
        scope = "global",
        category = "preference",
        stable = true,
        fact_key = "answer_style",
    },
    {
        text = "progress",
        source_id = "source-a",
        quote = "Still testing the API.",
        scope = "global",
        category = "task_state",
        stable = true,
        fact_key = "progress",
    },
})
local before = #memory:list(true)
s.messages[#s.messages + 1] = { id = "source-b", role = "user", content = "Prefer concise answers." }
memory:capture(s, {
    {
        text = "same",
        source_id = "source-b",
        quote = "Prefer concise answers.",
        scope = "global",
        category = "preference",
        stable = true,
        fact_key = "answer_style",
    },
})
assert(#memory:list(true) == before, "same fact from new message must deduplicate")
s.messages[#s.messages + 1] = { id = "source-c", role = "user", content = "Prefer very detailed answers." }
memory:capture(s, {
    {
        text = "different",
        source_id = "source-c",
        quote = "Prefer very detailed answers.",
        scope = "global",
        category = "preference",
        stable = true,
        fact_key = "answer_style",
    },
})
local pending = false
for _, r in ipairs(memory:list(true)) do
    if r.value.text == "Prefer very detailed answers." then
        pending = r.value.status == "pending"
    end
    if r.value.text == "Still testing the API." then
        assert(r.value.task_uuid == task.sync_uuid and r.value.expires_at, "task state must be scoped and expire")
    end
end
assert(pending, "conflicting facts need confirmation")
memory:save("Unrelated gardening manual", { scope = "global" })
local selected = memory:select({ fresh }, s.date, 5000)
assert(
    #selected == 2,
    "only relevant task state and lasting preferences should enter context: " .. vim.inspect(selected)
)
assert(svc:update(task.id, vim.tbl_extend("force", fresh, { description = "Changed" }), fresh.sync_revision))
selected = memory:select({ store:get(task.id) }, s.date, 5000)
assert(#selected == 1 and selected[1].text == "Prefer concise answers.", "stale task memory leaked")
local id = selected[1].id
memory:remove(id)
s.messages[#s.messages + 1] = { id = "source-d", role = "user", content = "Prefer concise answers." }
memory:capture(s, {
    {
        text = "same",
        source_id = "source-d",
        quote = "Prefer concise answers.",
        scope = "global",
        category = "preference",
        stable = true,
    },
})
assert(not ws:get("memory", id), "forgotten fact revived under a new source")
print(
    "ok - relevant memory budget, deduplication, conflict review, expiring task facts, stale revision exclusion and forgetting"
)
store:close()
vim.cmd("qa!")
