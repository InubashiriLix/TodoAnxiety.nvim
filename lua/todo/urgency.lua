local core = require("todo.core")
local M = {}

function M.calculate(task, now)
    return core.request("core.urgency", { task, now or os.time() })
end

function M.is_candidate(task)
    return not task.archived_at
        and (task.status == "todo" or task.status == "in_progress")
        and (task.due_date ~= nil or tonumber(task.priority) <= 1)
end

--- Decorate and sort every task by urgency without filtering out non-candidates.
function M.rank(tasks, now)
    now = now or os.time()
    local values = core.request("core.urgency_batch", { tasks, now })
    assert(type(values) == "table" and #values == #tasks, "todo-core returned an invalid urgency batch")
    local decorated = {}
    for index, task in ipairs(tasks) do
        local urgency = values[index]
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
