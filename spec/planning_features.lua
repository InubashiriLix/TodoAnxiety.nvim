local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
local cfg = require("todo.config")
cfg.setup({ reminders = { enabled = false }, ai = { enabled = true } })
vim.env.DEEPSEEK_API_KEY = "local-mock-key"
local passed, failed = 0, 0
local function test(name, fn)
    local ok, e = xpcall(fn, debug.traceback)
    if ok then
        passed = passed + 1
        print("ok - " .. name)
    else
        failed = failed + 1
        print("not ok - " .. name .. "\n" .. e)
    end
end
local function fixture()
    local store = require("todo.store").open(vim.fn.tempname() .. ".db")
    local ws = require("todo.workspace").new(store)
    local svc = require("todo.service").new(store)
    return store, ws, svc, require("todo.planning").new(ws, svc)
end
local function draft(ws, task, changes, extended)
    return {
        id = require("todo.sync.codec").uuid(),
        date = os.date("%Y-%m-%d"),
        extended = extended or false,
        plan_revision = select(2, ws:get("plan", os.date("%Y-%m-%d"))),
        changes = changes,
    }
end
local function change(id, kind, t, after)
    return {
        id = id,
        kind = kind,
        task_uuid = t and t.sync_uuid,
        expected_revision = t and t.sync_revision,
        after = after,
    }
end

