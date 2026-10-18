local core = require("todo.core")
local M = {}

M.kinds = { once = true, daily = true, weekdays = true, weekly = true, interval = true }
M.units = { minutes = 60, hours = 3600, days = 86400 }

function M.normalize(input)
    local ok, value = pcall(core.request, "core.recurrence_normalize", { input or {} })
    if not ok then
        local message = tostring(value)
        return nil, message:match("todo%-core: ([%w_]+)") or message
    end
    return value
end

function M.next_after(rule, scheduled_at, now)
    scheduled_at = assert(tonumber(scheduled_at), "scheduled_at is required")
    now = now or os.time()
    local value = core.request("core.recurrence_next", { rule, scheduled_at, now })
    return value
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
