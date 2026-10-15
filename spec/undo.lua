-- Headless spec for todo service undo/redo. Run with:
--   nvim --headless -u NONE -l spec/undo.lua
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local service = require("todo.service")

local passed, failed = 0, 0
local function check(cond, msg)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL: " .. msg)
    end
end
local function eq(got, want, msg)
    check(vim.deep_equal(got, want), msg .. " (got " .. vim.inspect(got) .. " want " .. vim.inspect(want) .. ")")
end

-- Minimal in-memory store emulating the real store's contract. Every write is
-- a fresh synchronisation revision; it never rewinds (same as sync.record).
local FakeStore = {}
FakeStore.__index = FakeStore
function FakeStore.new()
    return setmetatable({ tasks = {}, next_id = 0, rev = 0, fail = false }, FakeStore)
end
function FakeStore:bump(task)
    self.rev = self.rev + 1
    task.sync_revision = "rev" .. self.rev
    task.updated_at = (task.updated_at or 0) + 1
end
function FakeStore:get(id)
    local t = self.tasks[id]
    return t and vim.deepcopy(t) or nil
end
function FakeStore:insert(task)
    self.next_id = self.next_id + 1
    task.id = self.next_id
    self:bump(task)
    self.tasks[task.id] = task
    return self:get(task.id)
end
local function make_task(over)
    local task = {
        kind = "task",
        title = "task",
        description = "",
        status = "todo",
        priority = 2,
        due_date = nil,
        due_time = nil,
        created_at = 100,
        updated_at = 100,
        completed_at = nil,
        archived_at = nil,
        tags = {},
        reminder = nil,
        sync_uuid = "00000000-0000-4000-8000-000000000000",
        sync_revision = nil,
    }
    for k, v in pairs(over or {}) do
        task[k] = v
    end
    return task
end
local function make_reminder(over)
    local r = {
        enabled = true,
        recurrence = { kind = "once", every = 1, unit = nil, weekdays = {} },
        repeat_interval_seconds = 600,
        scheduled_at = 200,
        next_reminder_at = 200,
        snoozed_until = nil,
        last_reminded_at = nil,
        occurrence_started_at = 200,
    }
    for k, v in pairs(over or {}) do
        r[k] = v
    end
    return r
end
local UPDATE_FIELDS = { "kind", "title", "description", "status", "priority", "due_date", "due_time", "tags", "reminder" }
function FakeStore:update(id, patch, expected_revision)
    local t = self.tasks[id]
    if not t then
        return nil
    end
    if expected_revision ~= nil and t.sync_revision ~= expected_revision then
        error("sync_stale_form")
    end
    for _, k in ipairs(UPDATE_FIELDS) do
        t[k] = vim.deepcopy(patch[k])
    end
    t.completed_at = t.status == "done" and (t.completed_at or 999) or nil
    self:bump(t)
    return self:get(id)
end
function FakeStore:set_status(id, status)
    local t = self.tasks[id]
    if not t then
        return nil
    end
    t.status = status
    t.completed_at = status == "done" and (t.completed_at or 999) or nil
    if t.reminder then
        t.reminder.enabled = status == "todo" or status == "in_progress"
    end
    self:bump(t)
    return self:get(id)
end
function FakeStore:archive(id)
    local t = self.tasks[id]
    if not t then
        return nil
    end
    t.archived_at = 500
    if t.reminder then
        t.reminder.enabled = false
    end
    self:bump(t)
    return self:get(id)
end
function FakeStore:restore(id)
    local t = self.tasks[id]
    if not t then
        return nil
    end
    t.archived_at = nil
    if t.reminder then
        t.reminder.enabled = true
    end
    self:bump(t)
    return self:get(id)
end
function FakeStore:snooze(id, until_at)
    local t = self.tasks[id]
    if not t or not t.reminder then
        return nil
    end
    t.reminder.next_reminder_at = until_at
    t.reminder.snoozed_until = until_at
    self:bump(t)
    return self:get(id)
end
function FakeStore:set_reminder_enabled(id, enabled)
    local t = self.tasks[id]
    if not t or not t.reminder then
        return nil
    end
    t.reminder.enabled = enabled and true or false
    self:bump(t)
    return self:get(id)
