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

function M:delete_archived(id)
  local task = self.store:get(id)
  if not task then
    return nil, { id = "not_found" }
  end
  if not task.archived_at then
    return nil, { archived = "required" }
  end
  if not self.store.delete_archived then
    return nil, { delete = "unsupported" }
  end
  local deleted = self.store:delete_archived(id)
  return deleted, deleted and nil or { delete = "failed" }
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
  elseif view == "archived" then
    table.sort(tasks, function(a, b)
      if a.archived_at ~= b.archived_at then
        return a.archived_at > b.archived_at
      end
      return a.id > b.id
    end)
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

function M:list_tags()
  return self.store.list_tags and self.store:list_tags() or {}
end

local function normalize_tag_name(value)
  local tags = model.normalize_tags({ value })
  local name = tags[1]
  if not name or vim.fn.strchars(name) > 64 then
    return nil, { tag = "invalid" }
  end
  return name
end

function M:tag_stats()
  if self.store.tag_stats then
    return self.store:tag_stats()
  end
  return vim.tbl_map(function(name)
    return { name = name, task_count = 0 }
  end, self:list_tags())
end

function M:create_tag(value)
  local name, errors = normalize_tag_name(value)
  if not name then
    return nil, errors
  end
  return self.store.create_tag and self.store:create_tag(name) or name
end

function M:rename_tag(old_name, value)
  local name, errors = normalize_tag_name(value)
  if not name then
    return nil, errors
  end
  if not self.store.rename_tag then
    return nil, { tag = "unsupported" }
  end
  local renamed = self.store:rename_tag(old_name, name)
  return renamed, renamed and nil or { tag = "not_found" }
end

function M:delete_tag(name)
  if not self.store.delete_tag then
    return nil, { tag = "unsupported" }
  end
  local deleted = self.store:delete_tag(name)
  return deleted, deleted and nil or { tag = "not_found" }
end

function M:stats()
  if self.store.stats then
    return self.store:stats()
  end
  local active = self.store:list({ archived = false })
  local archived = self.store:list({ archived = true })
  return {
    active = #active,
    emergency = #urgency.sort(active),
    archived = #archived,
  }
end

return M
