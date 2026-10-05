local Store = require("todo.store")
local Service = require("todo.service")
local journal = require("todo.sync.store")
local codec = require("todo.sync.codec")
local transport = require("todo.sync")
local root = vim.fn.tempname() .. " sync space"
vim.fn.mkdir(root, "p")
local stores, passed, failed = {}, 0, 0

local function eq(a, b)
    assert(vim.deep_equal(a, b), "expected " .. vim.inspect(b) .. "\ngot " .. vim.inspect(a))
end
local function test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        passed = passed + 1
        print("ok - sync: " .. name)
    else
        failed = failed + 1
        print("not ok - sync: " .. name .. "\n" .. err)
    end
end
local function open(name)
    local store = Store.open(root .. "/" .. name .. ".db")
    stores[#stores + 1] = store
    return store, Service.new(store)
end
local function payloads(store)
    return vim.tbl_map(function(event)
        return event.payload
    end, journal.events(store))
end
local function exchange(a, b)
    journal.import(b, payloads(a))
    journal.import(a, payloads(b))
end
local function by_uuid(store, uuid)
    for _, archived in ipairs({ false, true }) do
        for _, task in ipairs(store:list({ archived = archived })) do
            if task.sync_uuid == uuid then
                return task
            end
        end
    end
end
local function git(args)
    local command = { "git" }
    vim.list_extend(command, args)
    local result = vim.system(command, { text = true }):wait()
    assert(result.code == 0, result.stderr)
    return result.stdout
end
local function sync(store, remote, extra)
    local done, failure, value = false
    local opts = vim.tbl_extend("force", { enabled = true, remote = remote, branch = "main" }, extra or {})
    local handle = transport.run(store, opts, function(err, result)
        done, failure, value = true, err, result
    end)
    assert(
        vim.wait(15000, function()
            return done
        end, 10),
        "sync timed out"
    )
    assert(not handle.running)
    assert(not failure, tostring(failure))
    return value
end

test("configuration validation and completion", function()
    local config = require("todo.config")
    assert(not config.defaults().sync.enabled)
    assert(not pcall(config.setup, { sync = { enabled = true } }))
    for _, branch in ipairs({ "--evil", "main..bad", "main.lock", "a/.b", "a/", "a//b" }) do
        assert(not pcall(config.setup, { sync = { branch = branch } }))
    end
    config.setup({})
    eq(require("todo.commands").complete("st", "Todo sync st"), { "status" })
end)

test("progress stages and per-run transfer counts include no-change sync", function()
    local remote = root .. "/progress.git"
    git({ "init", "--bare", remote })
    local a, sa = open("progress-a")
    local b = open("progress-b")
    sa:create({ title = "Progress test" })
    local first = sync(a, remote)
    eq(first.uploaded, 1)
    eq(first.downloaded, 0)
    local stages = {}
    local second = sync(b, remote, {
        on_progress = function(event)
            stages[#stages + 1] = event.phase
        end,
    })
    eq(stages, { "prepare", "download", "merge", "apply", "upload" })
    eq(second.uploaded, 0)
    eq(second.downloaded, 1)
    local unchanged = sync(b, remote)
    eq(unchanged.uploaded, 0)
    eq(unchanged.downloaded, 0)
    eq(unchanged.pending, 0)
    -- A broken notification provider must not abort the actual sync.
    sync(a, remote, {
        on_progress = function()
            error("presentation failed")
        end,
    })
end)

test("independent IDs, idempotence and newer whole-record winner", function()
    local a, sa = open("independent-a")
    local b, sb = open("independent-b")
    local first = assert(sa:create({ title = "中文 macOS", description = "multi\nline" }))
    local second = assert(sb:create({ title = "Linux" }))
    eq(first.id, second.id)
    assert(first.sync_uuid ~= second.sync_uuid)
    exchange(a, b)
    eq(#a:list(), 2)
    eq(#b:list(), 2)
    local remote = by_uuid(b, first.sync_uuid)
    assert(sa:update(first.id, { title = "older edit" }))
    -- Force a deterministic later offline clock, independent of test execution speed.
    b:set_setting("sync_clock_time", tonumber(a:get_setting("sync_clock_time")) + 100)
    assert(sb:update(remote.id, { title = "newer edit" }))
    exchange(a, b)
    eq(a:get(first.id).title, "newer edit")
    eq(by_uuid(b, first.sync_uuid).title, "newer edit")
    local count = #journal.events(a)
    eq(journal.import(a, payloads(b)), 0)
    eq(#journal.events(a), count)
    assert(not pcall(sa.update, sa, first.id, { title = "stale form" }, first.sync_revision))
    eq(a:get(first.id).title, "newer edit")
end)

test("archive, restore and deletion tombstones survive replay", function()
    local a, sa = open("delete-a")
    local b, sb = open("delete-b")
    local t = assert(sa:create({ title = "Disposable" }))
    exchange(a, b)
    local old = payloads(b)
    sa:archive(t.id)
    exchange(a, b)
    assert(by_uuid(b, t.sync_uuid).archived_at)
    sb:restore(by_uuid(b, t.sync_uuid).id)
    exchange(a, b)
    assert(not a:get(t.id).archived_at)
    sa:archive(t.id)
    sa:delete_archived(t.id)
    exchange(a, b)
    eq(by_uuid(b, t.sync_uuid), nil)
    journal.import(a, old)
    eq(a:get(t.id), nil)
end)

test("tag rename, merge, delete and stale associations", function()
    local a, sa = open("tags-a")
    local b, sb = open("tags-b")
    local t = assert(sa:create({ title = "Tagged", tags = { "Work", "Other" } }))
    exchange(a, b)
    sa:rename_tag("Work", "Other")
    exchange(a, b)
    eq(by_uuid(b, t.sync_uuid).tags, { "Other" })
    local stale = by_uuid(b, t.sync_uuid)
    sa:delete_tag("Other")
    b:set_setting("sync_clock_time", tonumber(a:get_setting("sync_clock_time")) + 100)
    sb:update(stale.id, { title = "Offline edit", tags = stale.tags })
    exchange(a, b)
    eq(a:get(t.id).tags, {})
    eq(by_uuid(b, t.sync_uuid).tags, {})
    sa:create_tag("OTHER")
    exchange(a, b)
    eq(a:list_tags(), { "OTHER" })
    eq(b:list_tags(), { "OTHER" })
    eq(a:get(t.id).tags, {})
    eq(by_uuid(b, t.sync_uuid).tags, {})
    sa:update(t.id, { title = "Reattach explicitly", tags = { "OTHER" } })
    exchange(a, b)
    eq(by_uuid(b, t.sync_uuid).tags, { "OTHER" })
end)

test("recurrence and snooze sync without exporting bell progress", function()
    local a, sa = open("reminder-a")
    local b, sb = open("reminder-b")
    local now = os.time()
    local t = assert(sa:create({
        kind = "notice",
        title = "Tea",
        trigger = "5m",
        now = now,
        reminder_interval = "2m",
        recurrence = { kind = "interval", every = 1, unit = "hours" },
    }))
    exchange(a, b)
    local other = by_uuid(b, t.sync_uuid)
    local count = #journal.events(a)
    sa:mark_reminded(t.id, now + 300)
    eq(#journal.events(a), count)
    exchange(a, b)
    eq(b:get(other.id).reminder.last_reminded_at, nil)
    sa:snooze(t.id, 600, now)
    exchange(a, b)
    eq(b:get(other.id).reminder.next_reminder_at, now + 600)
    sb:mark_reminded(other.id, now + 600)
    sb:create({ title = "Unrelated import" })
    exchange(a, b)
    eq(b:get(other.id).reminder.last_reminded_at, now + 600)
    sa:complete_reminder(t.id, now + 601)
    exchange(a, b)
    eq(b:get(other.id).reminder.scheduled_at, now + 3900)
    eq(b:get(other.id).reminder.last_reminded_at, nil)
    eq(b:get(other.id).reminder.snoozed_until, nil)
    sa:set_reminder_enabled(t.id, false)
    exchange(a, b)
    eq(b:get(other.id).reminder.enabled, false)
end)

test("equal clocks converge and corrupt batches roll back", function()
    local a, sa = open("validation-a")
    local b = open("validation-b")
    sa:create({ title = "Base" })
    local original = codec.decode(payloads(a)[1])
    local x, y = vim.deepcopy(original), vim.deepcopy(original)
    x.id, y.id = codec.uuid(), codec.uuid()
    x.device = "00000000-0000-4000-8000-000000000001"
    y.device = "00000000-0000-4000-8000-000000000002"
    x.changes[1].value.title, y.changes[1].value.title = "X", "Y"
    journal.import(a, { codec.encode(x), codec.encode(y) })
    journal.import(b, { codec.encode(y), codec.encode(x) })
    eq(b:list()[1].title, "Y")
    -- Validate all before import, including future wire versions.
    local invalid = vim.deepcopy(y)
    invalid.version = 2
    local c = open("validation-c")
    assert(not pcall(journal.import, c, { codec.encode(x), codec.encode(invalid) }))
    eq(c:list(), {})
    eq(#journal.events(c), 0)
    invalid = vim.deepcopy(y)
    invalid.changes[1].value.title = "tampered"
    local count = #journal.events(b)
    assert(not pcall(journal.import, b, { codec.encode(invalid) }))
    eq(#journal.events(b), count)
    eq(b:list()[1].title, "Y")
end)

test("import calendar validation is independent of local timezone", function()
    local a, sa = open("calendar")
    sa:create({ title = "DST boundary" })
    local event = codec.decode(payloads(a)[1])
    event.changes[1].value.due_date = "2027-03-14"
    event.changes[1].value.due_time = "02:30"
    local model = require("todo.model")
    local parse = model.parse_deadline
    model.parse_deadline = function()
        error("must not convert wire deadlines through local time")
    end
    local ok = pcall(codec.validate, event)
    model.parse_deadline = parse
    assert(ok)
    event.changes[1].value.due_date = "2027-02-29"
    assert(not pcall(codec.validate, event))
end)

test("import clears stale queued and visible reminders", function()
    local a, sa = open("scheduler-a")
    local b, sb = open("scheduler-b")
    local now = os.time()
    for _, title in ipairs({ "First reminder", "Second reminder" }) do
        sa:create({ kind = "notice", title = title, trigger = "1s", now = now - 10, reminder_interval = "2m" })
    end
    exchange(a, b)
    local callback, dismissals
    dismissals = 0
    local scheduler = require("todo.scheduler").new(sa, {
        now = function()
            return now
        end,
        play_sound = function() end,
        presenter = function(_, finish)
            callback = finish
        end,
        dismiss = function()
            dismissals = dismissals + 1
            callback("dismiss")
        end,
    })
    scheduler:start()
    assert(scheduler.active_task)
    eq(#scheduler.queue, 1)
    for _, task in ipairs(b:list()) do
        sb:complete_reminder(task.id, now)
    end
    journal.import(a, payloads(b))
    scheduler:reconcile()
    eq(dismissals, 1)
    eq(#scheduler.queue, 0)
    eq(scheduler.active_task, nil)
    eq(scheduler.pending_ids, {})
    scheduler:stop()
end)

test("business changes and journal are atomic", function()
    local a, sa = open("atomic")
    local original = codec.validate
    codec.validate = function()
        error("injected journal failure")
    end
    local ok = pcall(sa.create, sa, { title = "Must roll back" })
    codec.validate = original
    assert(not ok)
    eq(a:list(), {})
    eq(#journal.events(a), 0)
    sa:create({ title = "After rollback" })
    eq(#a:list(), 1)
end)

test("shared database lock and cancellation", function()
    local a = open("locks")
    local b = open("locks")
    local token = journal.lock(a)
    assert(not pcall(journal.lock, b))
    journal.unlock(a, token)
    token = journal.lock(b)
    journal.unlock(b, token)
    local called
    local handle = transport.run(a, { enabled = true, remote = root .. "/missing.git", branch = "main" }, function(err)
        called = err
    end)
    handle.cancel()
    assert(called and not handle.running)
    token = journal.lock(a)
    journal.unlock(a, token)
end)

test("real Git two-device sync, offline changes and cache recovery", function()
    local remote = root .. "/remote.git"
    git({ "init", "--bare", remote })
    local a, sa = open("git-a")
    local b, sb = open("git-b")
    local first = assert(sa:create({ title = "First", tags = { "work" } }))
    sync(a, remote)
    sync(b, remote)
    eq(b:list()[1].sync_uuid, first.sync_uuid)
    sa:create({ title = "Offline A" })
    sb:create({ title = "Offline B" })
    sync(a, remote)
    sync(b, remote)
    sync(a, remote)
    eq(#a:list(), 3)
    eq(#b:list(), 3)
    eq(journal.status(a).pending, 0)
    eq(journal.status(b).pending, 0)
    local head = git({ "-C", transport.directory(a), "rev-parse", "HEAD" })
    sync(a, remote)
    eq(git({ "-C", transport.directory(a), "rev-parse", "HEAD" }), head)
    -- A missing Git cache can be rebuilt solely from the SQLite journal.
    vim.fn.delete(transport.directory(a), "rf")
    sync(a, remote)
    eq(#a:list(), 3)
    eq(journal.status(a).pending, 0)
end)

test("edits during sync remain queued and push races retry", function()
    local remote = root .. "/race.git"
    git({ "init", "--bare", remote })
    local a, sa = open("race-a")
    local b, sb = open("race-b")
    sa:create({ title = "Initial" })
    sync(a, remote)
    sync(b, remote)
    local once = false
    local attempts = {}
    local result = sync(a, remote, {
        on_progress = function(event)
            if event.phase == "download" then
                attempts[#attempts + 1] = event.attempt
            end
        end,
        on_import = function()
            if once then
                return
            end
            once = true
            sa:create({ title = "Created while syncing" })
            sb:create({ title = "Competing writer" })
            sync(b, remote)
        end,
    })
    eq(attempts, { 1, 2 })
    eq(result.uploaded, 0)
    eq(result.downloaded, 1)
    eq(result.pending, 1)
    eq(journal.status(a).pending, 1)
    eq(#a:list(), 3)
    sync(a, remote)
    sync(b, remote)
    eq(#b:list(), 3)
    eq(journal.status(a).pending, 0)
end)

test("offline failure retains journal and releases lock", function()
    local a, sa = open("offline")
    sa:create({ title = "Keep me" })
    local ok = pcall(sync, a, root .. "/does-not-exist.git")
    assert(not ok)
    eq(a:list()[1].title, "Keep me")
    eq(journal.status(a).pending, 1)
    assert(journal.status(a).last_error)
    local token = journal.lock(a)
    journal.unlock(a, token)
    git({ "init", "--bare", root .. "/does-not-exist.git" })
    sync(a, root .. "/does-not-exist.git")
    eq(journal.status(a).pending, 0)
end)

test("authentication, timeout and pre-commit interruptions are retryable", function()
    for _, failure in ipairs({
        { "ls-remote", 128, "Permission denied (publickey)" },
        { "fetch", 124, "process timed out" },
        { "commit", 128, "interrupted before commit" },
    }) do
        local command, code, message = unpack(failure)
        local remote = root .. "/failure-" .. command .. ".git"
        git({ "init", "--bare", remote })
        local seed, seed_service = open("failure-seed-" .. command)
        seed_service:create({ title = "Seed" })
        sync(seed, remote)
        local a, sa = open("failure-" .. command)
        sa:create({ title = "Local record survives" })
        local system, intercepted = vim.system, false
        vim.system = function(argv, opts, callback)
            if vim.tbl_contains(argv, command) then
                intercepted = true
                vim.schedule(function()
                    callback({ code = code, stdout = "", stderr = message })
                end)
                return { kill = function() end, wait = function() end }
            end
            return system(argv, opts, callback)
        end
        local ok = pcall(sync, a, remote)
        vim.system = system
        assert(intercepted and not ok)
        eq(journal.status(a).pending, 1)
        assert(journal.status(a).last_error:find(message, 1, true))
        local token = journal.lock(a)
        journal.unlock(a, token)
        sync(a, remote)
        eq(#a:list(), 2)
        eq(journal.status(a).pending, 0)
    end
end)

test("cancel an in-flight process and recover an abandoned lock", function()
    local a, sa = open("inflight")
    sa:create({ title = "Not lost on cancellation" })
    -- An impossible PID represents a process which exited without releasing its lock.
    a.db:eval(
        "INSERT INTO sync_lock(singleton, pid, token) VALUES(1, :pid, :token)",
        { pid = 1073741824, token = "abandoned" }
    )
    local token = journal.lock(a)
    journal.unlock(a, token)
    local remote = root .. "/inflight.git"
    git({ "init", "--bare", remote })
    local system, child, finished = vim.system
    vim.system = function(argv, opts, callback)
        if vim.tbl_contains(argv, "ls-remote") then
            child = system(
                { vim.v.progpath, "--clean", "--headless", "--cmd", "lua vim.wait(30000)", "-c", "qa!" },
                opts,
                callback
            )
            return child
        end
        return system(argv, opts, callback)
    end
    local handle = transport.run(a, { enabled = true, remote = remote, branch = "main" }, function(err)
        finished = err
    end)
    local started = vim.wait(3000, function()
        return child ~= nil
    end, 10)
    vim.system = system
    handle.cancel()
    assert(started and finished)
    eq(journal.status(a).pending, 1)
    token = journal.lock(a)
    journal.unlock(a, token)
    sync(a, remote)
    eq(journal.status(a).pending, 0)
end)

test("unknown remote format does not touch local data", function()
    local remote = root .. "/unknown.git"
    git({ "init", "--bare", remote })
    local a, sa = open("unknown-a")
    sa:create({ title = "Remote" })
    sync(a, remote)
    local repo = transport.directory(a)
    vim.fn.writefile({ '{"format":"todo.nvim","version":999}' }, repo .. "/format.json")
    git({ "-C", repo, "add", "format.json" })
    git({
        "-C",
        repo,
        "-c",
        "user.name=test",
        "-c",
        "user.email=test@localhost",
        "-c",
        "commit.gpgsign=false",
        "commit",
        "-m",
        "Unsupported future format",
    })
    git({ "-C", repo, "push", "origin", "HEAD:main" })
    local b, sb = open("unknown-b")
    sb:create({ title = "Local" })
    assert(not pcall(sync, b, remote))
    eq(#b:list(), 1)
    eq(b:list()[1].title, "Local")
    eq(journal.status(b).pending, 1)
end)

for _, store in ipairs(stores) do
    store:close()
end
vim.fn.delete(root, "rf")
print(string.format("%d sync tests passed, %d failed", passed, failed))
if failed > 0 then
    vim.cmd("cquit " .. failed)
end
vim.cmd("qa!")
