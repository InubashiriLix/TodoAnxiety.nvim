local M = {}
local core = require("todo.core")

function M.parse(value)
    return core.request("core.duration_parse", { value })
end

function M.format(seconds)
    seconds = tonumber(seconds)
    if not seconds or seconds < 1 then
        return ""
    end
    if seconds % 1 ~= 0 then
        return ""
    end
    local parts = {}
    for _, item in ipairs({ { "d", 86400 }, { "h", 3600 }, { "m", 60 }, { "s", 1 } }) do
        local amount = math.floor(seconds / item[2])
        if amount > 0 then
            parts[#parts + 1] = tostring(amount) .. item[1]
            seconds = seconds % item[2]
        end
    end
    return table.concat(parts)
end

function M.trigger(value, now)
    local seconds = M.parse(value)
    return seconds and ((now or os.time()) + seconds) or nil
end

return M
