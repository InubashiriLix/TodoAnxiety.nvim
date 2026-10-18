package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
vim.env.XDG_STATE_HOME = vim.fn.tempname()
local cfg = require("todo.config")
cfg.setup({ reminders = { enabled = false }, ai = { enabled = true, api_key = "mock-task-refs" } })
vim.notify = function() end
local P, F = 0, 0
local reports = {}
local function test(name, fn)
    local ok, e = xpcall(fn, debug.traceback)
    if ok then
        P = P + 1
        reports[#reports + 1] = "ok - " .. name
    else
        F = F + 1
        reports[#reports + 1] = "not ok - " .. name .. "\n" .. e
    end
end
local function fixture(responder)
    local store = require("todo.store").open(vim.fn.tempname() .. ".db")
    local ws = require("todo.workspace").new(store)
    local svc = require("todo.service").new(store)
    local task = assert(svc:create({ title = "exact task", description = "full task text" }))
    local calls = {}
    local ai = require("todo.ai").new(ws, svc, {
        transport = function(opts, cb)
            calls[#calls + 1] = vim.deepcopy(opts.body)
            local result = responder(opts.body, #calls, task)
            cb(nil, {
                choices = { { finish_reason = "stop", message = { content = vim.json.encode(result) } } },
                usage = { prompt_tokens = 10, completion_tokens = 5 },
            })
            return { running = false, cancel = function() end }
        end,
    })
    return store, ws, svc, task, ai, calls
end
local function suggestion(ref, nested)
    return {
        action = "draft",
        summary = "plan",
        changes = { { kind = "plan_add", task_ref = ref, after = { task_uuid = nested, minutes = 30, group = "now" } } },
    }
end
test("short task refs become exact UUIDs before approval; no task writes happen during generation", function()
    local store, ws, svc, task, ai, calls = fixture(function(body)
        local context = vim.json.decode(body.messages[2].content:match("Workspace snapshot:\n(.*)"))
        assert(context.tasks[1].task_ref == "t1")
        return suggestion("t1")
    end)
    local session = ai:start()
    local failure
    ai:generate(session.id, function(e)
        failure = e
    end)
    assert(not failure, failure)
    local saved = ai:resume(session.id)
    local draft = assert(ws:get("draft", saved.draft_id))
    assert(
        #calls == 1
            and draft.changes[1].task_uuid == task.sync_uuid
            and draft.changes[1].after.task_uuid == task.sync_uuid
    )
    assert(not draft.changes[1].task_ref and not draft.changes[1].selected)
    assert(svc.store:get(task.id).description == "full task text")
    store:close()
end)
test("aliases stay attached to the same task when workspace tasks change", function()
    local store, ws, svc, task, ai = fixture(function()
        return suggestion("t1")
    end)
    local session = ai:start()
    ai:context(session)
    local original = session.task_refs.t1
    assert(svc:create({ title = "another task" }))
    local context = ai:context(session)
    assert(session.task_refs.t1 == original and session.task_refs.t2 and #context.tasks == 2)
    local found
    for _, t in ipairs(context.tasks) do
        if t.task_uuid == original then
            found = t.task_ref
        end
    end
    assert(found == "t1")
    store:close()
end)
test("repair receives the rejected response, precise change index and allowed reference map", function()
    local store, ws, svc, task, ai, calls = fixture(function(body, n)
        if n == 1 then
            return suggestion("invented-uuid")
        end
        local assistant = body.messages[#body.messages - 1]
        local feedback = body.messages[#body.messages]
        assert(assistant.role == "assistant" and assistant.content:find("invented-uuid", 1, true))
        assert(
            feedback.content:find("changes[1]", 1, true)
                and feedback.content:find("Allowed task references:", 1, true)
                and feedback.content:find("t1", 1, true)
        )
        return suggestion("t1", "t1")
    end)
    local s = ai:start()
    local err
    ai:generate(s.id, function(e)
        err = e
    end)
    assert(not err, err)
    s = ai:resume(s.id)
    assert(#calls == 2 and s.requests == 2 and not s.rejected_response)
    assert(ws:get("draft", s.draft_id).changes[1].task_uuid == task.sync_uuid)
    store:close()
end)
test("unknown references fail closed after one repair and preserve rejected JSON for inspection", function()
    local store, ws, svc, task, ai, calls = fixture(function()
        return suggestion("invented-uuid")
    end)
    local s = ai:start()
    local err
    ai:generate(s.id, function(e)
        err = e
    end)
    s = ai:resume(s.id)
    assert(err and err:find("changes[1]", 1, true) and #calls == 2 and s.requests == 2)
    assert(not s.draft_id and #ws:list("draft") == 0)
    assert(s.rejected_response.content:find("invented-uuid", 1, true))
    assert(svc.store:get(task.id).status == "todo")
    store:close()
end)
test("exact UUIDs tolerate casing and surrounding whitespace without fuzzy title matching", function()
    local store, ws, svc, task, ai = fixture(function(_, _, t)
        return {
            action = "draft",
            changes = {
                { kind = "note", task_uuid = " " .. t.sync_uuid:upper() .. " ", after = { text = "review first" } },
            },
        }
    end)
    local s = ai:start()
    local err
    ai:generate(s.id, function(e)
        err = e
    end)
    assert(not err, err)
    assert(ws:get("draft", ai:resume(s.id).draft_id).changes[1].task_uuid == task.sync_uuid)
    store:close()
end)
test("a top-level and nested reference cannot select different tasks", function()
    local second
    local store, ws, svc, task, ai, calls = fixture(function()
        return suggestion("t1", second.sync_uuid)
    end)
    second = assert(svc:create({ title = "other" }))
    local s = ai:start()
    local err
    ai:generate(s.id, function(e)
        err = e
    end)
    assert(err and err:find("conflicting task references", 1, true) and #calls == 2)
    assert(not ai:resume(s.id).draft_id)
    store:close()
end)
require("todo.ui.network_progress").close()
for _, line in ipairs(reports) do
    print(line)
end
print(P .. " task reference tests passed, " .. F .. " failed")
if F > 0 then
    vim.cmd("cquit 1")
end
vim.cmd("qa!")
