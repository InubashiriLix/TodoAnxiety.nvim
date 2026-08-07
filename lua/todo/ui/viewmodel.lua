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

-- A half-filled circle rather than a triangle: folding uses ▾/▸, so a task
-- status icon shaped like a triangle reads as another fold arrow.
local status_icons = { todo = "○", in_progress = "◐", done = "✓", cancelled = "×" }

-- Fixed widths so the urgency badge and due/relative column line up under
-- each other across every card; scanning becomes a column comparison
-- instead of parsing a new sentence per task.
local URGENCY_COL = 13
local DUE_COL = 18

--- Right-pad (or truncate) to an exact display width so columns line up.
local function pad(text, width)
    text = tostring(text or "")
    if vim.fn.strdisplaywidth(text) >= width then
        return M.truncate(text, width)
    end
    return text .. string.rep(" ", width - vim.fn.strdisplaywidth(text))
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

    opts = opts or {}
    local icon = status_icons[task.status] or "?"
    local badge = string.format("[P%d]", task.priority)
    local prefix = icon .. " " .. badge .. " "
    local prefix_width = vim.fn.strdisplaywidth(prefix)
    local title = M.truncate(task.title, math.max(1, width - prefix_width))
    local line1 = prefix .. title

    local due_text
    if opts.relative then
        local label = require("todo.ui.grouping").relative(
            (task.urgency or require("todo.urgency").calculate(task)).due_epoch
        )
        due_text = label or "—"
    elseif task.due_date then
        due_text = task.due_date .. (task.due_time and (" " .. task.due_time) or "")
    else
        due_text = "—"
    end

    local tag_items = {}
    for _, name in ipairs(task.tags or {}) do
        tag_items[#tag_items + 1] = "#" .. name
    end

    local indent = string.rep(" ", prefix_width)
    local columns_width = URGENCY_COL + 1 + DUE_COL + 1
    local available = math.max(1, width - prefix_width - columns_width)
    local visible, hidden, used = {}, 0, 0
    for index, item in ipairs(tag_items) do
        local separator = #visible > 0 and " " or ""
        local item_width = vim.fn.strdisplaywidth(separator .. item)
        local reserve = index < #tag_items and 4 or 0
        if used + item_width + reserve <= available then
            visible[#visible + 1] = item
            used = used + item_width
        else
            hidden = hidden + 1
        end
    end
    local tags_text = table.concat(visible, " ")
    if hidden > 0 then
        local suffix = "+" .. hidden
        tags_text = M.truncate(tags_text, math.max(0, available - vim.fn.strdisplaywidth(suffix) - 1))
        tags_text = (tags_text ~= "" and (tags_text .. " ") or "") .. suffix
    end

    local urgency_cell = pad(reason and reason ~= "" and reason or "—", URGENCY_COL)
    local due_cell = pad(due_text, DUE_COL)
    local line2 = indent .. urgency_cell .. " " .. due_cell .. " " .. tags_text
    -- Narrow windows (sidebar) can't fit both fixed columns; truncate rather
    -- than overflow the window width.
    line2 = M.truncate(line2, width)
    return line1, line2
end

return M
