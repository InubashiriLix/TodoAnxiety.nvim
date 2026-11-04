-- User-facing note editor shared by the dashboard and the task form. Notes are
-- separate workspace records, including the ones proposed by AI, so they need
-- their own picker instead of being folded into the description buffer.
local i18n = require("todo.i18n")
local codec = require("todo.sync.codec")

local M = {}

local function preview(text)
    for line in tostring(text or ""):gmatch("[^\r\n]+") do
        line = vim.trim(line)
        if line ~= "" then
            return line:sub(1, 70)
        end
    end
    return i18n.t("new_note")
end

--- Notes attached to a task. Pass a workspace to reuse an open transaction
--- owner; otherwise the current service supplies one.
function M.records(task, opts)
    if not task or not task.sync_uuid then
        return {}
    end
    opts = opts or {}
    local svc = opts.service or require("todo")._service()
    local ws = opts.workspace or require("todo.workspace").new(svc.store)
    local result = {}
    for _, r in ipairs(ws:list("note")) do
        if r.value.task_uuid == task.sync_uuid then
            result[#result + 1] = r
        end
    end
    table.sort(result, function(a, b)
        return (a.value.created_at or 0) < (b.value.created_at or 0)
    end)
    return result
end

--- Pick a note (or a new one) and open the Markdown editor. Editing an existing
--- record keeps its source label; clearing the text deletes it. `opts.editor`
--- exists for tests and callers that already own an editor.
function M.edit(task, opts)
    opts = opts or {}
    if not task or not task.sync_uuid then
        vim.notify(i18n.t("save_before_notes"), vim.log.levels.WARN)
        return
    end
    local svc = opts.service or require("todo")._service()
    local ws = opts.workspace or require("todo.workspace").new(svc.store)
    local planner = opts.planner or require("todo.planning").new(ws, svc)
    local editor = opts.editor or require("todo.ui.planner").editor
    local records = opts.records or M.records(task, { service = svc, workspace = ws })

    local choices = { { label = i18n.t("new_note") } }
    for _, r in ipairs(records) do
        choices[#choices + 1] = {
            label = "[" .. tostring(r.value.source or "user") .. "] " .. preview(r.value.text),
            record = r,
        }
    end
    vim.ui.select(choices, {
        prompt = i18n.t("task_notes"),
        format_item = function(choice)
            return choice.label
        end,
    }, function(choice)
        if not choice then
            return
        end
        local r = choice.record
        local source = r and r.value.source or "user"
        editor(
            r and (i18n.t("task_note") .. " · " .. tostring(source)) or i18n.t("new_note"),
            r and r.value.text or "",
            function(value)
                local blank = vim.trim(value) == ""
                planner:transaction(i18n.t("task_note"), function()
                    if r and blank then
                        ws:put("note", r.key, nil, r.revision)
                    elseif not blank then
                        ws:put("note", r and r.key or codec.uuid(), {
                            task_uuid = task.sync_uuid,
                            text = value,
                            source = source,
                            created_at = r and r.value.created_at or os.time(),
                        }, r and r.revision)
                    end
                end)
                if opts.on_change then
                    opts.on_change()
                end
                return true
            end,
            svc.store
        )
    end)
end

return M
