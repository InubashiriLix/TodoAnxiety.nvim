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

function M.sections(tasks, view, now)
    return require("todo.ui.grouping").sections(tasks, view, now)
end

function M.card(task, width, reason, opts)
    if task.kind == "notice" then
        local prefix = "󰀠  "
        local title = M.truncate(task.title, math.max(1, width - vim.fn.strdisplaywidth(prefix)))
        local metadata = {}
        if task.reminder then
            metadata[#metadata + 1] = os.date("%Y-%m-%d %H:%M", task.reminder.next_reminder_at)
            metadata[#metadata + 1] = require("todo.duration").format(task.reminder.repeat_interval_seconds)
            metadata[#metadata + 1] = require("todo.recurrence").label(task.reminder.recurrence)
        end
        for _, tag in ipairs(task.tags or {}) do
            metadata[#metadata + 1] = "#" .. tag
        end
        return prefix .. title, "    " .. M.truncate(table.concat(metadata, " · "), math.max(1, width - 4))
    end
    local status_icons = { todo = "○", in_progress = "▶", done = "✓", cancelled = "×" }
    local prefix = string.format("%s P%d  ", status_icons[task.status] or "?", task.priority)
    local title = M.truncate(task.title, math.max(1, width - vim.fn.strdisplaywidth(prefix)))
    local metadata = {}
    if (opts or {}).relative then
        local label =
            require("todo.ui.grouping").relative((task.urgency or require("todo.urgency").calculate(task)).due_epoch)
        if label then
            metadata[#metadata + 1] = "⏳ " .. label
        end
    end
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
