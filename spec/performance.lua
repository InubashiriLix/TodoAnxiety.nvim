package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
vim.env.XDG_STATE_HOME = vim.fn.tempname()
local count = tonumber(vim.env.TODO_PERF_TASKS) or 136
local active = count > 136 and count or 24
require("todo.config").setup({
    db_path = vim.fn.tempname() .. ".db",
    reminders = { enabled = false },
    ai = { enabled = true, api_key = "offline-performance-test" },
})
local todo = require("todo")
local svc = todo._service()
local ws = svc.store.workspace
local errors = {}
require("todo.diagnostics").record = function(event)
    if event.error then
        errors[#errors + 1] = tostring(event.error)
    end
end
-- Seed a disposable database in one transaction, without exercising the
-- mutation journal 1000 times before measuring the UI.
svc.store:transaction(function()
    for i = 1, count do
        svc.store.db:eval(
            [[INSERT INTO tasks(title,description,status,priority,created_at,updated_at,sync_uuid,sync_revision)
            VALUES(:title,:description,:status,2,1,1,:uuid,:revision)]],
            {
                title = "性能测试 Task " .. i,
                description = "A goal and deliverable\nMore information",
                status = i <= active and "todo" or "done",
                uuid = require("todo.sync.codec").uuid(),
                revision = require("todo.sync.codec").uuid(),
            }
        )
    end
end)
ws:observe(true)
local queries = 0
local original = svc.store.db.eval
svc.store.db.eval = function(...)
    queries = queries + 1
    return original(...)
end
local function callback(key)
    local mapping = vim.fn.maparg(key, "n", false, true)
    assert(mapping.callback, "missing mapping: " .. key)
    return mapping.callback()
end
local function benchmark(name)
    callback("j")
    callback("k") -- prime target detail and theme caches
    queries = 0
    local samples = {}
    for i = 1, 40 do
        local t = vim.uv.hrtime()
        callback(i % 2 == 0 and "j" or "k")
        samples[i] = (vim.uv.hrtime() - t) / 1e6
    end
    table.sort(samples)
    assert(#errors == 0, table.concat(errors, "\n"))
    assert(queries == 0, name .. " navigation performed " .. queries .. " database reads/writes")
    print(
        string.format(
            "perf %s tasks=%d p50=%.2fms p95=%.2fms max=%.2fms queries=%d",
            name,
            count,
            samples[20],
            samples[38],
            samples[40],
            queries
        )
    )
    -- Optional hardware-specific gate; deterministic query assertions run in CI.
    if vim.env.TODO_PERF_P95_MS then
        assert(samples[38] <= tonumber(vim.env.TODO_PERF_P95_MS), name .. " latency budget")
    end
end
local panel = require("todo.ui.panel")
panel.open({ view = "active" })
vim.api.nvim_set_current_win(panel.inspect_state().owner.list.winid)
benchmark("main")
panel.close()
local owner = todo.plan()
local ctl = owner.controller
assert(#ctl.state.queue == active, "fixture lost active tasks: " .. #ctl.state.queue)
vim.api.nvim_set_current_win(owner.questions.winid)
vim.wait(100)
benchmark("daily")
-- UI must not invoke searchable-corpus construction, even for checked items.
local entry = ctl.state.queue[1]
local session_id = ctl:item_id(entry)
local task = svc.store:get(entry.task_id)
ws:put("conversation", session_id, {
    review = {},
    checked_revision = task.sync_revision,
    checked_hash = ctl:document(entry).hash,
})
local snapshot = require("todo.ui.snapshot").new(svc)
assert(snapshot:daily(ctl):checked(entry))
local view = require("todo.ui.daily_view")
for _, readonly in ipairs({ false, true }) do
    local first = view.tasks(snapshot:daily(ctl), snapshot.service, 1, 80, readonly)
    local second = view.tasks(snapshot:daily(ctl), snapshot.service, 2, 80, readonly)
    assert(first == second, "cursor movement rebuilt the task cards")
    assert((first.lines[2]:find("Adjust tasks", 1, true) ~= nil) == readonly, "queue hints lost read-only state")
end
local old_documents = require("todo.memory").documents
require("todo.memory").documents = function()
    error("UI rebuilt the memory corpus")
end
owner.render()
benchmark("reviewed")
require("todo.memory").documents = old_documents
-- Invalidate before the scheduled event, including absent -> present records.
ws:put("note", "perf-note", { task_uuid = entry.uuid, text = "Changed requirements" })
assert(not snapshot:daily(ctl):checked(entry), "new note must invalidate a previous review immediately")
ws:put("note", "perf-note", nil)
assert(snapshot:daily(ctl):checked(entry), "removing a note must invalidate its cached document")
local before = snapshot:daily(ctl).ai:usage(ctl.id).requests
ws:put("usage", "perf-usage", { workflow_id = ctl.id, date = os.date("%Y-%m-%d"), known = true, usd = 0.01 })
assert(snapshot:daily(ctl).ai:usage(ctl.id).requests == before + 1)
local date = os.date
os.date = function(format, timestamp)
    if format == "%Y-%m-%d" and not timestamp then
        return "2099-01-01"
    end
    return date(format, timestamp)
end
assert(snapshot:daily(ctl).ai:usage(ctl.id).today_usd == 0, "cost cache must roll over at midnight")
os.date = date
local document_hash = snapshot:document(entry).hash
ws:import_page({
    version = 2,
    cursor = 1,
    operations = {
        {
            id = "remote-note",
            changes = {
                {
                    kind = "note",
                    key = "from-another-device",
                    version = 1,
                    value = { task_uuid = entry.uuid, text = "Remote requirements" },
                },
            },
        },
    },
})
assert(snapshot:document(entry).hash ~= document_hash, "sync import must invalidate documents")
ws:import_page({
    version = 2,
    cursor = 2,
    operations = {
        {
            id = "remove-remote-note",
            changes = {
                {
                    kind = "note",
                    key = "from-another-device",
                    version = 2,
                    value = vim.NIL,
                },
            },
        },
    },
})
assert(snapshot:document(entry).hash == document_hash, "remote deletion must invalidate documents")
local changed = vim.deepcopy(task)
changed.description = "Changed by the task service"
assert(svc:update(task.id, changed))
assert(snapshot:task(task.id).description == changed.description)
assert(not snapshot:daily(ctl):checked(entry))
assert(svc:undo())
assert(snapshot:task(task.id).description == task.description, "undo must invalidate presentation data")
-- Spinner ticks are extmarks only; they cannot scan SQLite or rewrite prose.
vim.wait(100)
ctl.busy = true
owner.render()
local tick = vim.api.nvim_buf_get_changedtick(owner.timeline.bufnr)
queries = 0
vim.wait(350)
assert(queries == 0, "spinner performed database work")
assert(vim.api.nvim_buf_get_changedtick(owner.timeline.bufnr) == tick, "spinner rewrote the timeline")
ctl.busy = false
owner.render()
owner.close()
panel.open({ view = "active", mode = "sidebar" })
vim.api.nvim_set_current_win(panel.inspect_state().owner.split.winid)
benchmark("sidebar")
panel.close()
print("ok - navigation performs no SQL; notes, usage, task edits and undo invalidate snapshots; spinner is incremental")
vim.cmd("qa!")
