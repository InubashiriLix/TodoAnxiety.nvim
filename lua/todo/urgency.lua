local core = require("todo.core")
local M = {}

local function cache_key(task, now)
    return table.concat({
        task.sync_uuid or task.id or "",
        task.due_date or "",
        task.due_time or "",
        tostring(task.priority or ""),
        task.status or "",
        tostring(task.archived_at or ""),
        tostring(math.floor(now / 30)),
    }, "\0")
end

function M.calculate(task, now)
    now = now or os.time()
    local key = cache_key(task, now)
    if task._urgency_key == key then
        return task._urgency
    end
    local value = core.request("core.urgency", { task, now })
    task._urgency, task._urgency_key = value, key
    return value
end

function M.is_candidate(task)
    return not task.archived_at
        and (task.status == "todo" or task.status == "in_progress")
        and (task.due_date ~= nil or tonumber(task.priority) <= 1)
end

--- Decorate and sort every task by urgency without filtering out non-candidates.
function M.rank(tasks, now)
    now = now or os.time()
    local missing = {}
    for _, task in ipairs(tasks) do
        if task._urgency_key ~= cache_key(task, now) then
            missing[#missing + 1] = task
        end
    end
    if #missing > 0 then
        local values = core.request("core.urgency_batch", { missing, now })
        assert(type(values) == "table" and #values == #missing, "todo-core returned an invalid urgency batch")
        for index, task in ipairs(missing) do
            task._urgency, task._urgency_key = values[index], cache_key(task, now)
        end
    end
    local decorated = {}
    for _, task in ipairs(tasks) do
        local urgency = task._urgency
        task.urgency = urgency
        decorated[#decorated + 1] = { task = task, urgency = urgency }
    end
    table.sort(decorated, function(a, b)
        if a.urgency.score ~= b.urgency.score then
            return a.urgency.score > b.urgency.score
        end
        if (a.urgency.due_epoch ~= nil) ~= (b.urgency.due_epoch ~= nil) then
            return a.urgency.due_epoch ~= nil
        end
        if a.urgency.due_epoch and a.urgency.due_epoch ~= b.urgency.due_epoch then
            return a.urgency.due_epoch < b.urgency.due_epoch
        end
        if tonumber(a.task.priority) ~= tonumber(b.task.priority) then
            return tonumber(a.task.priority) < tonumber(b.task.priority)
        end
        return tonumber(a.task.created_at) < tonumber(b.task.created_at)
    end)
    local result = {}
    for _, item in ipairs(decorated) do
        result[#result + 1] = item.task
    end
    return result
end

function M.sort(tasks, now)
    return M.rank(vim.tbl_filter(M.is_candidate, tasks), now)
end

return M
