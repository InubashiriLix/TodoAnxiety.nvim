local model = require("todo.model")
local urgency = require("todo.urgency")

local M = {}
M.__index = M

function M.new(store)
  return setmetatable({ store = store }, M)
end

function M:create(input)
  local task, errors = model.validate(input)
  if not task then
    return nil, errors
  end
  return self.store:create(task)
end

function M:update(id, input)
  if not self.store:get(id) then
    return nil, { id = "not_found" }
  end
  local task, errors = model.validate(input)
  if not task then
    return nil, errors
  end
  return self.store:update(id, task)
end

function M:set_status(id, status)
  if not model.statuses[status] then
    return nil, { status = "invalid" }
  end
  if not self.store:get(id) then
    return nil, { id = "not_found" }
  end
  return self.store:set_status(id, status)
end

function M:archive(id)
  if not self.store:get(id) then
    return nil, { id = "not_found" }
  end
  return self.store:archive(id)
end

function M:restore(id)
  if not self.store:get(id) then
    return nil, { id = "not_found" }
  end
  return self.store:restore(id)
end

local function matches(task, filters)
  if filters.status and filters.status ~= "all" and task.status ~= filters.status then
    return false
  end
  if filters.priority and filters.priority ~= "all" and task.priority ~= tonumber(filters.priority:match("%d")) then
    return false
  end
  if filters.tag and filters.tag ~= "" then
    local found = false
    for _, tag in ipairs(task.tags) do
      if tag:lower() == filters.tag:lower() then
        found = true
        break
      end
    end
    if not found then
      return false
    end
  end
  if filters.search and filters.search ~= "" then
    local needle = filters.search:lower()
    local haystack = (task.title .. "\n" .. task.description):lower()
    if not haystack:find(needle, 1, true) then
      return false
    end
  end
  return true
end

function M:list(view, filters, now)
  local tasks = self.store:list({ archived = view == "archived" })
  if view == "emergency" then
    tasks = urgency.sort(tasks, now)
  else
    table.sort(tasks, function(a, b)
      if a.status ~= b.status then
        local rank = { in_progress = 1, todo = 2, done = 3, cancelled = 4 }
        return rank[a.status] < rank[b.status]
      end
      if a.priority ~= b.priority then
        return a.priority < b.priority
      end
      return a.created_at < b.created_at
    end)
  end
  local result = {}
  for _, task in ipairs(tasks) do
    if matches(task, filters or {}) then
      result[#result + 1] = task
    end
  end
  return result
end

return M
