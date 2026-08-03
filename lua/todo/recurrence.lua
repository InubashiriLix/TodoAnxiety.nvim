local M = {}

M.kinds = { once = true, daily = true, weekdays = true, weekly = true, interval = true }
M.units = { minutes = 60, hours = 3600, days = 86400 }

local function calendar_days(epoch, days)
    local parts = os.date("*t", epoch)
    parts.day = parts.day + days
    parts.isdst = nil
    return os.time(parts)
end

local function weekday_set(values)
    local result = {}
    for _, value in ipairs(values or {}) do
        value = tonumber(value)
        if value and value >= 1 and value <= 7 and value % 1 == 0 then
            result[value] = true
        end
    end
    return result
end

function M.normalize(input)
    input = input or {}
    local kind = input.kind or input.recurrence_type or "once"
    if not M.kinds[kind] then
        return nil, "invalid_kind"
    end
    local every = tonumber(input.every or input.recurrence_every or 1)
    if not every or every < 1 or every % 1 ~= 0 then
        return nil, "invalid_every"
    end
    local unit = input.unit or input.recurrence_unit
    if kind == "interval" and not M.units[unit] then
        return nil, "invalid_unit"
    end
    local weekdays = {}
    for value in pairs(weekday_set(input.weekdays)) do
        weekdays[#weekdays + 1] = value
    end
    table.sort(weekdays)
    if kind == "weekly" and #weekdays == 0 then
        return nil, "weekdays_required"
    end
    return { kind = kind, every = every, unit = unit, weekdays = weekdays }
end

function M.next_after(rule, scheduled_at, now)
    rule = assert(M.normalize(rule))
    scheduled_at = assert(tonumber(scheduled_at), "scheduled_at is required")
    now = now or os.time()
    if rule.kind == "once" then
        return nil
    elseif rule.kind == "interval" then
        if rule.unit == "days" then
            local next_at = scheduled_at
            repeat
                next_at = calendar_days(next_at, rule.every)
            until next_at > now
            return next_at
        end
        local step = rule.every * M.units[rule.unit]
        return scheduled_at + (math.floor(math.max(0, now - scheduled_at) / step) + 1) * step
    elseif rule.kind == "daily" then
        local next_at = scheduled_at
        repeat
            next_at = calendar_days(next_at, rule.every)
        until next_at > now
        return next_at
    end

    local allowed = rule.kind == "weekdays" and { [2] = true, [3] = true, [4] = true, [5] = true, [6] = true }
        or weekday_set(rule.weekdays)
    local next_at = scheduled_at
    repeat
        next_at = calendar_days(next_at, 1)
    until next_at > now and allowed[os.date("*t", next_at).wday]
    return next_at
end

function M.label(rule)
    rule = assert(M.normalize(rule))
    local i18n = require("todo.i18n")
    if rule.kind == "interval" then
        return i18n.t("recurrence_every", rule.every, i18n.t("unit_" .. rule.unit))
    elseif rule.kind == "weekly" then
        local days = {}
        for _, weekday in ipairs(rule.weekdays) do
            days[#days + 1] = i18n.t("weekday_" .. weekday)
        end
        return i18n.t("recurrence_selected_days", table.concat(days, ","))
    end
    return i18n.t("recurrence_" .. rule.kind)
end

return M
