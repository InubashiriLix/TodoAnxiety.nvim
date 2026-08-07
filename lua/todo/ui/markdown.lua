local i18n = require("todo.i18n")
local urgency = require("todo.urgency")

local M = {}

local function field(label, value)
    return string.format("**%s** %s", label, value ~= nil and value ~= "" and value or "—")
end

--- Join field cells onto one list item so the block reads as a compact table.
local function item(...)
    return "- " .. table.concat({ ... }, "  ·  ")
end

local function deadline_text(task)
    if not task.due_date then
        return nil
    end
    return task.due_date .. (task.due_time and (" " .. task.due_time) or "")
end

local function tag_text(task)
    local tags = {}
    for _, tag in ipairs(task.tags or {}) do
        tags[#tags + 1] = "`#" .. tag .. "`"
    end
    return #tags > 0 and table.concat(tags, " ") or nil
end

local function notice_fields(task, lines)
    local reminder = task.reminder
    lines[#lines + 1] = item(
        field(i18n.t("trigger"), reminder and os.date("%Y-%m-%d %H:%M:%S", reminder.scheduled_at) or nil),
        field(
            i18n.t("reminder_interval"),
            reminder and require("todo.duration").format(reminder.repeat_interval_seconds) or nil
        )
    )
    lines[#lines + 1] = item(
        field(i18n.t("recurrence"), reminder and require("todo.recurrence").label(reminder.recurrence) or nil),
        field(i18n.t("tags"), tag_text(task))
    )
end

local function task_fields(task, lines)
    lines[#lines + 1] = item(
        field(i18n.t("status"), i18n.t(task.status)),
        field(i18n.t("priority"), string.format("P%d", task.priority))
    )
    -- The urgency band rides along with the deadline it was derived from.
    local info = urgency.is_candidate(task) and (task.urgency or urgency.calculate(task)) or nil
    local deadline = field(i18n.t("deadline"), deadline_text(task))
    lines[#lines + 1] = info and item(deadline, "`" .. i18n.t(info.level) .. "`") or item(deadline)
    lines[#lines + 1] = item(field(i18n.t("tags"), tag_text(task)))
end

--- Render a task as markdown source lines. The description is emitted verbatim
--- so any markdown the user typed into the form keeps working here.
function M.task_lines(task, opts)
    if not task then
        return { "", "> " .. i18n.t("no_tasks") }
    end
    opts = opts or {}
    local lines = { "# " .. task.title, "" }
    if task.kind == "notice" then
        notice_fields(task, lines)
    else
        task_fields(task, lines)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "---"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## " .. i18n.t("description")
    lines[#lines + 1] = ""
    if task.description ~= nil and task.description ~= "" then
        vim.list_extend(lines, vim.split(task.description, "\n", { plain = true }))
    else
        lines[#lines + 1] = "*" .. i18n.t("no_description") .. "*"
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "---"
    lines[#lines + 1] = string.format(
        "*%s %s · %s %s*",
        i18n.t("created"),
        os.date("%Y-%m-%d %H:%M", task.created_at),
        i18n.t("updated"),
        os.date("%Y-%m-%d %H:%M", task.updated_at)
    )
    if opts.actions ~= false then
        lines[#lines + 1] = ""
        -- A quote block rather than [ e Edit ]: brackets would parse as a link.
        lines[#lines + 1] = string.format(
            "> `e` %s · `s` %s · `x` %s",
            i18n.t("action_edit"),
            i18n.t("in_progress"),
            i18n.t("done")
        )
    end
    return lines
end

--- Turn a buffer into markdown: the filetype lets external renderers such as
--- render-markdown.nvim attach, and treesitter covers highlighting on its own.
--- Silently does nothing when disabled or when the parser is unavailable.
function M.attach(bufnr)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        return false
    end
    if not require("todo.config").get().ui.markdown then
        return false
    end
    if vim.b[bufnr].todo_markdown then
        return true
    end
    vim.b[bufnr].todo_markdown = true
    vim.bo[bufnr].filetype = "markdown"
    pcall(vim.treesitter.start, bufnr, "markdown")
    return true
end

--- Window options every markdown surface needs. `editing` keeps the cursor line
--- unconcealed so typing does not shift characters around.
function M.win_options(editing)
    return { conceallevel = 2, concealcursor = editing and "" or "nc" }
end

return M
