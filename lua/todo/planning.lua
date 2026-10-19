local codec = require("todo.sync.codec")
local M = {}
M.__index = M
function M.new(workspace, service)
    return setmetatable({ ws = workspace, service = service }, M)
end
function M:date()
    local configured = require("todo.config").get().planning.timezone_offset_minutes
    if configured ~= false then
        return os.date("!%Y-%m-%d", os.time() + configured * 60)
    end
    local profile = self.ws:get("profile", "planning") or {}
    if profile.timezone_offset_minutes then
        return os.date("!%Y-%m-%d", os.time() + profile.timezone_offset_minutes * 60)
    end
    return os.date("%Y-%m-%d")
end
function M:today(date)
    date = date or self.ws.store:get_setting("planning_view_date") or self:date()
    local cfg = require("todo.config").get().planning
    return self.ws:get("plan", date)
        or {
            date = date,
            capacity_minutes = cfg.capacity_minutes,
            reserve_ratio = cfg.reserve_minutes ~= false and cfg.reserve_minutes / cfg.capacity_minutes
                or cfg.reserve_ratio,
            items = {},
        }
end
function M:task(uuid)
    for _, archived in ipairs({ false, true }) do
        for _, t in ipairs(self.service.store:list({ archived = archived })) do
            if t.sync_uuid == uuid then
                return t
            end
        end
    end
end
local function refid(kind, key)
    return kind .. "/" .. key