test("today is independent of deadline and supports atomic undo/redo", function()
    local store, ws, svc, p = fixture()
    local a = assert(svc:create({ title = "A", deadline = "2020-01-01", reminder_interval = "5m" }))
    local b = assert(svc:create({ title = "B" }))
    p:add(a.sync_uuid)
    p:add(b.sync_uuid)
    assert(#svc:list("today") == 2)
    p:move(nil, b.sync_uuid, -1)
    assert(p:today().items[1].task_uuid == b.sync_uuid)
    assert(store:get(a.id).due_date == "2020-01-01")
    p:change(nil, a.sync_uuid, false)
    assert(#p:today().items == 1)
    assert(svc:undo())
    assert(#p:today().items == 2)
    assert(svc:redo())
    assert(#p:today().items == 1)
    store:close()
end)
test("review applies selected rows once and one undo restores the entire batch", function()
    local store, ws, svc, p = fixture()
    local t = assert(svc:create({ title = "Old", description = "Original" }))
    local d = draft(ws, t, {
        change("desc", "description", t, { description = "Clarified" }),
        change("note", "note", t, { text = "AI estimate" }),
        change("plan", "plan_add", t, { minutes = 45, group = "now", next_action = "Write outline" }),
    })
    p:apply(d, { desc = true, note = true, plan = true })
    assert(store:get(t.id).description == "Clarified" and #ws:list("note") == 1 and #p:today().items == 1)
    assert(svc:undo())
    assert(store:get(t.id).description == "Original" and #ws:list("note") == 0 and #p:today().items == 0)
    assert(svc:redo())
    assert(store:get(t.id).description == "Clarified" and #ws:list("note") == 1 and #p:today().items == 1)
    svc:set_status(t.id, "in_progress")
    assert(svc:undo())
    assert(svc:undo(), "batch undo after a status undo must work")
    store:close()
end)
test("review rejects stale or forbidden changes without partial writes", function()
    local store, ws, svc, p = fixture()
    local t = assert(svc:create({ title = "Task" }))
    local d = draft(
        ws,
        t,
        { change("n", "note", t, { text = "not committed" }), change("d", "description", t, { description = "x" }) }
    )
    svc:set_status(t.id, "done")
    assert(not pcall(p.apply, p, d, { n = true, d = true }))
    assert(#ws:list("note") == 0 and store:get(t.id).description == "")
    t = store:get(t.id)
    local e = draft(ws, t, { change("u", "task_update", t, { priority = 0 }) })
    assert(not pcall(p.apply, p, e, { u = true }))
    assert(store:get(t.id).priority == 2)
    store:close()
end)
test("extended task creation can be undone and redone as one batch", function()
    local store, ws, svc, p = fixture()
    local d = draft(ws, nil, {
        { id = "new", kind = "task_create", after = { title = "Created by AI" } },
        { id = "today", kind = "plan_add", after = { created_by = "new", minutes = 15, group = "next" } },
    }, true)
    p:apply(d, { new = true, today = true })
    assert(#svc:list("active") == 1 and #p:today().items == 1)
    assert(svc:undo())
    assert(#svc:list("active") == 0 and #p:today().items == 0)
    assert(svc:redo())
    assert(#svc:list("active") == 1 and #p:today().items == 1)
    store:close()
end)
local function mock_ai(ws, svc, replies, capture)
    return require("todo.ai").new(ws, svc, {
        transport = function(opts, cb)
            if capture then
                capture[#capture + 1] = opts
            end
            local response = table.remove(replies, 1)
            assert(response, "unexpected extra request")
            cb(response.error, response.error and nil or {
                choices = {
                    {
                        message = {
                            content = type(response.content) == "string" and response.content
                                or vim.json.encode(response.content),
                        },
                        finish_reason = "stop",
                    },
                },
                usage = response.usage,
            })
            return { cancel = function() end, running = false }
        end,
    })
end
local u =
    { prompt_tokens = 1000, prompt_cache_hit_tokens = 200, prompt_cache_miss_tokens = 800, completion_tokens = 100 }
test("AI counters persist and the question limit forces a final draft", function()
    local store, ws, svc = fixture()
    local ai = mock_ai(ws, svc, {
        { content = { action = "question", question = "What result do you need?" }, usage = u },
        { content = { action = "question", question = "Another question?" }, usage = u },
        { content = { action = "draft", summary = "Assumptions listed", changes = {} }, usage = u },
    })
    local s = ai:start({})
    s.max_questions = 1
    ws:put("conversation", s.id, s)
    local err
    ai:send(s.id, "Help me", {}, function(e)
        err = e
    end)
    assert(not err)
    assert(ai:resume(s.id).questions == 1)
    ai:send(s.id, "Already answered", {}, function(e)
        err = e
    end)
    assert(not err)
    s = ai:resume(s.id)
    assert(s.questions == 1 and s.requests == 3 and s.draft_id)
    assert(ai:usage(s.id).requests == 3 and ai:usage(s.id).usd > 0)
    store:close()
end)
test("AI full descriptions, extended permissions, request caps and unknown costs", function()
    local store, ws, svc = fixture()
    local t = assert(svc:create({ title = "Task", description = "Unique full description 123" }))
    local capture = {}
    local ai = mock_ai(ws, svc, { { error = "cancelled" } }, capture)
    local s = ai:start({})
    ai:send(s.id, "Start", {}, function(e)
        assert(e == "cancelled")
    end)
    assert(ai:usage(s.id).unknown == 1)
    assert(vim.json.encode(capture[1].body):find("Unique full description 123", 1, true))
    s = ai:resume(s.id)
    s.max_requests = 1
    ws:put("conversation", s.id, s)
    local e
    ai:send(s.id, "Again", {}, function(err)
        e = err
    end)
    assert(e and #capture == 1)
    store:close()
end)
test("AI malformed output has one charged repair and never executes suggestions", function()
    local store, ws, svc = fixture()
    local t = assert(svc:create({ title = "Task" }))
    local ai = mock_ai(ws, svc, {
        { content = "invalid JSON", usage = u },
        {
            content = {
                action = "draft",
                summary = "Review first",
                changes = { change("n", "note", t, { text = "Proposed only" }) },
            },
            usage = u,
        },
    })
    local s = ai:start({})
    local err
    ai:generate(s.id, function(e)
        err = e
    end)
    assert(not err)
    assert(ai:resume(s.id).requests == 2)
    assert(#ws:list("note") == 0 and #ws:list("draft") == 1 and ai:usage(s.id).requests == 2)
    store:close()
end)
test("extended deadline edits reschedule reminders and are reversible", function()
    local store, ws, svc, p = fixture()
    local task = assert(svc:create({ title = "Deadline", deadline = "2030-01-01", reminder_interval = "5m" }))
    local proposed =
        draft(ws, task, { change("date", "task_update", task, { deadline = "2030-02-03 14:30", priority = 0 }) }, true)
    p:apply(proposed, { date = true })
    local updated = store:get(task.id)
    assert(updated.due_date == "2030-02-03" and updated.due_time == "14:30" and updated.priority == 0)
    assert(updated.reminder.scheduled_at == require("todo.model").parse_deadline("2030-02-03 14:30").epoch)
    assert(svc:undo())
    assert(store:get(task.id).due_date == "2030-01-01")
    store:close()
end)
test("Lua preferences override synced AI profiles when config is authoritative", function()
    cfg.setup({
        ai = {
            enabled = true,
            preferences_source = "config",
            persona = "Lua authoritative persona",
            language = "en",
            api_key = "lua-authoritative-key",
        },
    })
    local store, ws, svc = fixture()
    ws:put("profile", "ai", { persona = "Old synced persona", language = "zh-CN" })
    local captured = {}
    local ai =
        mock_ai(ws, svc, { { content = { action = "draft", summary = "Plan", changes = {} }, usage = u } }, captured)
    local session = ai:start({})
    local err
    ai:generate(session.id, function(e)
        err = e
    end)
    assert(not err, err)
    local system = captured[1].body.messages[1].content
    assert(system:find("Lua authoritative persona", 1, true) and not system:find("Old synced persona", 1, true))
    assert(system:find("Respond in en", 1, true))
    assert(captured[1].headers.Authorization == "Bearer lua-authoritative-key")
    for _, kind in ipairs({ "conversation", "draft", "usage", "profile" }) do
        assert(
            not vim.json.encode(ws:list(kind)):find("lua-authoritative-key", 1, true),
            "credentials must never enter synced records"
        )
    end
    store:close()
    cfg.setup({ ai = { enabled = true } })
end)
test("balance lookup preserves currency and exact remaining amounts without model usage", function()
    local store, ws, svc = fixture()
    local ai = require("todo.ai").new(ws, svc, {
        transport = function(opts, cb)
            assert(opts.url == "https://api.deepseek.com/user/balance" and not opts.body)
            assert(opts.headers.Accept == "application/json")
            cb(nil, {
                is_available = true,
                balance_infos = {
                    {
                        currency = "CNY",
                        total_balance = "69.07",
                        granted_balance = "51.71",
                        topped_up_balance = "17.36",
                    },
                },
            })
            return { running = false, cancel = function() end }
        end,
    })
    local value
    ai:balance(function(e, r)
        assert(not e, e)
        value = r
    end)
    assert(value.is_available and value.balance_infos[1].total_balance == "69.07")
    assert(value.balance_infos[1].granted_balance == "51.71" and value.balance_infos[1].topped_up_balance == "17.36")
    assert(#ws:list("usage") == 0)
    store:close()
end)
test("compatible providers isolate credentials and omit unsupported parameters", function()
    cfg.setup({
        ai = {
            enabled = true,
            provider = "openai_compatible",
            base_url = "https://example.invalid/v1",
            model = "example",
        },
    })
    vim.env.AI_API_KEY = nil
    local credentials = require("todo.credentials")
    local original_path = credentials.path
    credentials.path = function()
        return vim.fn.tempname() .. ".json"
    end
    assert(not credentials.get(), "must not reuse DeepSeek environment or external credentials")
    local path = vim.fn.tempname() .. ".json"
    credentials.path = function()
        return path
    end
    credentials.set("compatible-local-test-key")
    assert(credentials.get() == "compatible-local-test-key")
    cfg.setup({ ai = { enabled = true } })
    assert(credentials.get() == "local-mock-key", "DeepSeek environment keeps its own priority")
    vim.env.DEEPSEEK_API_KEY = nil
    credentials.set("deepseek-local-test-key")
    cfg.setup({
        ai = {
            enabled = true,
            provider = "openai_compatible",
            base_url = "https://other.invalid/v1",
            model = "example",
        },
    })
    assert(not credentials.get(), "endpoint keys must be isolated")
    cfg.setup({
        ai = {
            enabled = true,
            provider = "openai_compatible",
            base_url = "https://example.invalid/v1",
            model = "example",
        },
    })
    credentials.clear()
    assert(not credentials.get())
    cfg.setup({ ai = { enabled = true } })
    assert(credentials.get() == "deepseek-local-test-key", "clear must preserve other provider keys")
    credentials.path = original_path
    vim.fn.delete(path)
    vim.env.DEEPSEEK_API_KEY = "local-mock-key"
    vim.env.AI_API_KEY = "compatible-test-key"
    cfg.setup({
        ai = {
            enabled = true,
            provider = "openai_compatible",
            base_url = "https://example.invalid/v1",
            model = "example",
        },
    })
    local store, ws, svc = fixture()
    local captured = {}
    local ai =
        mock_ai(ws, svc, { { content = { action = "draft", summary = "Review", changes = {} }, usage = u } }, captured)
    local session = ai:start({})
    local err
    ai:generate(session.id, function(e)
        err = e
    end)
    assert(not err, err)
    assert(#captured == 1 and not captured[1].body.thinking and not captured[1].body.response_format)
    assert(ai:usage(session.id).unknown == 1 and ai:usage(session.id).prompt_tokens == 1000)
    assert(ws:list("usage")[1].value.usd == nil)
    local balance_error
    ai:balance(function(e)
        balance_error = e
    end)
    assert(balance_error and #captured == 1, "unsupported balance must not make a request")
    store:close()
    cfg.setup({ ai = { enabled = true } })
end)
test("unsupported images are rejected before requests and text-only is explicit", function()
    cfg.setup({
        ai = {
            enabled = true,
            provider = "openai_compatible",
            base_url = "https://example.invalid/v1",
            model = "example",
        },
    })
    local store, ws, svc = fixture()
    local hash = string.rep("a", 64)
    local task = svc:create({ title = "Picture", description = "![example](todo-asset://" .. hash .. ".png)" })
    local captured = {}
    local ai = mock_ai(
        ws,
        svc,
        { { content = { action = "draft", summary = "Text only", changes = {} }, usage = u } },
        captured
    )
    local session = ai:start({ task_id = task.id })
    local err
    ai:generate(session.id, function(e)
        err = e
    end)
    assert(err and err:find("does not support images", 1, true), tostring(err))
    assert(#captured == 0 and ai:resume(session.id).requests == 0)
    session = ai:resume(session.id)
    session.text_only = true
    ws:put("conversation", session.id, session)
    ai:generate(session.id, function(e)
        err = e
    end)
    assert(not err, err)
    assert(#captured == 1 and type(captured[1].body.messages[2].content) == "string")
    assert(vim.json.encode(captured[1].body.messages):find("images were NOT sent", 1, true))
    store:close()
    cfg.setup({ ai = { enabled = true } })
end)
print(string.format("%d planning/AI tests passed, %d failed", passed, failed))
if failed > 0 then
    vim.cmd("cquit 1")
end
vim.cmd("qa!")
