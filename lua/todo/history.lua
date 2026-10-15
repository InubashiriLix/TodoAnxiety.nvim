-- In-memory, per-service undo/redo history for task business operations.
--
-- Every successful, effective task mutation made through an instrumented
-- service method pushes one entry (before/after snapshots). Nested service
-- calls (for example set_status -> complete_reminder) are recorded once.
local M = {}
M.__index = M

local LIMIT = 50

-- Methods that mutate an existing task and are undoable in this first version.
-- create / permanent delete / tag changes are intentionally excluded.
local RECORDED = {
    "update",
    "postpone",
    "set_status",
    "archive",
    "restore",
    "complete_reminder",
    "snooze",
    "set_reminder_enabled",
}

-- Mutations outside the first-version undo history. They never push an entry
-- but a successful business change still invalidates the redo stack.
local REDO_ONLY = {
    "create",
    "delete_archived",
    "create_tag",
    "rename_tag",
    "delete_tag",
}

-- Everything needed to reconstruct a task. Identity (id, sync_uuid) and sync
-- bookkeeping (sync_revision, updated_at) are deliberately absent so a restore
-- can never rewind them.
local SNAPSHOT_FIELDS = {
    "kind",
    "title",
    "description",
    "status",
    "priority",
    "due_date",
    "due_time",
    "created_at",
    "completed_at",
    "archived_at",
    "tags",
    "reminder",
}

local function capture(task)
    if not task then
        return nil
    end
    local snap = {}
    for _, key in ipairs(SNAPSHOT_FIELDS) do
        snap[key] = vim.deepcopy(task[key])
    end
    return snap
end

-- Business projection used for equality: background reminder progress
-- (next_reminder_at, last_reminded_at) is ignored, everything else is strict.
local function business(snap)
    if not snap then
        return nil
    end
    local result = vim.deepcopy(snap)
    if result.reminder then
        result.reminder.next_reminder_at = nil
        result.reminder.last_reminded_at = nil
    end
    return result
end

local function same_business(a, b)
    return vim.deep_equal(business(capture(a)), business(capture(b)))
end

function M.attach(service)
    local history = setmetatable({ service = service, undo_stack = {}, redo_stack = {}, depth = 0 }, M)
    service.history = history
    for _, name in ipairs(RECORDED) do
        local original = service[name]
        if original then
            service[name] = function(svc, ...)
                local args = { ... }
                local argc = select("#", ...)
                if history.depth > 0 then
                    return original(svc, unpack(args, 1, argc))
                end
                local id = args[1]
                local before = id ~= nil and svc.store:get(id) or nil
                history.depth = 1
                local ok, result, errors = pcall(original, svc, unpack(args, 1, argc))
                history.depth = 0
                if not ok then
                    error(result, 0)
                end
                if type(result) == "table" and result.id ~= nil then
                    history:record(result.id, before)
                end
                return result, errors
            end
        end
    end
    for _, name in ipairs(REDO_ONLY) do
        local original = service[name]
        if original then
            service[name] = function(svc, ...)
                local args = { ... }
                local argc = select("#", ...)
                if history.depth > 0 then
                    return original(svc, unpack(args, 1, argc))
                end
                local ok, result, errors = pcall(original, svc, unpack(args, 1, argc))
                if not ok then
                    error(result, 0)
                end
                if result then
                    history:clear_redo()
                end
                return result, errors
            end
        end
    end
    return history
end

function M:clear_redo()
    self.redo_stack = {}
end

-- Records one successful mutation. Failures and no-op mutations (identical
-- business content) never reach the stack; a new entry invalidates redo.
function M:record(id, before)
    if not before then
        return
    end
    local after = self.service.store:get(id)
    if not after or same_business(before, after) then
        return
    end
    table.insert(self.undo_stack, {
        id = id,
        before = capture(before),
        after = capture(after),
        expected_revision = after.sync_revision,
    })
    while #self.undo_stack > LIMIT do
        table.remove(self.undo_stack, 1)
    end
    self:clear_redo()
end

function M:can_undo()
    return #self.undo_stack > 0
end

function M:can_redo()
    return #self.redo_stack > 0
end

-- Top of the undo stack: source state for undo is entry.after.
function M:peek_undo()
    return self.undo_stack[#self.undo_stack]
end

-- Top of the redo stack: source state for redo is entry.before.
function M:peek_redo()
    return self.redo_stack[#self.redo_stack]
end

function M:revision_ok(task, expected)
    return task ~= nil and task.sync_revision == expected
end

function M:matches(task, snapshot)
    return task ~= nil and same_business(task, snapshot)
end

-- After a restore the live revision changed, so re-anchor any remaining entry
-- that still expects the task in its now-current business state. This is what
-- lets consecutive undo/redo of the same task keep working.
function M:refresh(id, task)
    local current = business(capture(task))
    for _, entry in ipairs(self.undo_stack) do
        if entry.id == id and vim.deep_equal(business(entry.after), current) then
            entry.expected_revision = task.sync_revision
        end
    end
    for _, entry in ipairs(self.redo_stack) do
        if entry.id == id and vim.deep_equal(business(entry.before), current) then
            entry.expected_revision = task.sync_revision
        end
    end
end

function M:pop_undo(restored)
    local entry = table.remove(self.undo_stack)
    entry.expected_revision = restored.sync_revision
    table.insert(self.redo_stack, entry)
    self:refresh(restored.id, restored)
    return entry
end

function M:pop_redo(restored)
    local entry = table.remove(self.redo_stack)
    entry.expected_revision = restored.sync_revision
    table.insert(self.undo_stack, entry)
    self:refresh(restored.id, restored)
    return entry
end

return M