end
function FakeStore:advance_occurrence(id, next_at, now)
    local t = self.tasks[id]
    if not t then
        return nil
    end
    if next_at then
        t.reminder.scheduled_at = next_at
        t.reminder.next_reminder_at = next_at
        t.reminder.occurrence_started_at = next_at
        t.reminder.snoozed_until = nil
        t.reminder.last_reminded_at = nil
    else
        if t.reminder then
            t.reminder.enabled = false
        end
        t.status = "done"
        t.completed_at = now
    end
    self:bump(t)
    return self:get(id)
end
function FakeStore:set_setting() end
function FakeStore:get_setting()
    return nil
end
function FakeStore:restore_snapshot(id, snapshot, expected_revision)
    if self.fail then
        error("boom")
    end
    local t = self.tasks[id]
    if not t then
        return nil
    end
    if expected_revision ~= nil and t.sync_revision ~= expected_revision then
        return nil
    end
    for _, k in ipairs({ "kind", "title", "description", "status", "priority", "due_date", "due_time", "tags", "completed_at", "archived_at" }) do
        t[k] = vim.deepcopy(snapshot[k])
    end
    t.reminder = vim.deepcopy(snapshot.reminder)
    self:bump(t)
    return self:get(id)
end
function FakeStore:create(task)
    return self:insert(make_task({
        kind = task.kind,
        title = task.title,
        description = task.description,
        status = task.status,
        priority = task.priority,
        due_date = task.due_date,
        due_time = task.due_time,
        tags = vim.deepcopy(task.tags) or {},
        reminder = vim.deepcopy(task.reminder),
    }))
end

local function new_svc()
    return service.new(FakeStore.new())
end

-- A: consecutive undo/redo of the same task, revisions never rewind.
do
    local svc = new_svc()
    local t = svc.store:insert(make_task({ title = "t0" }))
    svc:update(t.id, { title = "t1" })
    svc:update(t.id, { title = "t2" })
    svc:update(t.id, { title = "t3" })
    eq(svc.store:get(t.id).title, "t3", "A after edits")
    check(svc:can_undo(), "A can_undo")
    local old_rev = svc.store:get(t.id).sync_revision
    local r = svc:undo()
    eq(r.title, "t2", "A undo 1")
    check(svc.store:get(t.id).sync_revision ~= old_rev, "A undo advances revision")
    eq(svc:undo().title, "t1", "A undo 2")
    eq(svc:undo().title, "t0", "A undo 3")
    check(not svc:can_undo(), "A undo exhausted")
    check(svc:can_redo(), "A can_redo")
    eq(svc:redo().title, "t1", "A redo 1")
    eq(svc:redo().title, "t2", "A redo 2")
    eq(svc:redo().title, "t3", "A redo 3")
    check(not svc:can_redo(), "A redo exhausted")
end

-- B: global ordering across different tasks.
do
    local svc = new_svc()
    local a = svc.store:insert(make_task({ title = "a0" }))
    local b = svc.store:insert(make_task({ title = "b0" }))
    svc:update(a.id, { title = "a1" })
    svc:update(b.id, { title = "b1" })
    eq(svc:undo().title, "b0", "B undo newest task")
    eq(svc:undo().title, "a0", "B undo oldest task")
    eq(svc:redo().title, "a1", "B redo oldest task")
    eq(svc:redo().title, "b1", "B redo newest task")
end

-- C: a new successful change clears the redo stack (recorded and unrecorded).
do
    local svc = new_svc()
    local t = svc.store:insert(make_task({ title = "t0" }))
    svc:update(t.id, { title = "t1" })
    svc:undo()
    check(svc:can_redo(), "C redo available")
    svc:update(t.id, { title = "t2" })
    check(not svc:can_redo(), "C redo cleared by edit")
    eq(svc:undo().title, "t0", "C undo after new edit")
    check(svc:can_redo(), "C redo available again")
    svc:create({ title = "brand new" })
    check(not svc:can_redo(), "C redo cleared by create")
end

