local config = require("todo.config")
local urgency = require("todo.urgency")
local M = {}
local definitions = {
    edit = { "e", "Edit", "编辑" },
    start = { "s", "Start / resume in progress", "开始／恢复进行中" },
    done = { "x", "Complete", "完成" },
    cancel = { "c", "Cancel task", "取消任务" },
    reopen = { "u", "Return to Todo", "恢复待办" },
    archive = { "A", "Archive", "归档" },
    restore = { "R", "Restore from archive", "恢复归档" },
    delete = { "D", "Permanently delete…", "永久删除…" },
    postpone = { "p", "Postpone… (default 1d)", "延期…（默认1d）" },
}
function M.task_actions(task, now)
    if not task then
        return {}
    end
    local ids
    if task.archived_at then
        ids = { "edit", "restore", "delete" }
    elseif task.kind == "notice" then
        ids = (task.status == "todo" or task.status == "in_progress") and { "edit", "done", "archive" }
            or { "edit", "archive" }
    elseif task.status == "todo" then
        ids = { "edit", "start", "done", "cancel", "archive" }
    elseif task.status == "in_progress" then
        ids = { "edit", "reopen", "done", "cancel", "archive" }
    else
        ids = { "edit", "start", "reopen", "archive" }
    end
    if
        not task.archived_at
        and task.kind ~= "notice"
        and (task.status == "todo" or task.status == "in_progress")
        and urgency.calculate(task, now).level == "overdue"
    then
        table.insert(ids, 2, "postpone")
    end
    local zh = config.get().language == "zh-CN"
    local result = {}
    for _, id in ipairs(ids) do
        local d = definitions[id]
        local label = d[zh and 3 or 2]
        local key = d[1]
        if id == "start" then
            label = zh and (task.status == "todo" and "开始" or "恢复进行中") or "Start"
        end
        if id == "reopen" then
            key = task.status == "in_progress" and "s" or "x"
            label = zh and "恢复待办" or "Reopen"
        end
        if id == "restore" then
            key = "A"
            label = zh and "恢复归档" or "Restore"
        end
        if id == "postpone" then
            label = zh and "延期" or "Postpone"
        end
        if id == "done" and task.kind == "notice" then
            label = zh and "完成本轮" or "Complete occurrence"
        end
        result[#result + 1] = {
            id = id,
            key = key,
            label = label,
            group = zh and "当前任务" or "Current task",
            modes = { "n" },
        }
    end
    return result
end
function M.for_key(task, key)
    for _, action in ipairs(M.task_actions(task)) do
        if action.key == key then
            return action
        end
    end
end
function M.allowed(task, id, now)
    for _, action in ipairs(M.task_actions(task, now)) do
        if action.id == id then
            return true
        end
    end
    return false
end
return M
