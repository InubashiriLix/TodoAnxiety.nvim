local model = require("todo.model")
local M = {}

local priority_bonus = { [0] = 30, [1] = 20, [2] = 10, [3] = 0 }

local function due_epoch(task)
  local parsed = model.parse_deadline(model.deadline_text(task))
  return parsed and parsed.epoch or nil
end

function M.calculate(task, now)
  now = now or os.time()
  local due = due_epoch(task)
  local remaining = due and (due - now) or nil
  local base, reason
  if remaining and remaining < 0 then
    base, reason = 120, "overdue"
  elseif remaining and remaining <= 86400 then
    base, reason = 80, "due_today"
  elseif remaining and remaining <= 3 * 86400 then
    base, reason = 60, "due_in_days"
  elseif remaining and remaining <= 7 * 86400 then
    base, reason = 40, "due_in_days"
  elseif remaining then
    base, reason = 20, "due_later"
  else
    base, reason = 0, "no_deadline"
  end
  local score = base + (priority_bonus[tonumber(task.priority)] or 0)
  local level
  if reason == "overdue" then
    level = "overdue"
  elseif not due then
    level = "priority_only"
  elseif score >= 80 then
    level = "urgent"
  elseif score >= 60 then
    level = "high"
  else
    level = "attention"
  end
  return {
    score = score,
    level = level,
    reason = reason,
    due_epoch = due,
    days = remaining and math.max(0, math.ceil(remaining / 86400)) or nil,
  }
end

function M.is_candidate(task)
  return not task.archived_at
    and (task.status == "todo" or task.status == "in_progress")
    and (task.due_date ~= nil or tonumber(task.priority) <= 1)
end

function M.sort(tasks, now)
  local decorated = {}
  for _, task in ipairs(tasks) do
    if M.is_candidate(task) then
      decorated[#decorated + 1] = { task = task, urgency = M.calculate(task, now) }
    end
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
    item.task.urgency = item.urgency
    result[#result + 1] = item.task
  end
  return result
end

return M
