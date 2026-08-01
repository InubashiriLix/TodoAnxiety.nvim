local model = require("todo.model")

local M = {}
M.__index = M

local function snapshot(fields)
  return {
    title = fields.title or "",
    priority = fields.priority or "P2",
    status = fields.status or "todo",
    deadline = fields.deadline or "",
    description = fields.description or "",
    tags = vim.deepcopy(fields.tags or {}),
  }
end

function M.new(task)
  task = task or {}
  local fields = {
    title = task.title or "",
    priority = "P" .. tostring(task.priority == nil and 2 or task.priority),
    status = task.status or "todo",
    deadline = model.deadline_text(task),
    description = task.description or "",
    tags = model.normalize_tags(task.tags),
  }
  return setmetatable({ fields = fields, initial = snapshot(fields), errors = {} }, M)
end

function M:get(name)
  return self.fields[name]
end

function M:set(name, value)
  self.fields[name] = value
  self.errors[name] = nil
end

function M:add_tag(value)
  local tags = vim.deepcopy(self.fields.tags)
  tags[#tags + 1] = value
  self.fields.tags = model.normalize_tags(tags)
  return self.fields.tags
end

function M:remove_last_tag()
  if #self.fields.tags > 0 then
    table.remove(self.fields.tags)
  end
  return self.fields.tags
end

function M:remove_tag(index)
  table.remove(self.fields.tags, index)
  return self.fields.tags
end

function M:set_deadline_preset(preset, now)
  if preset == "clear" then
    self:set("deadline", "")
    return ""
  end
  local offsets = { today = 0, tomorrow = 1, three_days = 3, next_week = 7 }
  local offset = assert(offsets[preset], "unknown deadline preset: " .. tostring(preset))
  local base = os.date("*t", now or os.time())
  base.day = base.day + offset
  base.hour, base.min, base.sec = 12, 0, 0
  local value = os.date("%Y-%m-%d", os.time(base))
  self:set("deadline", value)
  return value
end

function M:input()
  return {
    title = self.fields.title,
    priority = self.fields.priority,
    status = self.fields.status,
    deadline = self.fields.deadline,
    description = self.fields.description,
    tags = vim.deepcopy(self.fields.tags),
  }
end

function M:validate()
  local normalized, errors = model.validate(self:input())
  self.errors = errors or {}
  return normalized, self.errors
end

function M:is_dirty()
  return not vim.deep_equal(snapshot(self.fields), self.initial)
end

function M:mark_saved()
  self.initial = snapshot(self.fields)
  self.errors = {}
end

return M
