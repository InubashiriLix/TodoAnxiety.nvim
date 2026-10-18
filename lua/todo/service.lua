local duration = require("todo.duration")
local history = require("todo.history")
local model = require("todo.model")
local recurrence = require("todo.recurrence")
local urgency = require("todo.urgency")

local M = {}
M.__index = M

function M.new(store)
    local service = setmetatable({ store = store }, M)
    history.attach(service)
    return service
end

function M:create(input)
    local task, errors = model.validate(input)
    if not task then
        return nil, errors
    end
    local created = self.store:create(task)
    if created and task.reminder and self.store.set_setting then
        self.store:set_setting("last_reminder_interval", task.reminder.repeat_interval_seconds)
    end
    return created
end

function M:update(id, input, expected_revision)
    if not self.store:get(id) then
        return nil, { id = "not_found" }
    end
    local task, errors = model.validate(input)
    if not task then
        return nil, errors
    end
    local updated = self.store:update(id, task, expected_revision)
    if updated and task.reminder and self.store.set_setting then
        self.store:set_setting("last_reminder_interval", task.reminder.repeat_interval_seconds)
    end
    return updated
end

local DEFAULT_POSTPONE_SECONDS = 86400

-- Overdue means a concrete deadline that already passed. Date-only deadlines
-- are anchored at 23:59 by the model, so they count as overdue the next day.
local function deadline_passed(task, now)
    local parsed = model.parse_deadline(model.deadline_text(task))
    return parsed ~= nil and parsed.epoch < now
end

local function is_finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Rounds up to the next whole minute; returns nil when the result cannot be
-- represented as a local calendar date/time.
local function format_deadline(epoch)
    if not is_finite(epoch) or epoch % 60 ~= 0 then
        return nil
    end
    local ok, formatted = pcall(os.date, "%Y-%m-%d %H:%M", epoch)
    if not ok or type(formatted) ~= "string" then
        return nil
    end
    return formatted:match("^(%d%d%d%d%-%d%d%-%d%d) (%d%d:%d%d)$")
end

function M:postpone(id, seconds, now, expected_revision)
    local task = self.store:get(id)
    if not task then
        return nil, { id = "not_found" }
    end
    if (task.kind or "task") ~= "task" or task.archived_at then
        return nil, { eligible = "required" }
    end
    if task.status ~= "todo" and task.status ~= "in_progress" then
        return nil, { eligible = "required" }
    end
    if seconds ~= nil and type(seconds) ~= "string" and type(seconds) ~= "number" then
        return nil, { duration = "invalid" }
    end
    local wait = seconds == nil and DEFAULT_POSTPONE_SECONDS or duration.parse(seconds)
    if not is_finite(wait) or wait <= 0 or wait % 1 ~= 0 then
        return nil, { duration = "invalid" }
    end
    now = now or os.time()
    if not is_finite(now) or not deadline_passed(task, now) then
        return nil, { eligible = "required" }
    end
    if expected_revision ~= nil and task.sync_revision ~= expected_revision then
        return nil, { revision = "conflict" }
    end
    local due_epoch = now + wait
    if not is_finite(due_epoch) then
        return nil, { duration = "invalid" }
    end
    due_epoch = math.ceil(due_epoch / 60) * 60
    local due_date, due_time = format_deadline(due_epoch)
    if not due_date then
        return nil, { duration = "invalid" }
    end
    local reminder
    if task.reminder then
        reminder = vim.deepcopy(task.reminder)
        reminder.scheduled_at = due_epoch
        reminder.next_reminder_at = due_epoch
        reminder.occurrence_started_at = due_epoch
        reminder.snoozed_until = nil
        reminder.last_reminded_at = nil
    end
    local updated = self.store:update(id, {
        kind = task.kind or "task",
        title = task.title,
        description = task.description,
        status = task.status,
        priority = task.priority,
        due_date = due_date,
        due_time = due_time,
        tags = vim.deepcopy(task.tags) or {},
        reminder = reminder,
    }, expected_revision)
    if not updated then
        return nil, { update = "failed" }
    end
    return updated
end

function M:set_status(id, status)
    if not model.statuses[status] then
        return nil, { status = "invalid" }
    end
    local task = self.store:get(id)
    if not task then
        return nil, { id = "not_found" }
    end
    if task.kind == "notice" and status == "done" then
        return self:complete_reminder(id)
    end
    return self.store:set_status(id, status)
end

function M:archive(id)
    if not self.store:get(id) then
        return nil, { id = "not_found" }
    end
    return self.store:archive(id)
end

function M:restore(id)
    if not self.store:get(id) then
        return nil, { id = "not_found" }
    end
    return self.store:restore(id)
end