end
function M:transaction(label, fn)
    if self.service.history.depth > 0 then
        return fn()
    end
    local before, after = {}, {}
    for _, kind in ipairs({ "task", "plan", "note" }) do
        for _, r in ipairs(self.ws:list(kind)) do
            before[refid(kind, r.key)] = { kind = kind, key = r.key, value = r.value, revision = r.revision }
        end
    end
    local history = self.service.history
    local previous_group = self.ws.group_id
    self.ws.group_id = codec.uuid()
    if not self.ws:get("profile", "planning") then
        local now = os.time()
        local utc = os.date("!*t", now)
        utc.isdst = nil
        self.ws:put("profile", "planning", { timezone_offset_minutes = os.difftime(now, os.time(utc)) / 60 })
    end
    local olddepth = history.depth
    history.depth = olddepth + 1
    local ok, result = pcall(function()
        return self.service.store:transaction(fn)
    end)
    history.depth = olddepth
    self.ws.group_id = previous_group
    if not ok then
        error(result, 0)
    end
    for _, kind in ipairs({ "task", "plan", "note" }) do
        for _, r in ipairs(self.ws:list(kind)) do
            after[refid(kind, r.key)] = { kind = kind, key = r.key, value = r.value, revision = r.revision }
        end
    end
    local keys = vim.tbl_extend("force", before, after)
    local bundle, expected = {}, {}
    for k, r in pairs(keys) do
        local b, a = before[k], after[k]
        if not vim.deep_equal(b and b.value, a and a.value) then
            bundle[#bundle + 1] = { kind = r.kind, key = r.key, before = b and b.value, after = a and a.value }
            expected[k] = select(2, self.ws:get(r.kind, r.key))
        end
    end
    if #bundle > 0 then
        local side = "after"
        local task_uuids = {}
        for _, r in ipairs(bundle) do
            if r.kind == "task" then
                task_uuids[#task_uuids + 1] = r.key
            end
        end
        history:push_custom({
            title = label,
            task_uuids = task_uuids,
            refresh = function()
                for _, r in ipairs(bundle) do
                    local current, revision = self.ws:get(r.kind, r.key)
                    local wanted = vim.deepcopy(r[side])
                    if r.kind == "task" then
                        if current then
                            current.updated_at = nil
                        end
                        if wanted then
                            wanted.updated_at = nil
                        end
                    end
                    if vim.deep_equal(current, wanted) then
                        expected[refid(r.kind, r.key)] = revision
                    end
                end
            end,
            apply = function(direction)
                local changes = {}
                for _, r in ipairs(bundle) do
                    local value = direction == "undo" and r.before or r.after
                    if direction == "undo" then
                        value = r.before
                    end -- nil is a meaningful tombstone
                    changes[#changes + 1] = {
                        kind = r.kind,
                        key = r.key,
                        value = value,
                        expected_revision = expected[refid(r.kind, r.key)],
                    }
                end
                local previous = self.ws.group_id
                self.ws.group_id = codec.uuid()
                local ok, restored = pcall(self.ws.restore, self.ws, changes)
                self.ws.group_id = previous
                if not ok then
                    error(restored, 0)
                end
                if label == "Apply AI plan" then
                    self.ws:put("profile", "memory_generation", codec.uuid())
                    for _, record in ipairs(self.ws:list("conversation")) do
                        if record.value.summary then
                            record.value.summary = nil
                            self.ws:put("conversation", record.key, record.value, record.revision)
                        end
                    end
                end
                expected = restored
                side = direction == "undo" and "before" or "after"
                return { title = label }
            end,
        })
    end
    return result
end
function M:add(uuid, date)
    local task = assert(self:task(uuid), "task not found")
    assert(not task.archived_at, "task archived")
    return self:transaction("Today: " .. task.title, function()
        local p = self:today(date)
        for _, i in ipairs(p.items) do
            if i.task_uuid == uuid then
                return
            end
        end
        p.items[#p.items + 1] = {
            task_uuid = uuid,
            group = "next",
            position = #p.items + 1,
            minutes = 30,
            locked = false,
            next_action = "",
            completion = "",
        }
        self.ws:put("plan", p.date, p)
    end)
end
function M:change(date, uuid, patch)
    return self:transaction("Update today", function()
        local p = self:today(date)
        for n, i in ipairs(p.items) do
            if i.task_uuid == uuid then
                if patch == false then
                    table.remove(p.items, n)
                else
                    p.items[n] = vim.tbl_extend("force", i, patch)
                end
                self.ws:put("plan", p.date, p)
                return
            end
        end
    end)
end
function M:move(date, uuid, delta)
    return self:transaction("Reorder today", function()
        local p = self:today(date)
        for n, i in ipairs(p.items) do
            if i.task_uuid == uuid then
                local other = n + delta
                if other >= 1 and other <= #p.items then
                    p.items[n], p.items[other] = p.items[other], p.items[n]
                end
                break
            end
        end
        for n, i in ipairs(p.items) do
            i.position = n
        end
        self.ws:put("plan", p.date, p)
    end)
end
function M:create(input, date)
    return self:transaction("Create today task", function()
        local t, errors = self.service:create(input)
        assert(t, vim.inspect(errors))
        self:add(t.sync_uuid, date)
        return t
    end)
end
function M:apply(draft, selected)
    local saved_draft = self.ws:get("draft", draft.id)
    if saved_draft and saved_draft.status == "applied" then
        -- Reopening an old review or pressing a twice must never apply twice.
        return saved_draft
    end
    return self:transaction("Apply AI plan", function()
        local plan = self:today(draft.date or self:date())
        local created = {}
        assert(draft.plan_revision == select(2, self.ws:get("plan", plan.date)), "plan changed since generation")
        -- Validate all preconditions before any changes, then execute atomically.
        for _, c in ipairs(draft.changes) do
            if selected[c.id] then
                assert(
                    c.kind ~= "task_update" and c.kind ~= "task_create" or draft.extended,
                    "extended changes disabled"
                )
                if c.task_uuid then
                    local t = assert(self:task(c.task_uuid), "task missing")
                    if c.expected_revision then
                        assert(c.expected_revision == t.sync_revision, "task changed: " .. t.title)
                    end
                    assert(not t.archived_at, "task archived")
                    if c.kind:match("^plan_") then
                        for _, item in ipairs(plan.items) do
                            assert(
                                item.task_uuid ~= c.task_uuid or not item.locked,
                                "locked task requires manual unlock: " .. t.title
                            )
                        end
                    end
                end
            end
        end
        for _, c in ipairs(draft.changes) do
            if selected[c.id] then
                local a = c.after or {}
                if c.kind == "task_create" then
                    local t, errors = self.service:create(a)
                    assert(t, vim.inspect(errors))
                    created[c.id] = t.sync_uuid
                elseif c.kind == "plan_remove" then
                    plan.items = vim.tbl_filter(function(i)
                        return i.task_uuid ~= c.task_uuid
                    end, plan.items)
                elseif c.kind == "plan_add" or c.kind == "plan_update" then
                    local uuid = c.task_uuid or a.task_uuid or created[a.created_by]
                    assert(self:task(uuid), "unknown task in plan")
                    assert(type(a.minutes) == "number" and a.minutes >= 0 and a.minutes <= 1440, "invalid estimate")
                    assert(vim.tbl_contains({ "now", "next", "optional" }, a.group or "next"), "invalid group")
                    local item = vim.tbl_extend(
                        "force",
                        { group = "next", locked = false, position = #plan.items + 1 },
                        a,
                        { task_uuid = uuid }
                    )
                    local found = false
                    for n, i in ipairs(plan.items) do
                        if i.task_uuid == uuid then
                            plan.items[n] = item
                            found = true
                            break
                        end
                    end
                    if not found then
                        plan.items[#plan.items + 1] = item
                    end
                elseif c.kind == "note" then
                    assert(c.task_uuid and type(a.text) == "string", "invalid note")
                    self.ws:put(
                        "note",
                        codec.uuid(),
                        { task_uuid = c.task_uuid, text = a.text, source = "ai", created_at = os.time() }
                    )
                elseif c.kind == "description" or c.kind == "task_update" then
                    local t = assert(self:task(c.task_uuid), "task missing")
                    local patch = vim.tbl_extend("force", t, a)
                    if c.kind == "description" then
                        patch = vim.tbl_extend("force", t, { description = assert(a.description) })
                    end
                    patch.deadline = a.deadline ~= nil and a.deadline or require("todo.model").deadline_text(patch)
                    if patch.deadline ~= require("todo.model").deadline_text(t) and patch.reminder then
                        local deadline = require("todo.model").parse_deadline(patch.deadline)
                        if deadline then
                            patch.reminder = vim.deepcopy(patch.reminder)
                            patch.reminder.scheduled_at = deadline.epoch
                            patch.reminder.next_reminder_at = deadline.epoch
                            patch.reminder.occurrence_started_at = deadline.epoch
                            patch.reminder.snoozed_until = nil
                            patch.reminder.last_reminded_at = nil
                        end
                    end
                    local t2, errors = self.service:update(t.id, patch, t.sync_revision)
                    assert(t2, vim.inspect(errors))
                    if t.status ~= patch.status then
                        assert(self.service:set_status(t.id, patch.status))
                    end
                else
                    error("unknown AI operation: " .. tostring(c.kind))
                end
            end
        end
        table.sort(plan.items, function(a, b)
            return (a.position or 0) < (b.position or 0)
        end)
        self.ws:put("plan", plan.date, plan)
        local saved = vim.deepcopy(draft)
        saved.status = "applied"
        saved.applied_at = os.time()
        self.ws:put("draft", draft.id, saved)
        if draft.workflow_id then
            local workflow = self.ws:get("conversation", draft.workflow_id)
            if workflow then
                workflow.status = "applied"
                self.ws:put("conversation", draft.workflow_id, workflow)
            end
        end
    end)
end
return M
