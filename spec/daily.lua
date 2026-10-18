package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
vim.env.XDG_STATE_HOME = vim.fn.tempname()
local config = require("todo.config")
config.setup({
    reminders = { enabled = false },
    ai = { enabled = true, api_key = "mock-daily", session_budget_usd = 2, daily_budget_usd = 3 },
})
vim.notify = function() end
local function fixture(count, responder, date)
    local store = require("todo.store").open(vim.fn.tempname() .. ".db")
    local ws = require("todo.workspace").new(store)
    local svc = require("todo.service").new(store)
    local uuids = {}
    for i = 1, count do
        local task = assert(svc:create({ title = "Task " .. i, description = "Complete description " .. i }))
        uuids[#uuids + 1] = task.sync_uuid
    end
    local calls = {}
    local ai = require("todo.ai").new(ws, svc, {
        transport = function(opts, cb)
            calls[#calls + 1] = opts.body
            local snapshot = vim.json.decode(opts.body.messages[2].content:match("Workspace snapshot:\n(.*)"))
            local result = responder(snapshot, #calls, opts.body)
            result.understanding = result.understanding
                or {
                    goal_clear = true,
                    goal = "Complete task",
                    deliverable = "Done",
                    unknowns = {},
                    evidence = { snapshot.tasks[1].title },
                }
            cb(nil, {
                choices = { { finish_reason = "stop", message = { content = vim.json.encode(result) } } },
                usage = { prompt_tokens = 10, completion_tokens = 5 },
            })
            return { running = false, cancel = function() end }
        end,
    })
    local ctl = require("todo.ai.daily").new(ws, svc, ai, date or "2026-10-16", {
        view = "active",
        task_uuids = uuids,
    })
    return ctl, ws, svc, ai, calls
end
local function review(s)
    return {
        message = "Checked",
        action = "item_review",
        understanding = {
            goal_clear = true,
            goal = "Complete task",
            deliverable = "Done",
            unknowns = {},
            evidence = { s.tasks[1].title },
        },
        summary = "Clear",
        review = { minutes = 10, next_action = "Start", completion = "Done" },
        changes = {
            { kind = "description", task_ref = s.tasks[1].task_ref, after = { description = "Approved detail" } },
        },
    }
end
local function prepare(ctl)
    for _, entry in ipairs(ctl.state.queue) do
        if not entry.missing then
            entry.selected = true
        end
    end
    ctl.state.locks_confirmed = true
    assert(ctl:prepare())
end
local function wait(ctl)
    assert(
        vim.wait(30000, function()
            return not ctl.busy
        end, 10),
        "workflow timeout"
    )
    assert(not ctl.state.last_error, ctl.state.last_error)
end
local ctl, ws, svc, ai, calls = fixture(25, function(s)
    if s.reviews then
        local changes = {}
        for i, t in ipairs(s.tasks) do
            changes[#changes + 1] = {
                kind = "plan_add",
                task_ref = t.task_ref,
                after = { minutes = 10, group = "next", position = i, next_action = "Start", completion = "Done" },
            }
        end
        return { message = "Ready", action = "draft", summary = "25 tasks checked", changes = changes }
    end
    assert(#s.tasks == 1 and #s.overview == 25, "one full task plus overview")
    return review(s)
end)
prepare(ctl)
ctl:start()
wait(ctl)
assert(ctl.state.status == "review" and #calls == 26, "25 item calls + final assembly: " .. #calls)
assert(select(1, ctl:counts()) == 25)
local draft = assert(ws:get("draft", ctl.state.draft_id))
assert(#draft.changes == 50)
for _, t in ipairs(svc.store:list({ archived = false })) do
    assert(t.description:find("Complete description", 1, true))
end
local selected = {}
for _, c in ipairs(draft.changes) do
    selected[c.id] = true
end
ctl.planner:apply(draft, selected)
assert(#ctl.planner:today(ctl.date).items == 25)
assert(svc.store:list({ archived = false })[1].description == "Approved detail")
assert(svc:undo())
assert(#ctl.planner:today(ctl.date).items == 0)
assert(svc.store:list({ archived = false })[1].description:find("Complete description", 1, true))
ctl:pause()
assert(ctl.state.status == "review", "closing review preserves status")
print("ok - 25 tasks sequential review, proposals only, final assembly, atomic approval and undo")
local c, w, service, api, requests = fixture(1, function(s, n, body)
    if s.reviews then
        return { message = "Ready", action = "draft", summary = "Ready", changes = {} }
    end
    if body.messages[#body.messages].content:find("FINAL DRAFT REQUIRED", 1, true) then
        return review(s)
    end
    return {
        message = "Need context",
        action = "question",
        questions = {
            {
                id = "q" .. n,
                header = "Goal",
                question = "Which goal " .. n .. "?",
                options = {
                    { id = "a", label = "A" },
                    { id = "b", label = "B" },
                    { id = "c", label = "C" },
                },
            },
        },
    }
end)
prepare(c)
c:start()
wait(c)
for round = 1, 10 do
    local ledger = c:item(c:current())
    assert(ledger.questions == round)
    c:pause()
    local resumed = require("todo.ai.daily").new(w, service, api, c.date, {
        view = c.view,
        task_uuids = c.state.seed_uuids,
    })
    assert(resumed == c and resumed:item(c:current()).questions == round)
    if round == 5 then
        package.loaded["todo.ai.daily"] = nil
        local restored = require("todo.ai.daily").new(w, service, api, c.date, {
            view = c.view,
            task_uuids = c.state.seed_uuids,
        })
        assert(restored ~= c and restored:item(restored:current()).questions == 5)
        c = restored
    end
    local q = vim.deepcopy(ledger.round)
    q.answers[q.questions[1].id] = { selected = { a = true }, notes = { a = "User explanation" } }
    c:submit("", q)
    wait(c)
end
assert(c.state.status == "review" and #requests == 12, "10 rounds then item result then final")
local nextday = require("todo.ai.daily").new(w, service, api, "2026-10-17", {
    view = c.view,
    task_uuids = c.state.seed_uuids,
})
assert(not nextday:item(nextday.state.queue[1]))
print("ok - 10 question rounds per task/date, reopen retains quota, next date resets")
local lock, lws, lsvc, lai, lcalls = fixture(1, review)
local task = lsvc.store:list({ archived = false })[1]
lock.planner:add(task.sync_uuid, lock.date)
lock.planner:change(lock.date, task.sync_uuid, { minutes = 480, locked = true })
lock.state.queue[1].locked = true
lock.state.queue[1].selected = true
lock.state.locks_confirmed = true
local ready, err = lock:prepare()
assert(not ready and err and #lcalls == 0, "full locks block before paid requests")
assert(lock:prepare(true))
assert(lock.planner:today(lock.date).items[1].locked)
print("ok - full locked capacity needs explicit continuation before network")
-- Quotas count lookup, repair and final calls; no repeated retries after the cap.
config.get().ai.planning.max_requests_total = 2
local limited, lw, ls, la, lr = fixture(2, review)
prepare(limited)
limited:start()
assert(vim.wait(5000, function()
    return not limited.busy
end, 10))
assert(#lr == 2 and limited.state.status == "paused" and limited.state.last_error)
config.get().ai.planning.max_requests_total = false
print("ok - workflow request budget pauses with completed item ledgers retained")
local stale, sw, ss, sa, sr = fixture(1, function(s)
    if s.reviews then
        return { message = "Ready", action = "draft", changes = {} }
    end
    return review(s)
end)
prepare(stale)
stale:start()
wait(stale)
local e = stale.state.queue[1]
assert(stale:checked(e))
local original = ss.store:get(e.task_id)
assert(
    ss:update(
        original.id,
        vim.tbl_extend("force", original, { description = "New user information" }),
        original.sync_revision
    )
)
assert(not stale:checked(e), "changed task must be rechecked")
stale:start()
wait(stale)
assert(#sr == 4)
print("ok - modifying task invalidates its review and forces reread")
local nextday = require("todo.ai.daily").new(sw, ss, sa, "2026-10-17", {
    view = stale.view,
    task_uuids = stale.state.seed_uuids,
})
prepare(nextday)
nextday:start()
wait(nextday)
local snapshot = vim.json.decode(sr[5].messages[2].content:match("Workspace snapshot:\n(.*)"))
assert(#snapshot.prior_reviews == 1 and snapshot.prior_reviews[1].date == "2026-10-16")
print("ok - next day reuses prior review as dated context without reusing quota")
-- Async pause cancels the only in-flight request and cannot drive the next item.
local paused, pw, ps, pa, pr = fixture(2, review)
local cancels = 0
pa.opts.transport = function(opts, cb)
    return {
        running = true,
        cancel = function()
            cancels = cancels + 1
            cb("cancelled")
        end,
    }
end
prepare(paused)
paused:start()
assert(paused.busy)
paused:pause()
assert(not paused.busy and cancels == 1 and paused.state.status == "paused")
vim.wait(80)
assert(cancels == 1 and #pr == 0)
print("ok - pause cancels active async IO once and stops queue advancement")
local cloud = require("todo.cloud")
local saved = { run = cloud.run, acquire = cloud.acquire_lease, release = cloud.release_lease }
local checkpoints, acquires, releases = 0, 0, 0
cloud.run = function(_, opts, cb)
    assert(opts.quiet)
    checkpoints = checkpoints + 1
    cb()
    return { running = false, cancel = function() end }
end
cloud.acquire_lease = function(_, _, _, cb)
    acquires = acquires + 1
    cb(nil, { token = "mock-lease" })
    return { running = false, cancel = function() end }
end
cloud.release_lease = function(_, _, _, _, cb)
    releases = releases + 1
    cb()
end
config.get().sync.enabled = true
config.get().sync.provider = "server"
config.get().sync.url = "https://example.invalid"
local synced, cws, cs, ca, cr = fixture(5, function(s)
    if s.reviews then
        return { action = "draft", summary = "Ready", changes = {} }
    end
    local result = review(s)
    result.memories = { { text = "A pending inferred preference", inferred = true } }
    return result
end)
prepare(synced)
vim.wait(80)
local origins = {}
local event = vim.api.nvim_create_autocmd("User", {
    pattern = "TodoWorkspaceChanged",
    callback = function(e)
        origins[#origins + 1] = e.data and e.data.origin or "user"
    end,
})
synced:start()
wait(synced)
assert(
    #cr == 6 and checkpoints == 2 and acquires == 1 and releases == 1,
    "only start/final checkpoints for uninterrupted queue"
)
vim.wait(80)
vim.api.nvim_del_autocmd(event)
assert(#cws:list("memory") == 5)
for _, origin in ipairs(origins) do
    assert(origin == "ai_checkpoint", "AI records must not trigger auto uploads")
end
cloud.run = saved.run
cloud.acquire_lease = saved.acquire
cloud.release_lease = saved.release
config.get().sync.enabled = false
print("ok - five item requests plus final use one date lease and only two quiet sync checkpoints")
-- Images from notes are real multimodal inputs; unsupported providers stop before billing.
local imagectl, iw, is, ia, ic = fixture(1, function(s)
    if s.reviews then
        return { action = "draft", summary = "Ready", changes = {} }
    end
    return review(s)
end)
local source = vim.fn.tempname() .. ".png"
vim.fn.writefile(
    vim.base64.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII="),
    source,
    "b"
)
local picture = require("todo.assets").import(source, { store = is.store })
iw:put(
    "note",
    "image-note",
    { task_uuid = imagectl.state.queue[1].uuid, text = picture.markdown, source = "user", created_at = os.time() }
)
prepare(imagectl)
config.get().ai.capabilities.vision = false
imagectl:start()
assert(vim.wait(5000, function()
    return not imagectl.busy
end, 10))
assert(#ic == 0 and imagectl.state.last_error:find("does not support images", 1, true))
imagectl.state.text_only = true
imagectl:save()
imagectl:start()
wait(imagectl)
assert(type(ic[1].messages[2].content) == "string")
assert(vim.json.encode(ic[1].messages):find("images were NOT sent", 1, true))
print("ok - daily provider without vision stops before billing and can resume explicitly as text only")
config.get().ai.capabilities.vision = true
local visual, vw, vs, va, vc = fixture(1, function(s)
    if s.reviews then
        return { action = "draft", changes = {} }
    end
    return review(s)
end)
local asset = require("todo.assets").import(source, { store = vs.store })
vw:put(
    "note",
    "visual-note",
    { task_uuid = visual.state.queue[1].uuid, text = asset.markdown, source = "user", created_at = os.time() }
)
-- Fixture supports actual multimodal snapshots.
va.opts.transport = function(opts, cb)
    vc[#vc + 1] = opts.body
    local content = opts.body.messages[2].content
    local snapshot =
        vim.json.decode((type(content) == "table" and content[1].text or content):match("Workspace snapshot:\n(.*)"))
    if not snapshot.reviews then
        assert(content[2].type == "image_url" and content[2].image_url.url:find("data:image/png;base64,", 1, true))
    end
    cb(nil, {
        choices = {
            {
                finish_reason = "stop",
                message = {
                    content = vim.json.encode(
                        snapshot.reviews and { action = "draft", changes = {} } or review(snapshot)
                    ),
                },
            },
        },
        usage = { prompt_tokens = 10, completion_tokens = 5 },
    })
    return { running = false, cancel = function() end }
end
prepare(visual)
visual:start()
wait(visual)
assert(#vc == 2)
vim.fn.delete(source)
config.get().ai.capabilities = {}
print("ok - images embedded in notes are included in per-item multimodal requests")
vim.cmd("qa!")