function M:delete_archived(id)
    local task = self.store:get(id)
    if not task then
        return nil, { id = "not_found" }
    end
    if not task.archived_at then
        return nil, { archived = "required" }
    end
    if not self.store.delete_archived then
        return nil, { delete = "unsupported" }
    end
    local deleted = self.store:delete_archived(id)
    return deleted, deleted and nil or { delete = "failed" }
end

local function matches(task, filters)
    if filters.status and filters.status ~= "all" and task.status ~= filters.status then
        return false
    end
    if filters.priority and filters.priority ~= "all" and task.priority ~= tonumber(filters.priority:match("%d")) then
        return false
    end
    if filters.tag and filters.tag ~= "" then
        local found = false
        for _, tag in ipairs(task.tags) do
            if tag:lower() == filters.tag:lower() then
                found = true
                break
            end
        end
        if not found then
            return false
        end
    end
    if filters.search and filters.search ~= "" then
        local needle = filters.search:lower()
        local haystack = (task.title .. "\n" .. task.description):lower()
        if not haystack:find(needle, 1, true) then
            return false
        end
    end
    return true
end

local regrouped = { by_urgency = true, by_time = true, by_tag = true }

local function open_only(tasks)
    return vim.tbl_filter(function(task)
        return task.status == "todo" or task.status == "in_progress"
    end, tasks)
end

