local M = {}
local function L(en, zh)
    return require("todo.config").get().language == "zh-CN" and zh or en
end
local function service()
    local todo = package.loaded.todo
    if todo and type(todo._existing_service) == "function" then
        return todo._existing_service()
    end
    return todo and type(todo._service) == "function" and todo._service() or nil
end
function M.actions()
    local svc, result = service(), {}
    if svc and svc.can_undo and svc:can_undo() then
        result[#result + 1] = {
            key = "U",
            label = L("Undo last task operation", "撤回上次任务操作"),
            group = L("History", "操作历史"),
            modes = { "n" },
        }
    end
    if svc and svc.can_redo and svc:can_redo() then
        result[#result + 1] = {
            key = "Ctrl-r",
            label = L("Redo task operation", "重做任务操作"),
            group = L("History", "操作历史"),
            modes = { "n" },
        }
    end
    return result
end
function M.perform(direction)
    local svc = service()
    if not svc or type(svc[direction]) ~= "function" then
        vim.notify(L("No task operation to undo/redo", "没有可撤回／重做的任务操作"), vim.log.levels.INFO)
        return
    end
    local ok, task, errors = pcall(svc[direction], svc)
    if not ok then
        vim.notify(require("todo.i18n").t("db_error", tostring(task)), vim.log.levels.ERROR)
        return
    end
    if not task then
        local conflict = errors and errors.history == "conflict"
        vim.notify(
            conflict
                    and L(
                        "Task changed elsewhere; undo/redo was refused",
                        "任务已发生其他修改，无法撤回／重做"
                    )
                or L("No task operation to undo/redo", "没有可撤回／重做的任务操作"),
            conflict and vim.log.levels.WARN or vim.log.levels.INFO
        )
        return
    end
    local todo = package.loaded.todo
    if todo and todo._reconcile_reminders then
        todo._reconcile_reminders()
    end
    local panel = package.loaded["todo.ui.panel"]
    if panel and panel.is_open() then
        panel.inspect_state().selected_id = task.id
        panel.refresh()
    end
    vim.notify(
        (direction == "undo" and L("Undone: ", "已撤回：") or L("Redone: ", "已重做：")) .. task.title,
        vim.log.levels.INFO
    )
end
function M.attach(bufnr)
    vim.keymap.set("n", "U", function()
        M.perform("undo")
    end, { buffer = bufnr, silent = true, desc = "Undo last task operation" })
    vim.keymap.set("n", "<C-r>", function()
        M.perform("redo")
    end, { buffer = bufnr, silent = true, desc = "Redo task operation" })
end
return M
