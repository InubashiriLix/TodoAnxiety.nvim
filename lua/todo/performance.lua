-- Opt-in, bounded, in-memory timings. Never collect task text or credentials.
local M = { samples = {}, counters = {} }
function M.enabled()
    return require("todo.config").get().ui.performance == true
end
function M.start()
    if M.enabled() then
        return (vim.uv or vim.loop).hrtime()
    end
end
function M.finish(name, started)
    if not started then
        return
    end
    local rows = M.samples[name] or {}
    rows[#rows + 1] = ((vim.uv or vim.loop).hrtime() - started) / 1e6
    if #rows > 200 then
        table.remove(rows, 1)
    end
    M.samples[name] = rows
end
function M.count(name)
    if M.enabled() then
        M.counters[name] = (M.counters[name] or 0) + 1
    end
end
function M.lines()
    local lines = { "", "UI performance (ui.performance = true)", "" }
    for _, name in ipairs(vim.tbl_keys(M.samples)) do
        local values = vim.deepcopy(M.samples[name])
        table.sort(values)
        lines[#lines + 1] = string.format(
            "%s  n=%d  p50=%.2fms  p95=%.2fms  max=%.2fms",
            name,
            #values,
            values[math.ceil(#values * 0.5)],
            values[math.ceil(#values * 0.95)],
            values[#values]
        )
    end
    for _, name in ipairs(vim.tbl_keys(M.counters)) do
        lines[#lines + 1] = name .. ": " .. M.counters[name]
    end
    return lines
end
return M
