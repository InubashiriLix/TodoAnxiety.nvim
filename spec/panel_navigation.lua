package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
vim.env.XDG_STATE_HOME = vim.fn.tempname()
require("todo.config").setup({ db_path = vim.fn.tempname() .. ".db", reminders = { enabled = false } })
vim.o.columns, vim.o.lines = 160, 50
local svc = require("todo")._service()
local task = assert(svc:create({ title = "Navigation test", description = string.rep("Context line\n", 100) }))
local panel = require("todo.ui.panel")
local function press(key)
    vim.fn.feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "xt")
    vim.wait(30)
end
panel.open({ selected_id = task.id, mode = "float" })
local o = panel.inspect_state().owner
local list = o.list.bufnr
local initial_width = vim.api.nvim_win_get_width(o.list.winid)
for _, key in ipairs({ "<C-h>", "<C-j>", "<C-k>", "<C-l>" }) do
    press(key)
    assert(vim.api.nvim_get_current_win() == o.list.winid, key .. " escaped")
end
press("+")
assert(vim.api.nvim_win_get_width(o.list.winid) > initial_width)
assert(o.list.bufnr == list)
press("l")
local detail = o.saved_detail.bufnr
assert(vim.api.nvim_get_current_buf() == detail)
press("10j")
local pos = vim.api.nvim_win_get_cursor(o.saved_detail.winid)
for _, size in ipairs({ { 80, 24 }, { 40, 12 }, { 160, 50 } }) do
    vim.o.columns, vim.o.lines = size[1], size[2]
    vim.api.nvim_exec_autocmds("VimResized", {})
    vim.wait(60)
    assert(not o.closed)
    assert(o.saved_detail.bufnr == detail)
    assert(vim.api.nvim_win_get_width(o.saved_detail.winid) <= size[1])
end
press("+")
assert(not o.maximized)
assert(vim.api.nvim_win_get_cursor(o.saved_detail.winid)[1] == pos[1])
panel.close()
panel.open({ selected_id = task.id, mode = "sidebar" })
o = panel.inspect_state().owner
press("+")
assert(o.max_overlay and vim.api.nvim_get_current_buf() == o.split.bufnr)
press("+")
assert(not o.max_overlay and vim.api.nvim_get_current_win() == o.split.winid)
press("<CR>")
assert(o.detail_overlay)
local buf = o.detail_overlay.bufnr
press("+")
assert(require("todo.ui.responsive").is_maximized(o.detail_overlay))
vim.o.columns, vim.o.lines = 60, 20
vim.api.nvim_exec_autocmds("VimResized", {})
vim.wait(60)
press("+")
assert(o.detail_overlay.bufnr == buf)
assert(vim.api.nvim_win_get_width(o.detail_overlay.winid) <= 60)
panel.close()
assert(#vim.api.nvim_list_wins() == 1, "leaked window")
print("ok - local Ctrl guards, float/sidebar/detail maximize, resize and buffer/view preservation")
vim.cmd("qa!")
