-- One durable planning workflow per date. Item ledgers survive every reopen.
local M = {}
M.__index = M
local instances = setmetatable({}, { __mode = "k" })
local codec = require("todo.sync.codec")
local uv = vim.uv or vim.loop
local function cfg()
    return require("todo.config").get()
end
local function T(en, zh)
    return cfg().language == "zh-CN" and zh or en
end
local function change_counts(changes)
    local counts = {}
    for _, change in ipairs(changes or {}) do
        counts[change.kind] = (counts[change.kind] or 0) + 1
    end
    return counts
end
local function counts_text(counts)
    local parts = {}
    for _, kind in ipairs({ "description", "note", "plan_add", "plan_update", "plan_remove" }) do
        if counts[kind] and counts[kind] > 0 then
            local label = ({
                description = T("description", "描述"),
                note = T("note", "备注"),
                plan_add = T("plan", "排期"),
                plan_update = T("plan", "排期"),
                plan_remove = T("plan", "排期"),
            })[kind]
            parts[#parts + 1] = label .. " " .. counts[kind]
        end
    end
    return table.concat(parts, " · ")
end
function M.new(ws, svc, ai, date, opts)
    opts = opts or {}
    date = date or require("todo.planning").new(ws, svc):date()
    assert(require("todo.model").parse_deadline(date), "invalid date")
    local view = opts.view or "today"
    local filter_tag = opts.filters and opts.filters.tag or nil
    local origin = view == "by_tag" and filter_tag and ("by_tag:" .. filter_tag) or view
    local id = "daily:" .. origin .. ":" .. date
    instances[ws] = instances[ws] or {}
    if instances[ws][id] then
        local existing = instances[ws][id]
        if not existing.busy then
            existing.state = ws:get("conversation", existing.id) or existing.state
            existing:refresh()
        end
        return existing
    end
    local planner = require("todo.planning").new(ws, svc)
    local plan = planner:today(date)
    local self = setmetatable(
        {
            ws = ws,
            service = svc,
            ai = ai,
            planner = planner,
            id = id,
            date = date,
            origin = origin,
            view = view,
            filters = vim.deepcopy(opts.filters or {}),
            seed_uuids = vim.deepcopy(opts.task_uuids or {}),
            listeners = {},
            busy = false,
        },
        M
    )
    self.state = ws:get("conversation", id)
        or {
            id = id,
            scope = "daily_planning",
            schema_version = 1,
            date = date,
            origin = origin,
            seed_uuids = vim.deepcopy(opts.task_uuids or {}),
            view = view,
            filters = vim.deepcopy(opts.filters or {}),
            status = "preparing",
            queue = {},
            task_refs = {},
            messages = {},
            created_at = os.time(),
            capacity_minutes = plan.capacity_minutes,
            reserve_minutes = math.floor(plan.capacity_minutes * plan.reserve_ratio + 0.5),
            locks_confirmed = false,
            text_only = cfg().ai.text_only,
        }
    self.state.origin = self.state.origin or origin
    self.state.view = self.state.view or view
    self.state.filters = self.state.filters or vim.deepcopy(opts.filters or {})
    self.state.seed_uuids = self.state.seed_uuids or vim.deepcopy(opts.task_uuids or {})
    local directory = vim.fn.stdpath("state") .. "/todo.nvim/daily-drafts"
    vim.fn.mkdir(directory, "p", 448)
    self.cache_path = directory .. "/" .. vim.fn.sha256(ws.store.path .. ":" .. id) .. ".json"
    self.cache = {}
    if uv.fs_stat(self.cache_path) then
        local ok, value = pcall(function()
            return vim.json.decode(table.concat(vim.fn.readfile(self.cache_path), "\n"))
        end)
        if ok and type(value) == "table" then
            self.cache = value
        end
    end
    self.mode = require("todo.ai.permissions").mode(cfg().ai.mode)
    self:refresh()
    instances[ws][id] = self
    return self
end
function M:on_change(fn)
    self.listeners[fn] = true
    return function()
        self.listeners[fn] = nil
    end
end
function M:emit()
    for fn in pairs(self.listeners) do
        local ok, err = pcall(fn)
        if not ok then
            require("todo.diagnostics").record({ operation = "Daily UI", stage = "render", error = tostring(err) })
        end
    end
end
function M:save()
    self.state.updated_at = os.time()
    self.ws:put("conversation", self.id, self.state)
    self:emit()
end
function M:save_cache()
    local tmp = self.cache_path .. ".tmp"
    local fd = assert(uv.fs_open(tmp, "w", 384))
    assert(uv.fs_write(fd, codec.encode(self.cache), 0))
    uv.fs_close(fd)
    assert(uv.fs_rename(tmp, self.cache_path))
end
local function day_before(date)
    local year, month, day = date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not year then
        return date
    end
    local noon = os.time({ year = tonumber(year), month = tonumber(month), day = tonumber(day), hour = 12 })
    return os.date("%Y-%m-%d", noon - 86400)
end

function M:compute_seed()
    local seed = {}
    local function add(uuid)
        if uuid then
            seed[uuid] = true
        end
    end
    if self.state.seed_uuids and #self.state.seed_uuids > 0 then
        for _, uuid in ipairs(self.state.seed_uuids) do
            add(uuid)
        end
    elseif self.origin == "today" then
        for _, item in ipairs(self.planner:today(self.date).items) do
            add(item.task_uuid)
        end
        local previous = day_before(self.date)
        for _, item in ipairs(self.planner:today(previous).items) do
            local task = self.planner:task(item.task_uuid)
            if task and not task.archived_at and (task.status == "todo" or task.status == "in_progress") then
                add(item.task_uuid)
            end
        end
    end
    local result = {}
    for uuid in pairs(seed) do
        result[#result + 1] = uuid
    end
    table.sort(result)
    return result
end

function M:refresh()
    local by_uuid, tasks = {}, {}
    local plan = self.planner:today(self.date)
    for _, item in ipairs(plan.items) do
        by_uuid[item.task_uuid] = item
    end
    for _, task in ipairs(self.service.store:list({ archived = false })) do
        if task.status == "todo" or task.status == "in_progress" then
            tasks[task.sync_uuid] = task
        end
    end
    local seed = self:compute_seed()
    local wanted = {}
    for _, uuid in ipairs(seed) do
        wanted[uuid] = true
    end
    -- Existing manual additions survive a refresh. Unseeded legacy entries are
    -- dropped so an old "all tasks" session cannot leak into the new scope.
    local kept, known = {}, {}
    for _, entry in ipairs(self.state.queue) do
        if wanted[entry.uuid] or entry.manual then
            entry.missing = tasks[entry.uuid] == nil
            kept[#kept + 1] = entry
            known[entry.uuid] = entry
        end
    end
    self.state.queue = kept
    local next_ref = 0
    for ref in pairs(self.state.task_refs) do
        next_ref = math.max(next_ref, tonumber(ref:match("^t(%d+)$")) or 0)
    end
    local function ensure(uuid, selected, manual)
        local task = tasks[uuid]
        if not task then
            return
        end
        local e = known[uuid]
        if not e then
            next_ref = next_ref + 1
            e = {
                uuid = uuid,
                ref = "t" .. next_ref,
                selected = selected == true,
                manual = manual == true,
                locked = by_uuid[uuid] and by_uuid[uuid].locked == true or false,
            }
            known[uuid] = e
            self.state.queue[#self.state.queue + 1] = e
            self.state.task_refs[e.ref] = uuid
        end
        e.task_id = task.id
        e.title = task.title
        e.priority = task.priority
        e.status = task.status
        e.due_date = task.due_date
        e.missing = false
    end
    for _, uuid in ipairs(seed) do
        ensure(uuid, false, false)
    end
    for _, entry in ipairs(self.state.queue) do
        if entry.uuid and tasks[entry.uuid] then
            ensure(entry.uuid, entry.selected, entry.manual)
        end
    end
    table.sort(self.state.queue, function(a, b)
        if (by_uuid[a.uuid] ~= nil) ~= (by_uuid[b.uuid] ~= nil) then
            return by_uuid[a.uuid] ~= nil
        end
        if (a.status == "in_progress") ~= (b.status == "in_progress") then
            return a.status == "in_progress"
        end
        if a.due_date ~= b.due_date then
            return (a.due_date or "9999") < (b.due_date or "9999")
        end
        if a.priority ~= b.priority then
            return (a.priority or 3) < (b.priority or 3)
        end
        return a.uuid < b.uuid
    end)
    return self.state.queue
end
function M:item_id(entry)
    return "daily-item:" .. self.origin .. ":" .. self.date .. ":" .. entry.uuid
end

function M:add_task(uuid)
    local task
    for _, candidate in ipairs(self.service.store:list({ archived = false })) do
        if candidate.sync_uuid == uuid then
            task = candidate
            break
        end
    end
    assert(task and not task.archived_at, "Only active tasks can be added")
    assert(task.status == "todo" or task.status == "in_progress", "Only unfinished tasks can be added")
    for _, entry in ipairs(self.state.queue) do
        if entry.uuid == uuid then
            entry.selected = true
            entry.manual = true
            self:save()
            return entry
        end
    end
    local next_ref = 0
    for ref in pairs(self.state.task_refs) do
        next_ref = math.max(next_ref, tonumber(ref:match("^t(%d+)$")) or 0)
    end
    local ref = "t" .. (next_ref + 1)
    local entry = {
        uuid = uuid,
        ref = ref,
        selected = true,
        manual = true,
        locked = false,
        task_id = task.id,
        title = task.title,
        priority = task.priority,
        status = task.status,
        due_date = task.due_date,
        missing = false,
    }
    self.state.task_refs[ref] = uuid
    self.state.queue[#self.state.queue + 1] = entry
    self:save()
    return entry
end
function M:item(entry)
    return self.ws:get("conversation", self:item_id(entry))
        or self.ws:get("conversation", "daily-item:" .. self.date .. ":" .. entry.uuid)
end
function M:document(entry)
    return require("todo.memory").new(self.ws, self.service):task_document(self.service.store:get(entry.task_id))
end
function M:checked(entry)
    local s = self:item(entry)
    if not s or not s.review then
        return false
    end
    local task = self.service.store:get(entry.task_id)
    if not task or s.checked_revision ~= task.sync_revision then
        return false
    end
    local doc = self:document(entry)
    return s
        and task
        and s.checked_revision == task.sync_revision
        and doc
        and s.checked_hash == doc.hash
        and s.review ~= nil
end
function M:counts()
    local total, done = 0, 0
    for _, e in ipairs(self.state.queue) do
        if e.selected and not e.missing then
            total = total + 1
            if self:checked(e) or e.deferred then
                done = done + 1
            end
        end
    end
    return done, total
end
function M:progress()
    local total, checked, deferred = 0, 0, 0
    for _, e in ipairs(self.state.queue) do
        if e.selected and not e.missing then
            total = total + 1
            if e.deferred then
                deferred = deferred + 1
            elseif self:checked(e) then
                checked = checked + 1
            end
        end
    end
    return {
        total = total,
        checked = checked,
        deferred = deferred,
        remaining = math.max(0, total - checked - deferred),
    }
end
function M:phase()
    if self.busy then
        return self.state.status == "assembling" and "arranging" or "clarifying"
    end
    if self.state.last_error then
        return "error"
    end
    local status = self.state.status
    if status == "preparing" then
        return "preparing"
    elseif status == "assembling" then
        return "arranging"
    elseif status == "review" then
        return "reviewing"
    elseif status == "applied" then
        return "applied"
    elseif status == "paused" then
        return "paused"
    end
    return "clarifying"
end
function M:event(kind, text)
    self.state.events = self.state.events or {}
    self.state.events[#self.state.events + 1] =
        { kind = kind, text = tostring(text or ""):sub(1, 300), at = os.time() }
    while #self.state.events > 40 do
        table.remove(self.state.events, 1)
    end
    self:save()
end
function M:toggle_deferred(entry)
    entry = entry or self:current()
    assert(entry, "No current task")
    if entry.deferred then
        entry.deferred = nil
        self:event("restored", T("Restored: ", "已恢复：") .. (entry.title or entry.uuid))
    else
        entry.deferred = T("User deferred this task", "用户选择稍后处理")
        self:event("deferred", T("Deferred: ", "已跳过：") .. (entry.title or entry.uuid))
    end
end
function M:current()
    for _, entry in ipairs(self.state.queue) do
        if entry.uuid == self.state.current_uuid then
            return entry
        end
    end
end
function M:prepare(allow_full)
    assert(not self.busy, "Planning already running")
    self:refresh()
    local capacity, reserve = tonumber(self.state.capacity_minutes), tonumber(self.state.reserve_minutes)
    assert(capacity and capacity > 0 and capacity <= 1440 and capacity % 1 == 0, "Invalid work time")
    assert(reserve and reserve >= 0 and reserve < capacity and reserve % 1 == 0, "Invalid reserve time")
    assert(self.state.locks_confirmed, "Confirm existing locks before starting")
    local fixed = 0
    local plan = self.planner:today(self.date)
    for _, item in ipairs(plan.items) do
        for _, entry in ipairs(self.state.queue) do
            if entry.uuid == item.task_uuid and entry.locked and not entry.missing then
                fixed = fixed + (item.minutes or 0)
            end
        end
    end
    local _, total = self:counts()
    assert(total > 0, "No unfinished tasks selected")
    if fixed >= capacity - reserve and not allow_full then
        return nil,
            "固定事项已占满可安排时间；请调整容量、解锁，或按 S 明确保持固定继续分析。"
    end
    self.planner:transaction("Daily preparation", function()
        plan.capacity_minutes = capacity
        plan.reserve_ratio = reserve / capacity
        for _, item in ipairs(plan.items) do
            for _, entry in ipairs(self.state.queue) do
                if item.task_uuid == entry.uuid then
                    item.locked = entry.locked
                end
            end
        end
        self.ws:put("plan", self.date, plan)
    end)
    self.state.status = "paused"
    self.state.last_error = nil
    self.state.draft_id = nil
    self.state.summary = nil
    self:save()
    return true
end
function M:budget()
    local usage = self.ai:usage(self.id)
    local _, total = self:counts()
    local a = cfg().ai
    local limit = a.planning.max_requests_total or total * a.planning.max_requests_per_item + 2
    assert(
        usage.requests < limit,
        "规划请求额度已达到上限；可调整 ai.planning.max_requests_total 后继续。"
    )
    assert(
        not a.session_budget_usd or usage.usd < a.session_budget_usd,
        "本次规划费用已达到预算；可修改预算后继续，已完成结果会保留。"
    )
    assert(not a.daily_budget_usd or self.ai:usage().today_usd < a.daily_budget_usd, "今日费用已达到预算。")
end
-- Classify a stored failure so the UI can offer the matching budget control.
function M:budget_error()
    local err = tostring(self.state.last_error or "")
    if err == "" then
        return nil
    end
    if err:find("今日费用", 1, true) or err:lower():find("daily budget", 1, true) then
        return "daily"
    end
    if err:find("本次规划费用", 1, true) or err:lower():find("session budget", 1, true) then
        return "session"
    end
end
function M:checkpoint(callback)
    local sync = cfg().sync
    if sync.enabled and sync.provider == "server" then
        self.io = require("todo.cloud").run(self.ws, vim.tbl_extend("force", sync, { quiet = true }), callback)
    else
        callback()
    end
end
function M:_finish(status, err)
    if self.finishing then
        return
    end
    self.finishing = true
    self.state.status = status
    self.state.last_error = err
    self:save()
    if self.lease_timer then
        self.lease_timer:stop()
        self.lease_timer:close()
        self.lease_timer = nil
    end
    local function released(sync_error)
        local function done()
            self.busy = false
            self.request_started = nil
            self.finishing = false
            self.pausing = false
            self.request = nil
            self.permission, self.permission_reply = nil, nil
            self.io = nil
            if sync_error then
                self.state.last_error = sync_error
                self.state.status = "paused"
                self:save()
            end
            self:emit()
        end
        if self.lease then
            local lease = self.lease
            self.lease = nil
            require("todo.cloud").release_lease(
                self.lease_id,
                self.owner,
                lease.token,
                cfg().sync,
                function(release_error)
                    if release_error then
                        self.state.last_error = release_error
                    end
                    done()
                end
            )
        else
            done()
        end
    end
    self:checkpoint(released)
end
function M:pause()
    self:save_cache()
    if not self.busy then
        if self.state.status == "review" or self.state.status == "applied" or self.state.status == "preparing" then
            return
        end
        self.state.status = "paused"
        self:save()
        return
    end
    self.pausing = true
    if self.request and self.request.running then
        self.request.cancel()
    elseif self.io and self.io.running then
        self.io.cancel()
    else
        self:_finish("paused")
    end
end
function M:overview()
    local result = {}
    for _, e in ipairs(self.state.queue) do
        if e.selected and not e.missing then
            result[#result + 1] = {
                task_ref = e.ref,
                title = e.title,
                priority = e.priority,
                status = e.status,
                due_date = e.due_date,
                locked = e.locked,
            }
        end
    end
    return result
end
function M:set_mode(mode)
    assert(not self.busy, "Stop the active request before changing permission mode")
    self.mode = require("todo.ai.permissions").mode(mode)
    self:emit()
end
function M:decide_permission(decision)
    assert(self.permission and self.permission_reply, "No permission request is pending")
    local reply = self.permission_reply
    self.permission, self.permission_reply = nil, nil
    self:emit()
    reply(decision, decision == "deny" and "User rejected" or "User approved exact request")
end
local common =
    [[Return JSON only, with "message" FIRST: a concise explanation for the user in their language. This field streams to the UI. Do not expose internal reasoning or raw protocol. Never say a change has been applied. The host applies changes according to the displayed mode and configured policy. Do not claim successful writes before the host reports them.]]
function M:_request(session, text, opts, callback)
    opts = vim.tbl_extend("force", opts or {}, {
        mode = self.mode,
        on_permission = function(request, reply)
            self.permission, self.permission_reply = request, reply
            self:emit()
            return {
                cancel = function()
                    self.permission, self.permission_reply = nil, nil
                    self:emit()
                end,
            }
        end,
        managed = true,
        quiet = true,
        workflow_id = self.id,
        stream = cfg().ai.planning.stream,
        on_delta = function(value)
            self.partial = value
            self.cache.partial = { session_id = session.id, text = value, interrupted = true }
            if not self.partial_cache_pending then
                self.partial_cache_pending = true
                vim.defer_fn(function()
                    self.partial_cache_pending = false
                    self:save_cache()
                end, 1000)
            end
            self:emit()
        end,
        on_stage = function(stage)
            self.stage = stage
            self:emit()
        end,
        before_request = function()
            assert(not self.pausing, "cancelled")
            self:budget()
        end,
    })
    local ok, result = pcall(self.ai.send, self.ai, session.id, text, opts, function(err, s)
        self.request = nil
        if self.pausing then
            self:_finish("paused")
            return
        end
        if err then
            self:_finish("paused", err)
            return
        end
        self.cache.partial = nil
        self.partial = nil
        self:save_cache()
        local success, failure = pcall(callback, s)
        if not success then
            self:_finish("paused", tostring(failure))
        end
    end)
    if ok then
        if self.ai.active[session.id] then
            self.request = result
        end
    else
        self:_finish("paused", tostring(result))
    end
end
function M:_drive(answer)
    if self.pausing then
        self:_finish("paused")
        return
    end
    self:refresh()
    local entry
    if answer then
        entry = self:current()
    end
    if not entry then
        for _, e in ipairs(self.state.queue) do
            if e.selected and not e.missing and not e.deferred and not self:checked(e) then
                entry = e
                break
            end
        end
    end
    if not entry then
        self:_assemble()
        return
    end
    self.state.current_uuid = entry.uuid
    self.state.status = "reviewing"
    self:save()
    local doc = assert(self:document(entry), "Task no longer exists")
    local task = assert(self.service.store:get(entry.task_id), "Task no longer exists")
    local s = self:item(entry)
    if s then
        s = self.ai:resume(s.id)
    end
    if not s then
        s = self.ai:start({
            id = self:item_id(entry),
            scope = "daily_item",
            workflow_id = self.id,
            date = self.date,
            task_id = entry.task_id,
            max_questions = cfg().ai.planning.max_rounds_per_item,
            max_requests = cfg().ai.planning.max_requests_per_item,
            text_only = self.state.text_only,
        })
    end
    if s.requests >= s.max_requests then
        entry.deferred = "任务请求额度已用完，保留未知信息"
        self:save()
        vim.schedule(function()
            self:_drive()
        end)
        return
    end
    local retry_last = not answer and s.status == "error" and s.pending_request ~= nil
    if s.round and s.round.status == "pending" and not answer and not retry_last then
        self:_finish("awaiting")
        return
    end
    s.prior_reviews = {}
    local prior = self.ws:list("conversation")
    table.sort(prior, function(a, b)
        return (a.value.date or "") > (b.value.date or "")
    end)
    for _, record in ipairs(prior) do
        local old = record.value
        if old.scope == "daily_item" and old.subject_uuid == entry.uuid and old.date < self.date and old.review then
            s.prior_reviews[#s.prior_reviews + 1] = { date = old.date, review = old.review }
            if #s.prior_reviews >= 3 then
                break
            end
        end
    end
    s.text_only = self.state.text_only
    if s.text_only == nil then
        s.text_only = cfg().ai.text_only
    end
    s.intent = self.state.intent
    s.task_refs = vim.deepcopy(self.state.task_refs)
    s.overview = self:overview()
    self.ws:put("conversation", s.id, s)
    local force = s.questions >= s.max_questions or s.requests >= s.max_requests - 1 or answer and answer.force
    local attachments = vim.deepcopy(answer and answer.attachments or {})
    vim.list_extend(attachments, require("todo.assets").refs(self.state.intent or ""))
    local function evidence_sources(session, research)
        local sources = {}
        local function add(value)
            if type(value) == "string" and value ~= "" then
                sources[#sources + 1] = value
            end
        end
        local function add_round(round)
            if type(round) ~= "table" or type(round.questions) ~= "table" then
                return
            end
            for _, q in ipairs(round.questions) do
                add(q.header)
                add(q.question)
                for _, option in ipairs(q.options or {}) do
                    add(option.label)
                    add(option.description)
                end
            end
        end
        -- Separate sources: a quote must not accidentally span unrelated records.
        for i = #session.messages, 1, -1 do
            local msg = session.messages[i]
            if msg.role == "user" and msg.origin ~= "workflow" and type(msg.content) == "string" then
                add(msg.content)
            end
        end
        add_round(session.round)
        for _, item in ipairs(self:overview()) do
            add(item.title)
        end
        add(self.state.intent)
        add(doc.text)
        add(task.title)
        add(research)
        return sources
    end
    self:_request(
        s,
        answer and answer.text
            or "Read this task completely and decide what information is still missing. Ask only useful unknowns; otherwise finish this item.",
        {
            retry_last = retry_last,
            message_origin = not answer and "workflow" or nil,
            message_display = answer and answer.display,
            repair_prompt = function(reason, session, research)
                if reason:find("understanding evidence", 1, true) or reason:find("Understanding evidence", 1, true) then
                    return require("todo.ai.evidence").repair(evidence_sources(session, research))
                end
                if reason:find("Goal is unclear", 1, true) then
                    return 'Set understanding.goal_clear=false and return questions ONLY with intent exactly "goal", "scope" or "deliverable". Do not ask progress, estimate or dependency questions until the goal and deliverable are grounded.'
                end
            end,
            validate_result = function(result, session, research_evidence, repairing)
                if result.action == "lookup" then
                    return
                end
                local read = session.read_sources and session.read_sources[entry.uuid]
                assert(
                    read and read.complete and read.hash == doc.hash,
                    "Read the FULL current task and notes before asking questions or completing review"
                )
                local degraded = false
                local u = result.understanding
                if type(u) ~= "table" then
                    if not repairing then
                        assert(
                            false,
                            "Include understanding with goal_clear, goal, deliverable, unknowns and evidence before asking questions"
                        )
                    end
                    u = { goal_clear = false, goal = "", deliverable = "", unknowns = {}, evidence = {} }
                    result.understanding = u
                    degraded = true
                end
                if u.goal_clear == "true" then
                    u.goal_clear = true
                elseif u.goal_clear == "false" then
                    u.goal_clear = false
                end
                if type(u.goal_clear) ~= "boolean" then
                    if not repairing then
                        assert(
                            false,
                            "Include understanding with goal_clear, goal, deliverable, unknowns and evidence before asking questions"
                        )
                    end
                    u.goal_clear = false
                    degraded = true
                end
                u.goal = type(u.goal) == "string" and vim.fn.strcharpart(u.goal, 0, 1500) or ""
                u.deliverable = type(u.deliverable) == "string" and vim.fn.strcharpart(u.deliverable, 0, 1500) or ""
                local unknowns = {}
                if type(u.unknowns) == "table" and vim.islist(u.unknowns) then
                    for _, value in ipairs(u.unknowns) do
                        if type(value) == "string" and value ~= "" then
                            unknowns[#unknowns + 1] = vim.fn.strcharpart(value, 0, 800)
                            if #unknowns >= 8 then
                                break
                            end
                        end
                    end
                end
                u.unknowns = unknowns
                local evidence_list = {}
                if type(u.evidence) == "table" and vim.islist(u.evidence) then
                    evidence_list = u.evidence
                elseif type(u.evidence) == "string" and u.evidence ~= "" then
                    evidence_list = { u.evidence }
                end
                local quotes = {}
                for _, quote in ipairs(evidence_list) do
                    if type(quote) == "string" and quote ~= "" then
                        quotes[#quotes + 1] = quote
                        if #quotes >= 50 then
                            break
                        end
                    end
                end
                u.evidence = quotes
                local sources = evidence_sources(session, research_evidence)
                local verified = {}
                for _, quote in ipairs(u.evidence) do
                    if require("todo.ai.evidence").matches(quote, sources) then
                        verified[#verified + 1] = quote
                        if #verified >= 6 then
                            break
                        end
                    end
                end
                u.evidence = verified
                if u.goal_clear then
                    if u.goal == "" or u.deliverable == "" then
                        if repairing then
                            u.goal_clear = false
                            degraded = true
                        else
                            assert(
                                false,
                                "A clear goal requires an evidenced goal and deliverable"
                            )
                        end
                    end
                    if u.goal_clear and #verified == 0 then
                        if repairing then
                            u.goal_clear = false
                            degraded = true
                        else
                            assert(
                                false,
                                "Understanding evidence must quote current task text, user answers, intent or approved research; only whitespace differences are allowed"
                            )
                        end
                    end
                end
                if result.action == "question" and not degraded and not u.goal_clear then
                    for _, q in ipairs(result.round.questions) do
                        if not ({ goal = true, scope = true, deliverable = true })[q.intent] then
                            if repairing then
                                degraded = true
                                break
                            end
                            assert(
                                false,
                                "Goal is unclear: clarify goal/scope/deliverable before progress or estimates"
                            )
                        end
                    end
                end
                if degraded then
                    if #u.unknowns < 8 then
                        u.unknowns[#u.unknowns + 1] = "Understanding evidence could not be verified"
                    end
                    require("todo.diagnostics").record({
                        operation = "AI evidence",
                        stage = "degraded",
                        status = "complete",
                        error = "Understanding could not be fully verified; continuing without blocking",
                    })
                    self:event(
                        "warning",
                        T(
                            "Evidence could not be fully verified; continuing with assumptions.",
                            "证据未完全核对，已按假设继续。"
                        )
                    )
                end
                if result.action == "draft" then
                    assert(result.review, "Finish using item_review with a review object")
                end
            end,
            round_id = answer and answer.round_id,
            attachments = attachments,
            force_final = force,
            system_tail = common
                .. [[
UNDERSTANDING FIRST: Read title, full description, notes and prior explicit answers before asking anything. In EVERY question/item_review response include understanding:{goal_clear:boolean,goal:string,deliverable:string,unknowns:[short strings],evidence:[exact short quotes from this task, user answers or approved research excerpts]}. Explain this understanding in message, without claiming certainty you lack. A title/status alone does not establish a concrete goal, scope or completion criterion. If unclear, goal_clear=false and ask ONLY goal/scope/deliverable questions, each with intent:"goal"|"scope"|"deliverable". Do not ask how far the work has progressed until you understand what the work means. Once goal and deliverable are grounded, ask only decision-relevant missing progress/estimate/dependency questions with intent:"progress"|"estimate"|"dependency". Never run a fixed questionnaire or repeat facts already provided. If no useful question remains, finish immediately. If forced to finish with unclear goal, keep goal_clear=false and list uncertainty; never fabricate evidence. External research may be requested only to resolve a specific uncertainty, respecting permissions. Users can select an option AND add supplemental text/option notes; consider all of them. A note on an unselected option is still explicit user information; it does not imply acceptance of the option label. Quotes must be short verbatim excerpts, never translations or paraphrases; only whitespace may differ.
FOLLOW-UP QUALITY: Rounds are adaptive. Ask 3-4 related questions when several gaps remain, and follow up on the user's previous answers instead of starting over. If an answer is vague, ask what specifically is meant. If an answer changes the plan, revisit the affected unknowns. If the user sends free-form guidance, treat it as explicit steering and revise the round or finish. Offer enough options: 3-5 for every choice question, including less obvious alternatives, tradeoffs, edge cases and an explicit "Other / not sure" when needed. Use multiple=true when several independent choices may apply. Do not reduce a nuanced decision to two options.
DAILY ITEM REVIEW. Focus only on the current task; overview is context for dependencies. Never schedule every task in this response. Ask up to 4 related questions in one round with action="question" and questions as specified above, or finish using {"message":"...","action":"item_review","summary":"confirmed facts and explicit unknowns","review":{"minutes":30,"next_action":"...","completion":"...","dependencies":[],"unresolved":[]},"changes":[]}.
Changes in an item review may ONLY propose description or note improvements for this current task, using its exact task_ref. Use user answers/images and preserve uncertainty. Estimates are remaining work, not time already spent. Avoid repeating already answered questions. At the round/request limit, finish with explicit assumptions instead of asking again.]],
        },
        function(result)
            if result.round and result.round.status == "pending" then
                self:_finish("awaiting")
                return
            end
            local draft = assert(self.ws:get("draft", result.draft_id), "Missing item result")
            assert(draft.review, "AI must return item_review when completing an item")
            for _, change in ipairs(draft.changes) do
                assert(
                    change.kind == "description" or change.kind == "note",
                    "Item review cannot alter scheduling or task status"
                )
            end
            result.review = draft.review
            local applied_count = 0
            if self.mode ~= "plan" and cfg().ai.permissions.auto_apply_documents and #draft.changes > 0 then
                local selected = {}
                for _, change in ipairs(draft.changes) do
                    selected[change.id] = true
                end
                applied_count = #draft.changes
                local counts = change_counts(draft.changes)
                local approved = vim.deepcopy(draft)
                approved.workflow_id = nil
                self.planner:apply(approved, selected)
                draft.status = "applied"
                draft.changes = {}
                self.ws:put("draft", draft.id, draft)
                task = self.service.store:get(entry.task_id)
                doc = self:document(entry)
                result.read_sources[entry.uuid] =
                    { complete = true, hash = doc.hash, offset = vim.fn.strchars(doc.text) }
                local summary = T("Auto-applied ", "已自动应用 ")
                    .. applied_count
                    .. T(" change(s): ", " 项修改：")
                    .. counts_text(counts)
                self:event("applied", summary .. " · " .. (task.title or entry.title or ""))
                vim.notify(summary, vim.log.levels.INFO, { title = "todo.nvim" })
            end
            result.checked_revision = task.sync_revision
            result.checked_hash = doc.hash
            self.ws:put("conversation", result.id, result)
            self:save()
            self:event(
                "reviewed",
                T("Reviewed: ", "已检查：")
                    .. (task.title or entry.title or "")
                    .. " · "
                    .. tostring(draft.review and draft.review.minutes or 0)
                    .. "m"
            )
            if self.can_advance and not self.can_advance() then
                self:_finish("paused", "输入尚未发送；提交或清空后继续。")
                return
            end
            vim.schedule(function()
                if self.busy and not self.pausing then
                    self:_drive()
                end
            end)
        end
    )
end
function M:_assemble()
    self.state.status = "assembling"
    self.state.current_uuid = nil
    local progress = self:progress()
    self:event(
        "arranging",
        T("Arranging: ", "进入编排：")
            .. progress.total
            .. T(" task(s)", " 个任务")
            .. (progress.deferred > 0 and (T(", ", "，") .. progress.deferred .. T(" deferred", " 个已跳过")) or "")
    )
    local reviews, candidates, reads, details = {}, {}, {}, {}
    for _, e in ipairs(self.state.queue) do
        if e.selected and not e.missing then
            candidates[e.uuid] = true
            local s = self:item(e)
            if not e.deferred then
                assert(self:checked(e), "任务已变化，请重新检查：" .. e.title)
            end
            reviews[#reviews + 1] =
                { task_ref = e.ref, title = e.title, locked = e.locked, review = s and s.review, deferred = e.deferred }
            if s and not e.deferred then
                reads[e.uuid] = s.read_sources and s.read_sources[e.uuid]
                local draft = s.draft_id and self.ws:get("draft", s.draft_id)
                for _, change in ipairs(draft and draft.changes or {}) do
                    details[#details + 1] = change
                end
            end
        end
    end
    local s = self.ai:start({
        scope = "daily_final",
        workflow_id = self.id,
        date = self.date,
        max_questions = 0,
        max_requests = 2,
    })
    s.intent = self.state.intent
    s.task_refs = vim.deepcopy(self.state.task_refs)
    s.candidate_uuids = candidates
    s.review_context = reviews
    s.read_sources = reads
    self.ws:put("conversation", s.id, s)
    self:_request(s, "Produce the final executable plan and explain every deferred/unassigned task.", {
        force_final = true,
        validate_result = function(result)
            if result.action ~= "draft" then
                return
            end
            for _, change in ipairs(result.changes) do
                local available = false
                for _, e in ipairs(self.state.queue) do
                    if e.uuid == change.task_uuid then
                        available = e.selected and not e.missing and not e.deferred and not e.locked
                    end
                end
                assert(available, "Cannot schedule excluded, deferred or locked tasks")
            end
        end,
        system_tail = common
            .. [[
DAILY FINAL PLANNING. The reviews field contains prior per-item analysis. Return action="draft" only. Produce ordered now/next/optional items, minutes, next_action and completion. Respect locked items and the exact plan capacity/reserve_ratio. Explain dependencies, overload and unassigned work. Changes may ONLY be plan_add,plan_update,plan_remove: description/note suggestions from item reviews are merged by the application. Never change locked items or schedule deferred items.]],
    }, function(result)
        local draft = assert(self.ws:get("draft", result.draft_id))
        local deferred, locked = {}, {}
        for _, e in ipairs(self.state.queue) do
            if e.deferred then
                deferred[e.uuid] = true
            end
            if e.locked then
                locked[e.uuid] = true
            end
        end
        for _, change in ipairs(draft.changes) do
            assert(change.kind:match("^plan_"), "Final planner may only arrange tasks")
            assert(
                candidates[change.task_uuid] and not deferred[change.task_uuid] and not locked[change.task_uuid],
                "Final plan changed an unavailable or locked task"
            )
        end
        vim.list_extend(draft.changes, details)
        draft.workflow_id = self.id
        draft.session_id = self.id
        self.ws:put("draft", draft.id, draft)
        self.state.draft_id = draft.id
        self.state.summary = draft.summary
        local summary = T("Draft ready: ", "草稿已生成：")
            .. #draft.changes
            .. T(" suggestion(s)", " 项建议")
            .. ((counts_text(change_counts(draft.changes))) ~= "" and (" · " .. counts_text(change_counts(draft.changes))) or "")
        self:event("draft", summary)
        vim.notify(summary, vim.log.levels.INFO, { title = "todo.nvim" })
        self:_finish("review")
    end)
end
function M:start(answer)
    assert(not self.busy, "Planning already running")
    assert(self.state.status ~= "preparing", "Confirm preparation first")
    local ok, err = pcall(self.budget, self)
    if not ok then
        self.state.last_error = tostring(err)
        self:save()
        return
    end
    self.busy = true
    self.request_started = os.time()
    self.pausing = false
    self.finishing = false
    self.partial = nil
    self:emit()
    local function begin(sync_error)
        if sync_error then
            self:_finish("paused", sync_error)
            return
        end
        if self.pausing then
            self:_finish("paused")
            return
        end
        self.state = self.ws:get("conversation", self.id) or self.state
        local success, failure = pcall(self._drive, self, answer)
        if not success then
            self:_finish("paused", tostring(failure))
        end
    end
    local sync = cfg().sync
    if sync.enabled and sync.provider == "server" then
        self.owner = self.ws.store:get_setting("sync_device") or "local"
        self.lease_id = vim.fn.sha256("daily-planning:" .. self.date)
        self.io = require("todo.cloud").acquire_lease(self.lease_id, self.owner, sync, function(failure, lease)
            if failure then
                self:_finish("paused", failure)
                return
            end
            self.lease = lease
            self.lease_timer = uv.new_timer()
            self.lease_timer:start(
                45000,
                45000,
                vim.schedule_wrap(function()
                    require("todo.cloud").renew_lease(self.lease_id, self.owner, lease.token, sync, function(e)
                        if e then
                            self:pause()
                            self.state.last_error = e
                        end
                    end)
                end)
            )
            self:checkpoint(begin)
        end)
    else
        begin()
    end
end
function M:submit(text, round, attachments, force)
    local e = assert(self:current(), "No current task")
    assert(not self.busy, "AI is still replying; stop it before submitting")
    local answer = { text = text, attachments = attachments, force = force }
    if round then
        local missing = require("todo.ai.questions").missing(round)
        if #missing > 0 and force then
            for _, q in ipairs(missing) do
                round.answers[q.id] = round.answers[q.id] or { selected = {}, notes = {} }
                round.answers[q.id].custom = T(
                    "User could not answer; use a reasonable assumption and record it as an unknown.",
                    "用户未能回答；请按合理假设处理，并记入 unknowns。"
                )
            end
        elseif #missing > 0 and type(text) == "string" and vim.trim(text) ~= "" then
            local first = missing[1]
            round.answers[first.id] = round.answers[first.id] or { selected = {}, notes = {} }
            round.answers[first.id].custom = text
            text = ""
        end
        local valid, missing_message = require("todo.ai.questions").validate(round)
        assert(valid, missing_message)
        local s = assert(self:item(e), "No current AI session")
        s = self.ai:resume(s.id)
        assert(s.round and s.round.id == round.id and s.round.status == "pending", "Question round changed")
        s.round = round
        self.ws:put("conversation", s.id, s)
        answer.round_id = round.id
        answer.text = require("todo.ai.questions").transcript(round)
        answer.display = require("todo.ai.questions").display(round)
        if text and text ~= "" then
            answer.text = answer.text .. "\nAdditional answer:\n" .. text
            answer.display = answer.display .. "\n" .. text
        end
    end
    assert(answer.text and answer.text ~= "", "Answer is empty")
    self:start(answer)
end
function M:feedback(text)
    assert(not self.busy, "Stop current request first")
    self.state.intent = (self.state.intent or "") .. "\nPlan feedback:\n" .. text
    self.state.status = "paused"
    self.state.current_uuid = nil
    self.state.draft_id = nil
    self.state.summary = nil
    self:save()
end

--- Free-form steering while a question round is pending. The partial answers
--- travel with the message, but the round itself is superseded and is never
--- treated as submitted.
function M:message(text)
    assert(not self.busy, "AI is still replying; stop it before sending")
    assert(type(text) == "string" and vim.trim(text) ~= "", "Message is empty")
    local entry = assert(self:current(), "No current task")
    local s = assert(self:item(entry), "No current AI session")
    s = self.ai:resume(s.id)
    local partial = ""
    if s.round and s.round.status == "pending" then
        partial = require("todo.ai.questions").display(s.round)
        s.round.status = "superseded"
        self.ws:put("conversation", s.id, s)
    end
    local message = "User guidance for the next questions (not a final answer; do not ignore):\n"
        .. text
    if partial ~= "" then
        message = message .. "\n\nPartial answers so far (draft, not submitted):\n" .. partial
    end
    self:start({ text = message, force = false })
end
function M:skip()
    local e = assert(self:current())
    assert(not self.busy, "Stop the current request first")
    e.deferred = T("User deferred this task", "用户选择稍后处理")
    self:event("deferred", T("Deferred: ", "已跳过：") .. (e.title or e.uuid))
    self:start()
end
return M