-- D: external / synced modification yields a conflict and does not pop.
do
    local svc = new_svc()
    local t = svc.store:insert(make_task({ title = "t0" }))
    svc:update(t.id, { title = "t1" })
    local raw = svc.store.tasks[t.id]
    raw.title = "external"
    svc.store:bump(raw)
    local result, err = svc:undo()
    check(result == nil and err.history == "conflict", "D conflict returned")
    check(svc:can_undo(), "D stack preserved")
    eq(svc.store:get(t.id).title, "external", "D state not overwritten")
end

-- E: a storage failure does not corrupt or pop the stack.
do
    local svc = new_svc()
    local t = svc.store:insert(make_task({ title = "t0" }))
    svc:update(t.id, { title = "t1" })
    svc.store.fail = true
    local result, err = svc:undo()
    check(result == nil and err.history == "conflict", "E failure surfaced")
    check(svc:can_undo(), "E stack preserved on failure")
    svc.store.fail = false
    eq(svc:undo().title, "t0", "E undo works after recovery")
end

-- F: archive + reminder metadata (enabled, schedule, snooze) restored.
do
    local svc = new_svc()
    local t = svc.store:insert(make_task({ reminder = make_reminder({}) }))
    svc:archive(t.id)
    check(svc.store:get(t.id).archived_at ~= nil, "F archived")
    check(svc.store:get(t.id).reminder.enabled == false, "F reminder disabled on archive")
    local r = svc:undo()
    eq(r.archived_at, nil, "F archived_at cleared")
    check(svc.store:get(t.id).reminder.enabled == true, "F reminder re-enabled")
    eq(svc.store:get(t.id).reminder.next_reminder_at, 200, "F reminder schedule restored")
    svc:set_reminder_enabled(t.id, false)
    check(svc.store:get(t.id).reminder.enabled == false, "F disabled")
    svc:undo()
    check(svc.store:get(t.id).reminder.enabled == true, "F set_reminder_enabled undone")
    svc:snooze(t.id, 300, 1000)
    eq(svc.store:get(t.id).reminder.snoozed_until, 1300, "F snoozed")
    svc:undo()
    eq(svc.store:get(t.id).reminder.snoozed_until, nil, "F snooze undone")
end

-- G: postpone restores due_date/due_time and reminder schedule.
do
    local svc = new_svc()
    local t = svc.store:insert(make_task({ due_date = "2000-01-01", reminder = make_reminder({}) }))
    local moved = svc:postpone(t.id, 3600, os.time())
    check(moved ~= nil, "G postpone succeeded")
    check(svc.store:get(t.id).due_date ~= "2000-01-01", "G date moved")
    svc:undo()
    eq(svc.store:get(t.id).due_date, "2000-01-01", "G due_date restored")
    eq(svc.store:get(t.id).reminder.scheduled_at, 200, "G reminder schedule restored")
end

-- H: nested service calls are recorded exactly once.
do
    local svc = new_svc()
    local notice = svc.store:insert(make_task({ kind = "notice", reminder = make_reminder({}) }))
    local before = #svc.history.undo_stack
    svc:set_status(notice.id, "done")
    eq(#svc.history.undo_stack, before + 1, "H nested call recorded once")
end

-- I: no-op and failed operations are not recorded.
do
    local svc = new_svc()
    local t = svc.store:insert(make_task({}))
    local n = #svc.history.undo_stack
    svc:set_status(t.id, "todo")
    eq(#svc.history.undo_stack, n, "I no-op not recorded")
    local result, err = svc:update(t.id, { title = "" })
    check(result == nil and err.title == "required", "I invalid update rejected")
    eq(#svc.history.undo_stack, n, "I invalid update not recorded")
    local r2, e2 = svc:update(9999, { title = "x" })
    check(r2 == nil and e2.id == "not_found", "I missing task rejected")
    eq(#svc.history.undo_stack, n, "I missing task not recorded")
end

-- J: empty history reports empty and can_* return booleans.
do
    local svc = new_svc()
    check(svc:can_undo() == false and svc:can_redo() == false, "J booleans false")
    local result, err = svc:undo()
    check(result == nil and err.history == "empty", "J undo empty")
    local r2, e2 = svc:redo()
    check(r2 == nil and e2.history == "empty", "J redo empty")
end

print(string.format("undo spec: %d passed, %d failed", passed, failed))
if failed > 0 then
    os.exit(1)
end
os.exit(0)
