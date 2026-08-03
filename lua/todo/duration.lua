local M = {}

local units = { s = 1, m = 60, h = 3600, d = 86400 }

function M.parse(value)
    if type(value) == "number" then
        return value > 0 and value % 1 == 0 and value or nil
    end
    local compact = vim.trim(value or ""):lower():gsub("%s+", "")
    if compact == "" then
        return nil
    end
    local total, rebuilt = 0, ""
    for amount, unit in compact:gmatch("(%d+)([smhd])") do
        rebuilt = rebuilt .. amount .. unit
        total = total + tonumber(amount) * units[unit]
    end
    return rebuilt == compact and total > 0 and total or nil
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
