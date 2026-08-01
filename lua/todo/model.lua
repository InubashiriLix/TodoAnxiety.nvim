local M = {}

M.statuses = { todo = true, in_progress = true, done = true, cancelled = true }

local function trim(value)
  return (value or ""):match("^%s*(.-)%s*$")
end

function M.normalize_priority(value)
  if type(value) == "string" then
    value = tonumber(value:upper():match("^P([0-3])$"))
  end
  if type(value) ~= "number" or value < 0 or value > 3 or value % 1 ~= 0 then
    return nil
  end
  return value
end

function M.normalize_tags(tags)
  if type(tags) == "string" then
    tags = vim.split(tags, ",", { plain = true })
  end
  local result, seen = {}, {}
  for _, tag in ipairs(tags or {}) do
    local clean = trim(tag)
    local key = clean:lower()
    if clean ~= "" and not seen[key] then
      seen[key] = true
      result[#result + 1] = clean
    end
  end
  table.sort(result, function(a, b)
    return a:lower() < b:lower()
  end)
  return result
end

function M.parse_deadline(value)
  value = trim(value)
  if value == "" then
    return nil, nil
  end
  local year, month, day, hour, min = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)%s+(%d%d):(%d%d)$")
  local has_time = true
  if not year then
    year, month, day = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    hour, min, has_time = "23", "59", false
  end
  if not year then
    return nil, "invalid"
  end
  local parts = {
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(min),
    sec = has_time and 0 or 59,
    isdst = nil,
  }
  if parts.month < 1 or parts.month > 12 or parts.day < 1 or parts.day > 31 or parts.hour > 23 or parts.min > 59 then
    return nil, "invalid"
  end
  local epoch = os.time(parts)
  local normalized = os.date("*t", epoch)
  if
    normalized.year ~= parts.year
    or normalized.month ~= parts.month
    or normalized.day ~= parts.day
    or normalized.hour ~= parts.hour
    or normalized.min ~= parts.min
  then
    return nil, "invalid"
  end
  return {
    date = string.format("%04d-%02d-%02d", parts.year, parts.month, parts.day),
    time = has_time and string.format("%02d:%02d", parts.hour, parts.min) or nil,
    epoch = epoch,
  }
end

function M.deadline_text(task)
  if not task.due_date then
    return ""
  end
  return task.due_date .. (task.due_time and (" " .. task.due_time) or "")
end

function M.validate(input)
  local errors = {}
  local title = trim(input.title)
  if title == "" then
    errors.title = "required"
  end
  local priority = M.normalize_priority(input.priority == nil and 2 or input.priority)
  if priority == nil then
    errors.priority = "invalid"
  end
  local status = input.status or "todo"
  if not M.statuses[status] then
    errors.status = "invalid"
  end
  local deadline, deadline_error = M.parse_deadline(input.deadline or M.deadline_text(input))
  if deadline_error then
    errors.deadline = deadline_error
  end
  if next(errors) then
    return nil, errors
  end
  return {
    title = title,
    description = input.description or "",
    status = status,
    priority = priority,
    due_date = deadline and deadline.date or nil,
    due_time = deadline and deadline.time or nil,
    tags = M.normalize_tags(input.tags),
  }
end

return M
