-- Recurring routines are templates. Each matching day materialises one normal
-- task occurrence; completing that task never changes future occurrences.
local M = {}

local codec = require("todo.sync.codec")
local model = require("todo.model")
local recurrence = require("todo.recurrence")

local function L(en, zh)
    return require("todo.config").get().language == "zh-CN" and zh or en
end

local function parse_date(date)
    local value = model.parse_deadline(tostring(date or "") .. " 12:00")
    return value and value.epoch or nil
end

local function date_of(epoch)
    return os.date("%Y-%m-%d", epoch)
end

local function days_between(a, b)
    local left, right = parse_date(a), parse_date(b)
    if not left or not right then
        return nil
    end
    return math.floor((right - left) / 86400 + 0.5)
end

local function weekday(date)
    local epoch = parse_date(date)
    return epoch and tonumber(os.date("%w", epoch)) + 1 or nil
end

local function last_day_of_month(date)
    local year, month = date:match("^(%d%d%d%d)%-(%d%d)")
    if not year then
        return nil
    end
    local next_month = os.time({ year = tonumber(year), month = tonumber(month) + 1, day = 1, hour = 12 })
    return tonumber(os.date("%d", next_month - 86400))
end

local function matches_monthly(rule, start_date, date)
    local day = tonumber(date:sub(9, 10))
    local wanted = tonumber(rule.day_of_month)
    if wanted == -1 then
        if day ~= last_day_of_month(date) then
            return false
        end
    elseif day ~= wanted then
        return false
    end
    local every = tonumber(rule.every) or 1
    if every <= 1 then
        return true
    end
    local sy, sm = start_date:match("^(%d%d%d%d)%-(%d%d)")
    local dy, dm = date:match("^(%d%d%d%d)%-(%d%d)")
    if not sy or not dy then
        return false
    end
    local months = (tonumber(dy) - tonumber(sy)) * 12 + tonumber(dm) - tonumber(sm)
    return months >= 0 and months % every == 0
end

function M.matches(rule, start_date, date)
    rule = rule or {}
    if date < start_date then
        return false
    end
    local diff = days_between(start_date, date)
    if not diff then
        return false
    end
    local every = math.max(1, tonumber(rule.every) or 1)
    if rule.kind == "once" then
        return diff == 0
    elseif rule.kind == "daily" then
        return diff % every == 0
    elseif rule.kind == "weekdays" then
        local day = weekday(date)
        return day ~= nil and day >= 2 and day <= 6
    elseif rule.kind == "weekly" then
        local day = weekday(date)
        local allowed = {}
        for _, value in ipairs(rule.weekdays or {}) do
            allowed[tonumber(value)] = true
        end
        if not allowed[day] then
            return false
        end
        return math.floor(diff / 7) % every == 0
    elseif rule.kind == "monthly" then
        return matches_monthly(rule, start_date, date)
    elseif rule.kind == "interval" then
        local unit = rule.unit or "days"
        if unit ~= "days" then
            -- Sub-day interval reminders are notification-only; the task
            -- occurrence is still materialised once per calendar day.
            return diff % every == 0
        end
        return diff % every == 0
    end
    return false
end

