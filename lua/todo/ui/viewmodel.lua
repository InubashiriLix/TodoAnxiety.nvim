local i18n = require("todo.i18n")

local M = {}

function M.truncate(text, width)
  text = tostring(text or "")
  if width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  if width == 1 then
    return "…"
  end
  local chars = vim.fn.strchars(text)
  local low, high, best = 0, chars, ""
  while low <= high do
    local mid = math.floor((low + high) / 2)
    local candidate = vim.fn.strcharpart(text, 0, mid)
    if vim.fn.strdisplaywidth(candidate) <= width - 1 then
      best, low = candidate, mid + 1
    else
      high = mid - 1
    end
  end
  return best .. "…"
end

function M.sections(tasks, view)
  if view ~= "active" then
    return { { key = view, label = i18n.t(view), tasks = tasks } }
  end
  local order = { "in_progress", "todo", "done", "cancelled" }
  local buckets = {}
  for _, status in ipairs(order) do
    buckets[status] = {}
  end
  for _, task in ipairs(tasks) do
    local bucket = buckets[task.status]
    if bucket then
      bucket[#bucket + 1] = task
    end
  end
  local sections = {}
  for _, status in ipairs(order) do
    if #buckets[status] > 0 then
      sections[#sections + 1] = {
        key = status,
        label = i18n.t(status),
        tasks = buckets[status],
      }
    end
  end
  return sections
end

function M.card(task, width, reason)
  local status_icons = { todo = "○", in_progress = "▶", done = "✓", cancelled = "×" }
  local prefix = string.format("%s P%d  ", status_icons[task.status] or "?", task.priority)
  local title = M.truncate(task.title, math.max(1, width - vim.fn.strdisplaywidth(prefix)))
  local metadata = {}
  if task.due_date then
    metadata[#metadata + 1] = "⏱ " .. task.due_date .. (task.due_time and (" " .. task.due_time) or "")
  end
  if reason and reason ~= "" then
    metadata[#metadata + 1] = reason
  end
  for _, tag in ipairs(task.tags or {}) do
    metadata[#metadata + 1] = "#" .. tag
  end

  local indent = "     "
  local available = math.max(1, width - vim.fn.strdisplaywidth(indent))
  local visible, hidden, used = {}, 0, 0
  for index, item in ipairs(metadata) do
    local separator = #visible > 0 and " · " or ""
    local item_width = vim.fn.strdisplaywidth(separator .. item)
    local reserve = index < #metadata and 4 or 0
    if used + item_width + reserve <= available then
      visible[#visible + 1] = item
      used = used + item_width
    else
      hidden = hidden + 1
    end
  end
  local line2 = table.concat(visible, " · ")
  if hidden > 0 then
    local suffix = "+" .. hidden
    line2 = M.truncate(line2, math.max(0, available - vim.fn.strdisplaywidth(suffix) - 1))
    line2 = (line2 ~= "" and (line2 .. " ") or "") .. suffix
  end
  return prefix .. title, indent .. line2
end

return M
