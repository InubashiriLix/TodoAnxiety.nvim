-- Self-contained backend tests for todo.service:postpone.
-- Run with: nvim --clean --headless --cmd 'set runtimepath+=.' -l spec/postpone.lua
local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local service = require("todo.service")

local passed, failed = 0, 0

local function test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        passed = passed + 1
        print("ok - " .. name)
    else
        failed = failed + 1
        print("not ok - " .. name .. "\n" .. err)
    end
end

local function eq(actual, expected, message)
    if not vim.deep_equal(actual, expected) then
        error(
            (message or "values differ")
                .. "\nexpected: "
                .. vim.inspect(expected)
                .. "\nactual: "
                .. vim.inspect(actual)
        )
    end
end

-- Minimal in-memory store implementing the subset of the store API used by
-- todo.service:postpone (get + transactional update). No sqlite dependency.
local function memory_store(seed)
    local records = {}
    local counter = 0
    local store = {}

    local function clone(task)
        return task and vim.deepcopy(task) or nil
    end

    function store:_seed(task)
        counter = counter + 1
        local id = tostring(counter)
        local record = clone(task)
        record.id = id
        record.sync_revision = task.sync_revision or id
        records[id] = record
        return id
    end

    function store:get(id)
        return clone(records[id])
    end

    function store:update(id, task, expected_revision)
        if not records[id] then
            return nil
        end
        if expected_revision ~= nil and records[id].sync_revision ~= expected_revision then
            return nil
        end
        local updated = clone(task)
        updated.id = id
        updated.sync_revision = tostring((tonumber(records[id].sync_revision) or 0) + 1)
        updated.updated_at = os.time()
        records[id] = updated
        return clone(updated)
    end

    if seed then
        store:_seed(seed)
    end
    return store, service.new(store)
end

local function base_task(overrides)
    local task = {
        kind = "task",
        title = "Overdue",
        description = "desc",
        status = "todo",
        priority = 2,
        due_date = "2020-01-01",
        due_time = "12:00",
        tags = { "work" },
        archived_at = nil,
        reminder = nil,
    }
    for key, value in pairs(overrides or {}) do
        task[key] = value
    end
    return task
end

local function at(year, month, day, hour, min, sec)
    return os.time({
        year = year,
        month = month,
        day = day,
        hour = hour or 0,
        min = min or 0,
        sec = sec or 0,
        isdst = nil,
    })
end

test("default duration is one day", function()
    local store, svc = memory_store(base_task())
    local now = at(2026, 5, 1, 10, 0, 0)
    local updated = assert(svc:postpone("1", nil, now))
    eq(updated.due_date, os.date("%Y-%m-%d", now + 86400))
    eq(updated.due_time, "10:00")
end)

test("custom string durations parse via todo.duration", function()
    local _, svc = memory_store(base_task())
    local now = at(2026, 5, 1, 10, 0, 0)
    local two_hours = assert(svc:postpone("1", "2h", now))
    eq(two_hours.due_time, "12:00")
    eq(two_hours.due_date, "2026-05-01")

    local _, svc2 = memory_store(base_task())
    local three_days = assert(svc2:postpone("1", "3d", now))
    eq(three_days.due_date, "2026-05-04")
    eq(three_days.due_time, "10:00")

    local _, svc3 = memory_store(base_task())
    local combined = assert(svc3:postpone("1", "1d2h", now))
    eq(combined.due_date, "2026-05-02")
    eq(combined.due_time, "12:00")
end)

test("numeric duration seconds accepted, invalid rejected", function()
    local _, svc = memory_store(base_task())
    local now = at(2026, 5, 1, 10, 0, 0)
    local updated = assert(svc:postpone("1", 3600, now))
    eq(updated.due_time, "11:00")

    local _, bad = memory_store(base_task())
    local task, errors = bad:postpone("1", "0m", now)
    eq(task, nil)
    eq(errors, { duration = "invalid" })

    local _, bad2 = memory_store(base_task())
    eq(select(1, bad2:postpone("1", -5, now)), nil)
    eq(select(2, bad2:postpone("1", 1.5, now)), { duration = "invalid" })
    eq(select(1, bad2:postpone("1", math.huge, now)), nil)
    -- Overlong digit strings overflow to math.huge in todo.duration.parse.
    eq(select(2, bad2:postpone("1", string.rep("9", 400) .. "d", now)), { duration = "invalid" })
end)

test("deadline is rounded up to the next minute", function()
    local _, svc = memory_store(base_task())
    local now = at(2026, 5, 1, 10, 0, 0)
    local updated = assert(svc:postpone("1", 90, now))
    eq(updated.due_time, "10:02")
    eq(updated.due_date, "2026-05-01")

    -- already on a minute boundary stays exact
    local _, svc2 = memory_store(base_task())
    local exact = assert(svc2:postpone("1", 3600, now))
    eq(exact.due_time, "11:00")
end)

test("year boundary rolls over", function()
    local _, svc = memory_store(base_task())
    local now = at(2026, 12, 31, 23, 30, 0)
    local updated = assert(svc:postpone("1", "1h", now))
    eq(updated.due_date, "2027-01-01")
    eq(updated.due_time, "00:30")
end)

test("date-only deadline becomes date and time, no reminder stays nil", function()
    local task = base_task()
    task.due_time = nil
    local _, svc = memory_store(task)
    local now = at(2026, 5, 1, 8, 15, 0)
    local updated = assert(svc:postpone("1", nil, now))
    eq(updated.due_date, "2026-05-02")
    eq(updated.due_time, "08:15")
    eq(updated.reminder, nil)
end)

