local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
local config = require("todo.config")
config.setup({ language = "en", reminders = { enabled = false } })
local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed = passed + 1; print("ok - " .. name)
    else failed = failed + 1; print("not ok - " .. name .. "\n" .. err) end
end
local function press(keys)
    vim.fn.feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt")
    vim.wait(25)
end

test("every hint line has matching text and key highlights", function()
    require("todo.ui.highlights").setup()
    local hints = require("todo.ui.hints")
    local buf = vim.api.nvim_create_buf(false, true)
    local lines = { "[e] Edit  [s] Start", "[延期] 延后  [[ / ]] 切页", "F1 完整帮助" }
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    hints.highlight(buf)
    local ns = vim.api.nvim_get_namespaces().TodoHintHighlight
    local rows = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
        rows[mark[2]] = rows[mark[2]] or {}
        rows[mark[2]][mark[4].hl_group] = true
    end
    for i = 0, 2 do
        assert(rows[i].TodoHintText and rows[i].TodoHintKey, "missing uniform highlights on row " .. i)
    end
    assert(vim.api.nvim_get_hl(0, { name = "TodoHintText", link = false }).italic ~= true)
    local other = vim.api.nvim_buf_get_extmarks(buf, ns, { 2, 0 }, { 2, -1 }, { details = true })
    hints.highlight(buf, 0, 1)
    assert(vim.deep_equal(other, vim.api.nvim_buf_get_extmarks(buf, ns, { 2, 0 }, { 2, -1 }, { details = true })))
    vim.api.nvim_buf_delete(buf, { force = true })
end)

test("U and Ctrl-r undo and redo saved task operations in the panel", function()
    local store = require("todo.store").open(vim.fn.tempname() .. ".db")
    local svc = require("todo.service").new(store)
    local task = assert(svc:create({ title = "Undo task", deadline = "2020-01-01", reminder_interval = "5m" }))
    local reconciled = 0
    package.loaded.todo = {
        _service = function() return svc end,
        _reschedule_reminders = function() end,
        _reconcile_reminders = function() reconciled = reconciled + 1 end,
    }
    local panel = require("todo.ui.panel")
    panel.open({ mode = "float", view = "active" })
    vim.wait(30)
    press("s")
    assert(store:get(task.id).status == "in_progress")
    press("U")
    assert(store:get(task.id).status == "todo")
    press("<C-r>")
    assert(store:get(task.id).status == "in_progress")
    local deadline = store:get(task.id).due_date
    assert(svc:postpone(task.id, "1d"))
    panel.refresh()
    press("U")
    assert(store:get(task.id).due_date == deadline)
    press("A")
    assert(store:get(task.id).archived_at)
    press("U")
    assert(not store:get(task.id).archived_at)
    assert(reconciled >= 4, "undo must reconcile scheduled reminders")
    local before = store:get(task.id)
    store:set_status(task.id, "done")
    press("U")
    assert(store:get(task.id).status == "done", "undo must not overwrite external changes")
    assert(svc:can_undo(), "conflict must leave history intact")
    panel.close()
    store:close()
    package.loaded.todo = nil
end)
print(string.format("%d history/highlight tests passed, %d failed", passed, failed))
if failed > 0 then vim.cmd("cquit 1") end
vim.cmd("qa!")
