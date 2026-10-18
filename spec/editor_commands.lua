package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
vim.env.XDG_STATE_HOME = vim.fn.tempname()
require("todo.config").setup({ db_path = vim.fn.tempname() .. ".db", reminders = { enabled = false } })
vim.o.columns, vim.o.lines = 160, 50
local svc = require("todo")._service()
local form = require("todo.ui.form")
local task = assert(svc:create({ title = "Ex save test", description = "Original" }))
local writes = 0
local function open()
    form.open(task, function(input, saved)
        writes = writes + 1
        local result, err = svc:update(task.id, input, saved.sync_revision)
        if result then
            task = result
        end
        return result, err
    end)
    vim.wait(30)
    vim.cmd("stopinsert")
    local o = form.inspect_state()
    vim.api.nvim_set_current_win(o.components.description.winid)
    return o
end
local function text(o, value)
    vim.api.nvim_buf_set_lines(o.components.description.bufnr, 0, -1, false, { value })
end
local o = open()
text(o, "Saved once")
vim.cmd("write")
assert(not o.closed and svc.store:get(task.id).description == "Saved once")
text(o, "Keep me after rejected quit")
local ok = pcall(vim.cmd, "quit")
vim.wait(30)
assert(not ok and not o.closed, "dirty :q must reject and leave editor alive")
assert(vim.api.nvim_buf_get_lines(o.components.description.bufnr, 0, -1, false)[1] == "Keep me after rejected quit")
vim.cmd("quit!")
vim.wait(30)
assert(o.closed and svc.store:get(task.id).description == "Saved once", ":q! must discard only unsaved changes")
o = open()
text(o, "Saved by wq")
vim.cmd("wq")
vim.wait(30)
assert(o.closed and svc.store:get(task.id).description == "Saved by wq")
assert(#vim.api.nvim_list_wins() == 1, "wq must return to parent")
o = open()
text(o, "Saved by x")
vim.cmd("x")
vim.wait(30)
assert(o.closed and svc.store:get(task.id).description == "Saved by x")
-- :x from details must also save a changed title in another field.
o = open()
vim.api.nvim_buf_set_lines(o.components.title.bufnr, 0, -1, false, { "Changed title from another field" })
vim.cmd("x")
vim.wait(30)
assert(o.closed and svc.store:get(task.id).title == "Changed title from another field", "x missed another dirty field")
-- Failed writes must abort :wq before the window disappears.
form.open(task, function()
    error("simulated persistence error")
end)
vim.wait(30)
vim.cmd("stopinsert")
o = form.inspect_state()
vim.api.nvim_set_current_win(o.components.description.winid)
text(o, "Recover me")
ok = pcall(vim.cmd, "wq")
vim.wait(30)
assert(not ok and not o.closed)
assert(vim.api.nvim_buf_get_lines(o.components.description.bufnr, 0, -1, false)[1] == "Recover me")
form.close(true)
-- Built-in creation callback changes to update after the first :w.
require("todo").add({ title = "Created only once" })
vim.wait(30)
vim.cmd("stopinsert")
o = form.inspect_state()
vim.api.nvim_set_current_win(o.components.description.winid)
text(o, "First")
vim.cmd("w")
local id = o.saved_task.id
text(o, "Second")
vim.cmd("w")
assert(o.saved_task.id == id)
local count = 0
for _, t in ipairs(svc:list({})) do
    if t.title == "Created only once" then
        count = count + 1
    end
end
assert(count == 1, "repeated write duplicated task")
vim.cmd("wq")
vim.wait(30)
assert(#vim.api.nvim_list_wins() == 1)
print("ok - real :w/:wq/:x/:q/:q!, failed persistence, parent window and repeated creation")
vim.cmd("qa!")
