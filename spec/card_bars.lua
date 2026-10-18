package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
vim.env.XDG_STATE_HOME = vim.fn.tempname()
require("todo.config").setup({
    db_path = vim.fn.tempname() .. ".db",
    reminders = { enabled = false },
    ai = { enabled = false },
})
local todo = require("todo")
local svc = todo._service()
local planner = require("todo.planning").new(svc.store.workspace, svc)
local task = assert(svc:create({ title = "三段竖条任务", description = "details", tags = { "ui" } }))
planner:add(task.sync_uuid)
local panel = require("todo.ui.panel")
panel.open({ mode = "float", view = "today" })
vim.wait(100)
local owner = panel.inspect_state().owner
local lines = vim.api.nvim_buf_get_lines(owner.list.bufnr, 0, -1, false)
local found = {}
for index, line in ipairs(lines) do
    if line:find("▌", 1, true) or line:find("▐", 1, true) then
        found[#found + 1] = { index = index, line = line }
    end
end
assert(#found == 3, "task item must span exactly three bar rows, got " .. #found)
local width = vim.api.nvim_win_get_width(owner.list.winid)
for _, item in ipairs(found) do
    assert(vim.startswith(item.line, "▌ "), "left bar must start the card: " .. item.line)
    assert(vim.endswith(item.line, "▐"), "right bar must reach the right edge: " .. item.line)
    assert(vim.fn.strdisplaywidth(item.line) == width, "bar row must fill the list width")
end
panel.close()
print("ok - task cards use three-row full-height left/right bars")
vim.cmd("qa!")