function M.list(ws)
    local result = {}
    for _, record in ipairs(ws:list("routine")) do
        record.value.id = record.key
        result[#result + 1] = record
    end
    table.sort(result, function(a, b)
        return (a.value.title or "") < (b.value.title or "")
    end)
    return result
end

function M.get(ws, id)
    return ws:get("routine", id)
end

function M.create(ws, svc, input, today)
    local title = vim.trim(input.title or "")
    assert(title ~= "", L("Routine title is required", "循环任务标题不能为空"))
    local start_date = input.start_date
    local time = input.time
    if input.trigger then
        local parsed = model.parse_deadline(input.trigger)
        assert(parsed, L("Invalid routine time", "循环任务时间无效"))
        start_date = parsed.date
        time = parsed.time or "09:00"
    end
    assert(start_date and model.parse_deadline(start_date), L("Routine start date is required", "循环任务需要开始日期"))
    local rule = input.recurrence or { kind = "daily", every = 1 }
    local id = codec.uuid()
    local value = {
        title = title,
        description = input.description or "",
        priority = tonumber(input.priority) or 2,
        tags = model.normalize_tags(input.tags),
        start_date = start_date,
        time = time or "09:00",
        end_date = input.end_date,
        max_occurrences = tonumber(input.max_occurrences),
        recurrence = rule,
        enabled = input.enabled ~= false,
        auto_today = input.auto_today ~= false,
        created_at = os.time(),
    }
    ws:put("routine", id, value)
    M.run(ws, svc, today or require("todo.planning").new(ws, svc):date())
    return id, value
end

function M.update(ws, svc, id, input)
    local current = assert(ws:get("routine", id), "routine not found")
    local value = vim.tbl_extend("force", current, input)
    value.id = nil
    ws:put("routine", id, value)
    M.run(ws, svc, require("todo.planning").new(ws, svc):date())
    return value
end

function M.delete(ws, id)
    ws:put("routine", id, nil)
end

function M.set_enabled(ws, svc, id, enabled)
    local value = assert(ws:get("routine", id), "routine not found")
    value.enabled = enabled == true
    ws:put("routine", id, value)
    M.run(ws, svc, require("todo.planning").new(ws, svc):date())
end

function M.run(ws, svc, date)
    if not ws or not svc or not svc.store or not svc.store.db then
        return 0
    end
    date = date or require("todo.planning").new(ws, svc):date()
    local extra = 0
    local planner
    for _, record in ipairs(ws:list("routine")) do
        local routine = record.value
        if routine.enabled ~= false and routine.start_date and routine.start_date <= date then
            if not routine.end_date or date <= routine.end_date then
                if M.matches(routine.recurrence, routine.start_date, date) then
                    local key = record.key .. ":" .. date
                    if not ws:get("routine_run", key) then
                        local task, errors = svc:create({
                            title = routine.title,
                            description = routine.description or "",
                            priority = routine.priority or 2,
                            tags = routine.tags or {},
                            due_date = date,
                            due_time = routine.time,
                            reminder_interval = "1m",
                            reminder = { enabled = true },
                        })
                        if task then
                            if routine.auto_today ~= false then
                                planner = planner or require("todo.planning").new(ws, svc)
                                pcall(planner.add, planner, task.sync_uuid, date)
                            end
                            ws:put("routine_run", key, {
                                routine_id = record.key,
                                date = date,
                                task_uuid = task.sync_uuid,
                            })
                            extra = extra + 1
                        else
                            vim.notify(
                                L("Routine failed: ", "循环任务生成失败：") .. vim.inspect(errors),
                                vim.log.levels.WARN
                            )
                        end
                    end
                end
            end
        end
    end
    return extra
end

function M.occurrences(rule, start_date, limit)
    local result = {}
    local cursor = parse_date(start_date)
    if not cursor then
        return result
    end
    local date = start_date
    for _ = 1, 3660 do
        if M.matches(rule, start_date, date) then
            result[#result + 1] = date
            if #result >= (limit or 5) then
                break
            end
        end
        cursor = cursor + 86400
        date = date_of(cursor)
    end
    return result
end

function M.create_from_notice(ws, svc, input, date)
    local parsed = assert(model.parse_deadline(input.trigger or ""), "routine time required")
    return M.create(ws, svc, {
        title = input.title,
        description = input.description,
        priority = input.priority,
        tags = input.tags,
        start_date = parsed.date,
        time = parsed.time or "09:00",
        recurrence = input.recurrence,
        auto_today = true,
        enabled = true,
    }, date)
end


function M.manage()
    local todo = require("todo")
    local svc = todo._service()
    local ws = svc.store.workspace
    local records = M.list(ws)
    local choices = { { label = "＋ " .. L("New routine", "新建循环任务"), action = "new" } }
    for _, record in ipairs(records) do
        local value = record.value
        local rule = value.recurrence or {}
        local pattern = require("todo.recurrence").label(rule)
        choices[#choices + 1] = {
            label = string.format(
                "%s · %s %s · %s",
                value.title,
                value.time or "09:00",
                pattern,
                value.enabled == false and L("disabled", "已停用") or L("enabled", "启用")
            ),
            action = "edit",
            record = record,
        }
    end
    vim.ui.select(choices, {
        prompt = L("Recurring routines", "循环任务"),
        format_item = function(item)
            return item.label
        end,
    }, function(choice)
        if not choice then
            return
        end
        if choice.action == "new" then
            require("todo.ui.notice_form").open({}, function(input)
                M.create_from_notice(ws, svc, input)
            end, { routine = true })
            return
        end
        local record = choice.record
        local value = record.value
        vim.ui.select({
            L("Edit", "编辑"),
            value.enabled == false and L("Enable", "启用") or L("Disable", "停用"),
            L("Delete", "删除"),
        }, { prompt = value.title }, function(action)
            if action == L("Delete", "删除") then
                local ok = vim.fn.confirm(L("Delete this routine?", "删除这个循环任务？"), L("&Yes\n&No", "&是\n&否"))
                if ok == 1 then
                    M.delete(ws, record.key)
                    vim.notify(L("Routine deleted", "循环任务已删除"))
                end
            elseif action == L("Enable", "启用") or action == L("Disable", "停用") then
                M.set_enabled(ws, svc, record.key, value.enabled == false)
            else
                local fake = {
                    title = value.title,
                    description = value.description,
                    tags = value.tags,
                    due_date = value.start_date,
                    due_time = value.time,
                    reminder = {
                        repeat_interval_seconds = 60,
                        recurrence = value.recurrence,
                        scheduled_at = 0,
                        next_reminder_at = 0,
                    },
                }
                require("todo.ui.notice_form").open(fake, function(input)
                    local parsed = assert(model.parse_deadline(input.trigger or ""), "routine time required")
                    local next_value = vim.deepcopy(value)
                    next_value.title = input.title
                    next_value.description = input.description
                    next_value.tags = model.normalize_tags(input.tags)
                    next_value.start_date = parsed.date
                    next_value.time = parsed.time or value.time
                    next_value.recurrence = input.recurrence
                    M.update(ws, svc, record.key, next_value)
                end, { routine = true })
            end
        end)
    end)
end

return M