test("omitted kind is treated as an ordinary task", function()
    local task = base_task()
    task.kind = nil
    local _, svc = memory_store(task)
    local updated = assert(svc:postpone("1", "1d", at(2026, 5, 1, 10, 0, 0)))
    eq(updated.kind, "task")
    eq(updated.due_date, "2026-05-02")
end)

test("missing task reports not_found", function()
    local _, svc = memory_store(base_task())
    local task, errors = svc:postpone("999", "1d", at(2026, 5, 1))
    eq(task, nil)
    eq(errors, { id = "not_found" })
end)

test("ineligible tasks are refused without writing", function()
    local now = at(2026, 5, 1, 10, 0, 0)
    local no_deadline = base_task()
    no_deadline.due_date = nil
    no_deadline.due_time = nil
    local cases = {
        base_task({ status = "done" }),
        base_task({ status = "cancelled" }),
        base_task({ archived_at = now - 10 }),
        base_task({ kind = "notice" }),
        base_task({ due_date = "2030-01-01" }),
        no_deadline,
    }
    for _, task in ipairs(cases) do
        local store, svc = memory_store(task)
        local before = store:get("1")
        local result, errors = svc:postpone("1", "1d", now)
        eq(result, nil)
        eq(errors, { eligible = "required" })
        eq(store:get("1"), before, "ineligible postpone must not write")
    end
end)

test("revision conflict is refused without overwrite", function()
    local store, svc = memory_store(base_task())
    local before = store:get("1")
    local task, errors = svc:postpone("1", "1d", at(2026, 5, 1, 10, 0, 0), "stale")
    eq(task, nil)
    eq(errors, { revision = "conflict" })
    eq(store:get("1"), before, "conflict must not overwrite")
end)

test("matching expected_revision passes through", function()
    local store, svc = memory_store(base_task())
    local current = store:get("1")
    local updated = assert(svc:postpone("1", "1d", at(2026, 5, 1, 10, 0, 0), current.sync_revision))
    eq(updated.due_date, "2026-05-02")
end)

test("reminder schedule reset, interval and recurrence preserved", function()
    local recurrence = { kind = "every", every = 2, unit = "d", weekdays = { 1, 3 } }
    local reminder = {
        enabled = true,
        recurrence = recurrence,
        repeat_interval_seconds = 300,
        scheduled_at = 100,
        next_reminder_at = 100,
        snoozed_until = 999,
        last_reminded_at = 500,
        occurrence_started_at = 100,
    }
    local _, svc = memory_store(base_task({ reminder = reminder }))
    local now = at(2026, 5, 1, 10, 0, 0)
    local updated = assert(svc:postpone("1", "2h", now))
    local expected_epoch = at(2026, 5, 1, 12, 0, 0)
    eq(updated.reminder.repeat_interval_seconds, 300)
    eq(updated.reminder.enabled, true)
    eq(updated.reminder.recurrence, recurrence)
    eq(updated.reminder.scheduled_at, expected_epoch)
    eq(updated.reminder.next_reminder_at, expected_epoch)
    eq(updated.reminder.occurrence_started_at, expected_epoch)
    eq(updated.reminder.snoozed_until, nil)
    eq(updated.reminder.last_reminded_at, nil)
end)

test("task fields are preserved and tags untouched", function()
    local _, svc = memory_store(base_task({
        title = "Keep me",
        description = "keep desc",
        status = "in_progress",
        priority = 1,
        tags = { "alpha", "beta" },
    }))
    local updated = assert(svc:postpone("1", "1d", at(2026, 5, 1, 10, 0, 0)))
    eq(updated.title, "Keep me")
    eq(updated.description, "keep desc")
    eq(updated.status, "in_progress")
    eq(updated.priority, 1)
    eq(updated.kind, "task")
    eq(updated.tags, { "alpha", "beta" })
end)

-- The scheduler keeps stale tasks queued by (id, sync_revision). A postpone
-- rewrites the record and bumps its revision, so reconcile must drop every
-- queued/active copy of the old revision while keeping the current one.
test("scheduler reconcile drops stale queued and active revisions after postpone", function()
    local reminder = {
        enabled = true,
        recurrence = { kind = "once", every = 1, weekdays = {} },
        repeat_interval_seconds = 300,
        scheduled_at = 100,
        next_reminder_at = 100,
        occurrence_started_at = 100,
    }
    local store, svc = memory_store(base_task({ reminder = reminder }))
    local now = at(2026, 5, 1, 10, 0, 0)
    local stale = store:get("1")
    local dismissed = 0
    local scheduler = require("todo.scheduler").new(svc, {
        now = function()
            return now
        end,
        timer = {
            stop = function() end,
            start = function() end,
            is_closing = function()
                return true
            end,
            close = function() end,
        },
        presenter = function() end,
        dismiss = function()
            dismissed = dismissed + 1
        end,
        play_sound = function() end,
    })
    scheduler.queue = { stale }
    scheduler.active_task = stale
    scheduler.pending_ids = { ["1"] = true }

    local updated = assert(svc:postpone("1", "1d", now))
    assert(updated.sync_revision ~= stale.sync_revision, "postpone should bump the sync revision")

    scheduler:reconcile()
    eq(#scheduler.queue, 0, "stale queued revision should be removed")
    eq(scheduler.pending_ids["1"], nil, "stale pending id should be cleared")
    eq(dismissed, 1, "the stale presenter should be dismissed once")

    -- The freshly postponed (current) revision stays queued.
    scheduler.queue = { updated }
    scheduler.pending_ids = { ["1"] = true }
    scheduler:reconcile()
    eq(#scheduler.queue, 1, "current revision should remain queued")
    eq(scheduler.pending_ids["1"], true, "current revision should remain pending")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
    os.exit(1)
end
