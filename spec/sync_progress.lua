local config = require("todo.config")
local progress = require("todo.ui.sync_progress")
local passed, failed = 0, 0
local function test(name, fn)
    local notify, columns, lines = vim.notify, vim.o.columns, vim.o.lines
    -- Simulate a notification provider filtering INFO messages.
    vim.notify = function() end
    config.setup({ language = "zh-CN" })
    local ok, err = xpcall(fn, debug.traceback)
    progress.close()
    vim.notify, vim.o.columns, vim.o.lines = notify, columns, lines
    config.setup({})
    if ok then
        passed = passed + 1
        print("ok - sync feedback: " .. name)
    else
        failed = failed + 1
        print("not ok - sync feedback: " .. name .. "\n" .. err)
    end
end
local function text(owner)
    return table.concat(vim.api.nvim_buf_get_lines(owner.buf, 0, -1, false), "\n")
end
local function contains(value, expected)
    assert(value:find(expected, 1, true), "missing " .. expected .. " in " .. value)
end

test("visible stages and elapsed time without taking focus", function()
    local origin = vim.api.nvim_get_current_win()
    local owner = progress.start()
    assert(vim.api.nvim_win_is_valid(owner.win))
    assert(vim.api.nvim_get_current_win() == origin)
    assert(not vim.api.nvim_win_get_config(owner.win).focusable)
    contains(text(owner), "[1/5]")
    owner:update({ phase = "download", attempt = 2 })
    contains(text(owner), "正在连接远端并下载")
    contains(text(owner), "第 2/3 轮")
    owner.started = (vim.uv or vim.loop).hrtime() - 2100000000
    assert(vim.wait(600, function()
        return text(owner):find("已用时 2 秒", 1, true) ~= nil
    end, 20))
    assert(vim.api.nvim_get_current_win() == origin)
end)

test("success remains visible and is saved to message history", function()
    local owner = progress.start()
    owner:finish(nil, { uploaded = 3, downloaded = 2, pending = 1 })
    assert(not owner.running and vim.api.nvim_win_is_valid(owner.win))
    contains(text(owner), "同步完成")
    contains(text(owner), "已上传 3 条变更，下载 2 条变更")
    contains(text(owner), "请再执行一次")
    local due = owner.timer:get_due_in()
    assert(due > 7000 and due <= 8000, "completion must remain visible for eight seconds")
    contains(vim.api.nvim_exec2("messages", { output = true }).output, "已上传 3 条变更，下载 2 条变更")
    owner:update({ phase = "upload" })
    contains(text(owner), "同步完成")
end)

test("no-change, failure and cancellation have distinct results", function()
    local owner = progress.start()
    owner:finish(nil, { uploaded = 0, downloaded = 0, pending = 0 })
    contains(text(owner), "已经是最新状态")
    owner = progress.start()
    owner:finish("Permission denied (publickey)")
    contains(text(owner), "同步失败，本地修改已保留")
    contains(text(owner), "Permission denied")
    assert(owner.timer:get_due_in() > 14000)
    owner = progress.start()
    owner:finish("cancelled", { cancelled = true })
    contains(text(owner), "同步已取消")
    assert(not owner.failed)
end)

test("small screens, replacement and teardown do not leak windows or timers", function()
    local first = progress.start()
    local first_window = first.win
    local second = progress.start()
    assert(first.closed and first.timer:is_closing())
    assert(not vim.api.nvim_win_is_valid(first_window))
    first:close()
    assert(progress.inspect_state() == second)
    vim.o.columns, vim.o.lines = 28, 10
    vim.api.nvim_exec_autocmds("VimResized", {})
    local layout = vim.api.nvim_win_get_config(second.win)
    assert(layout.width <= 22 and layout.height <= 4)
    local second_window = second.win
    progress.close()
    assert(not vim.api.nvim_win_is_valid(second_window))
    assert(second.timer:is_closing())
    assert(progress.inspect_state() == nil)
end)

test("public sync command shows immediate configuration failures", function()
    require("todo")._reset_for_tests()
    local service = require("todo")._service
    require("todo")._service = function()
        return { store = {} }
    end
    local ok, err = pcall(require("todo").sync)
    require("todo")._service = service
    assert(ok, err)
    local owner = assert(progress.inspect_state())
    contains(text(owner), "同步失败")
    contains(text(owner), "同步未启用")
    require("todo")._reset_for_tests()
    assert(progress.inspect_state() == nil)
end)

print(string.format("%d sync feedback tests passed, %d failed", passed, failed))
if failed > 0 then
    vim.cmd("cquit " .. failed)
end
vim.cmd("qa!")
