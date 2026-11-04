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

local function feed(keys)
    vim.fn.feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt")
    vim.wait(30)
end

-- Esc only changes mode in the task form; it must never request a close.
o = open()
assert(vim.api.nvim_buf_call(o.components.description.bufnr, function()
    return vim.fn.maparg("<Esc>", "n")
end) == "", "task form must not map Normal Esc to close")
feed("<Esc>")
assert(not o.closed, "Esc must not close the task form")
feed("+")
assert(o.maximized == 7, "Normal + must expand the focused description field")
feed("+")
assert(not o.maximized, "Normal + must restore the description field")
form.close(true)

-- The AI proposal editor follows the same protocol: Esc never saves/closes,
-- Enter saves, and + expands the popup.
local saved_proposal
local proposal = require("todo.ui.planner").editor("Edit detail", "old", function(value)
    saved_proposal = value
    return true
end)
vim.wait(30)
assert(vim.api.nvim_buf_call(proposal.bufnr, function()
    return vim.fn.maparg("<Esc>", "n")
end) == "", "proposal editor must not map Normal Esc to save/close")
feed("<Esc>")
assert(vim.api.nvim_win_is_valid(proposal.winid), "Esc must not close the proposal editor")
local proposal_width = vim.api.nvim_win_get_width(proposal.winid)
feed("+")
assert(vim.api.nvim_win_get_width(proposal.winid) > proposal_width, "+ must expand the proposal editor")
feed("+")
vim.api.nvim_buf_set_lines(proposal.bufnr, 0, -1, false, { "changed" })
feed("<CR>")
assert(saved_proposal == "changed", "Enter must save the proposal editor")

-- N edits task notes, including AI-authored ones, without closing the form.
local ws = require("todo.workspace").new(svc.store)
ws:put("note", "ai-note-form", {
    task_uuid = task.sync_uuid,
    text = "confirm tablet get method and task details",
    source = "ai",
    created_at = 1,
})
o = open()
local previous_select = vim.ui.select
local planner = require("todo.ui.planner")
local previous_editor = planner.editor
local loaded
vim.ui.select = function(items, _, callback)
    callback(items[2])
end
planner.editor = function(_, value, save)
    loaded = value
    assert(save("edited from the form"))
end
feed("N")
vim.ui.select = previous_select
planner.editor = previous_editor
assert(loaded == "confirm tablet get method and task details", "form N must load the AI note")
assert(ws:get("note", "ai-note-form").text == "edited from the form", "form N must save the note")
assert(not o.closed, "editing notes must keep the task form open")
assert(
    vim.api.nvim_get_current_win() == o.components.description.winid,
    "note editing must return focus to the form"
)
form.close(true)

print("ok - real :w/:wq/:x/:q/:q!, failed persistence, parent window and repeated creation")
vim.cmd("qa!")