function M:list(view, filters, now)
    if view == "today" then
        local ws = require("todo.workspace").new(self.store)
        local planner = require("todo.planning").new(ws, self)
        local plan = planner:today()
        local result, seen = {}, {}
        for _, item in ipairs(plan.items) do
            local task = planner:task(item.task_uuid)
            if task and not task.archived_at and matches(task, filters or {}) then
                task.planning = item
                result[#result + 1] = task
                seen[task.sync_uuid] = true
            end
        end
        for _, r in ipairs(ws:list("plan")) do
            if r.key < plan.date then
                for _, item in ipairs(r.value.items or {}) do
                    local task = planner:task(item.task_uuid)
                    if
                        task
                        and not seen[task.sync_uuid]
                        and not task.archived_at
                        and (task.status == "todo" or task.status == "in_progress")
                        and matches(task, filters or {})
                    then
                        task.planning = vim.tbl_extend("force", item, { group = "review", previous_date = r.key })
                        result[#result + 1] = task
                        seen[task.sync_uuid] = true
                    end
                end
            end
        end
        return result
    end
    local tasks = self.store:list({ archived = view == "archived" })
    if view == "notices" then
        tasks = vim.tbl_filter(function(task)
            return task.kind == "notice"
        end, tasks)
    elseif view ~= "archived" then
        tasks = vim.tbl_filter(function(task)
            return task.kind ~= "notice"
        end, tasks)
    end
    if regrouped[view] then
        tasks = open_only(tasks)
    end
    if view == "emergency" then
        tasks = urgency.sort(tasks, now)
    elseif view == "by_urgency" then
        tasks = urgency.rank(tasks, now)
    elseif view == "by_time" then
        local reference = now or os.time()
        for _, task in ipairs(tasks) do
            task.urgency = task.urgency or urgency.calculate(task, reference)
        end
        table.sort(tasks, function(a, b)
            local ae, be = a.urgency.due_epoch, b.urgency.due_epoch
            if (ae ~= nil) ~= (be ~= nil) then
                return ae ~= nil
            end
            if ae and ae ~= be then
                return ae < be
            end
            if a.priority ~= b.priority then
                return a.priority < b.priority
            end
            return a.id < b.id
        end)
    elseif view == "by_tag" then
        table.sort(tasks, function(a, b)
            if a.priority ~= b.priority then
                return a.priority < b.priority
            end
            local at, bt = a.title:lower(), b.title:lower()
            if at ~= bt then
                return at < bt
            end
            return a.id < b.id
        end)
    elseif view == "notices" then
        table.sort(tasks, function(a, b)
            local at = a.reminder and a.reminder.next_reminder_at or math.huge
            local bt = b.reminder and b.reminder.next_reminder_at or math.huge
            return at == bt and a.id < b.id or at < bt
        end)
    elseif view == "archived" then
        table.sort(tasks, function(a, b)
            if a.archived_at ~= b.archived_at then
                return a.archived_at > b.archived_at
            end
            return a.id > b.id
        end)
    else
        table.sort(tasks, function(a, b)
            if a.status ~= b.status then
                local rank = { in_progress = 1, todo = 2, done = 3, cancelled = 4 }
                return rank[a.status] < rank[b.status]
            end
            if a.priority ~= b.priority then
                return a.priority < b.priority
            end
            return a.created_at < b.created_at
        end)
    end
    local result = {}
    for _, task in ipairs(tasks) do
        if matches(task, filters or {}) then
            result[#result + 1] = task
        end
    end
    return result
end

function M:due_reminders(now)
    return self.store.due_reminders and self.store:due_reminders(now or os.time()) or {}
end

function M:next_reminder_time()
    return self.store.next_reminder_time and self.store:next_reminder_time() or nil
end

function M:mark_reminded(id, now)
    return self.store:mark_reminded(id, now or os.time())
end

function M:snooze(id, seconds, now)
    local task = self.store:get(id)
    if not task or not task.reminder then
        return nil, { reminder = "not_found" }
    end
    return self.store:snooze(id, (now or os.time()) + seconds)
end

function M:complete_reminder(id, now)
    local task = self.store:get(id)
    if not task or not task.reminder then
        return nil, { reminder = "not_found" }
    end
    now = now or os.time()
    if task.kind ~= "notice" then
        return self:set_status(id, "done")
    end
    local next_at = recurrence.next_after(task.reminder.recurrence, task.reminder.scheduled_at, now)
    return self.store:advance_occurrence(id, next_at, now)
end

function M:set_reminder_enabled(id, enabled)
    local task = self.store:get(id)
    if not task or not task.reminder then
        return nil, { reminder = "not_found" }
    end
    return self.store:set_reminder_enabled(id, enabled)
end

function M:can_undo()
    return self.history ~= nil and self.history:can_undo()
end

function M:can_redo()
    return self.history ~= nil and self.history:can_redo()
end

-- Restores the previous business state of the most recently changed task.
-- Refuses (without touching state or the stacks) when the task is gone, was
-- changed externally or by sync, or the store rejects the revision.
function M:undo()
    local history = self.history
    if not history or not history:can_undo() then
        return nil, { history = "empty" }
    end
    local entry = history:peek_undo()
    if entry.custom then
        return history:apply_custom("undo")
    end
    local current = self.store:get(entry.id)
    if not history:revision_ok(current, entry.expected_revision) or not history:matches(current, entry.after) then
        return nil, { history = "conflict" }
    end
    local ok, restored = pcall(self.store.restore_snapshot, self.store, entry.id, entry.before, entry.expected_revision)
    if not ok or not restored then
        return nil, { history = "conflict" }
    end
    history:pop_undo(restored)
    return restored
end

function M:redo()
    local history = self.history
    if not history or not history:can_redo() then
        return nil, { history = "empty" }
    end
    local entry = history:peek_redo()
    if entry.custom then
        return history:apply_custom("redo")
    end
    local current = self.store:get(entry.id)
    if not history:revision_ok(current, entry.expected_revision) or not history:matches(current, entry.before) then
        return nil, { history = "conflict" }
    end
    local ok, restored = pcall(self.store.restore_snapshot, self.store, entry.id, entry.after, entry.expected_revision)
    if not ok or not restored then
        return nil, { history = "conflict" }
    end
    history:pop_redo(restored)
    return restored
end

function M:last_reminder_interval()
    local value = self.store.get_setting and self.store:get_setting("last_reminder_interval") or nil
    return value and tonumber(value) or nil
end

function M:list_tags()
    return self.store.list_tags and self.store:list_tags() or {}
end

local function normalize_tag_name(value)
    local tags = model.normalize_tags({ value })
    local name = tags[1]
    if not name or vim.fn.strchars(name) > 64 then
        return nil, { tag = "invalid" }
    end
    return name
end

function M:tag_stats()
    if self.store.tag_stats then
        return self.store:tag_stats()
    end
    return vim.tbl_map(function(name)
        return { name = name, task_count = 0 }
    end, self:list_tags())
end

function M:create_tag(value)
    local name, errors = normalize_tag_name(value)
    if not name then
        return nil, errors
    end
    return self.store.create_tag and self.store:create_tag(name) or name
end

function M:rename_tag(old_name, value)
    local name, errors = normalize_tag_name(value)
    if not name then
        return nil, errors
    end
    if not self.store.rename_tag then
        return nil, { tag = "unsupported" }
    end
    local renamed = self.store:rename_tag(old_name, name)
    return renamed, renamed and nil or { tag = "not_found" }
end

function M:delete_tag(name)
    if not self.store.delete_tag then
        return nil, { tag = "unsupported" }
    end
    local deleted = self.store:delete_tag(name)
    return deleted, deleted and nil or { tag = "not_found" }
end

function M:stats()
    if self.store.stats then
        return self.store:stats()
    end
    local active = self.store:list({ archived = false })
    local archived = self.store:list({ archived = true })
    local tasks = vim.tbl_filter(function(task)
        return task.kind ~= "notice"
    end, active)
    return {
        active = #tasks,
        emergency = #urgency.sort(tasks),
        archived = #archived,
        notices = #vim.tbl_filter(function(task)
            return task.kind == "notice"
        end, active),
    }
end

return M
