-- Shared visual semantics for task cards. Panel and daily views both use this
-- module so a task looks the same in every list.
local M = {}

local priority_groups = {
    [0] = "TodoPriorityBadge0",
    [1] = "TodoPriorityBadge1",
    [2] = "TodoPriorityBadge2",
    [3] = "TodoPriorityBadge3",
}

local urgency_groups = {
    overdue = "TodoBarOverdue",
    urgent = "TodoBarUrgent",
    high = "TodoBarHigh",
    attention = "TodoBarAttention",
    priority_only = "TodoBarNone",
}

local due_groups = {
    overdue = "TodoDueOverdue",
    urgent = "TodoDueToday",
    high = "TodoDueSoon",
    attention = "TodoDueLater",
    priority_only = "TodoDueNone",
}

function M.done(task)
    return task.status == "done" or task.status == "cancelled"
end

function M.priority_group(task)
    if M.done(task) then
        return "TodoMuted"
    end
    return priority_groups[tonumber(task.priority)] or "TodoPriorityBadge3"
end

function M.urgency(task)
    task.urgency = task.urgency or require("todo.urgency").calculate(task)
    return task.urgency
end

function M.right_group(task)
    if M.done(task) then
        return nil
    end
    return urgency_groups[M.urgency(task).level] or "TodoBarNone"
end

function M.due_group(task)
    if M.done(task) then
        return "TodoMuted"
    end
    return due_groups[M.urgency(task).level] or "TodoDueNone"
end

function M.left_group(task, plan_state)
    if M.done(task) then
        return nil
    end
    if plan_state == "today" then
        return "TodoBarToday"
    elseif plan_state == "review" then
        return "TodoBarReview"
    end
    return "TodoBarActive"
end

function M.ai_group(selected)
    return selected and "TodoBarAI" or nil
end

--- Plan membership for a date, plus the union of AI selections from every
--- planning conversation for that date.
function M.marks(ws, svc, date, view)
    if not ws or not svc or not svc.store or not svc.store.db then
        return { today = {}, review = {}, ai = {}, date = date }
    end
    local planner = require("todo.planning").new(ws, svc)
    date = date or planner:date()
    local today = {}
    for _, item in ipairs(planner:today(date).items) do
        today[item.task_uuid] = true
    end
    local ai = {}
    for _, record in ipairs(ws:list("conversation")) do
        local value = record.value
        if value.scope == "daily_planning" and value.date == date then
            for _, entry in ipairs(value.queue or {}) do
                if entry.selected and not entry.missing then
                    ai[entry.uuid] = true
                end
            end
        end
    end
    local review = {}
    if view == "today" then
        for _, task in ipairs(svc:list("today")) do
            if task.planning and task.planning.group == "review" and not M.done(task) then
                review[task.sync_uuid] = true
            end
        end
    end
    return { today = today, review = review, ai = ai, date = date }
end

function M.plan_state(task, marks)
    if not marks then
        return nil
    end
    if marks.review[task.sync_uuid] then
        return "review"
    elseif marks.today[task.sync_uuid] then
        return "today"
    end
end

return M
