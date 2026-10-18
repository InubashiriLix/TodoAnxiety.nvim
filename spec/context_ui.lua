local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
local config = require("todo.config")
config.setup({ language = "en", reminders = { enabled = false } })
local hints = require("todo.ui.hints")
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
local function mapping(buf, mode, key)
    for _, item in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
        if item.lhs:lower() == key:lower() then return item end
    end
end
local function settle() vim.wait(30) end

test("context help groups all actions and restores focus without editing", function()
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unchanged" })
    local owner = {}
    local entries = {}
    for i = 1, 35 do entries[i] = { key = "key" .. i, label = "说明 " .. i, group = i < 15 and "导航" or "编辑" } end
    hints.attach(buf, function(mode)
        return { title = "Context " .. mode, actions = entries }
    end, { owner = owner })
    assert(not mapping(buf, "i", "?"), "insert ? must remain text")
    press("i<F1>")
    local help = assert(owner.help, "F1 must open help from insert mode")
    assert(vim.api.nvim_get_current_win() == help.winid)
    local lines = vim.api.nvim_buf_get_lines(help.bufnr, 0, -1, false)
    assert(table.concat(lines, "\n"):find("说明 35", 1, true), "full help must contain last action")
    assert(#lines > vim.api.nvim_win_get_height(help.winid), "long help must scroll")
    press("G")
    assert(vim.api.nvim_win_get_cursor(help.winid)[1] == #lines)
    press("q")
    assert(owner.help == nil and vim.api.nvim_get_current_win() == win)
    assert(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "unchanged")
    -- feedkeys xt leaves insert at the end; check the restoration request using
    -- the real mode before another key loop exits Insert.
    vim.cmd("stopinsert")
end)

test("task and notice descriptions retain insert Tab, normal Tab moves focus", function()
    vim.o.columns=140;vim.o.lines=45
    for _, module in ipairs({ "todo.ui.form", "todo.ui.notice_form" }) do
        vim.cmd("stopinsert")
        local form = require(module)
        form.open({}, function() return true end)
        settle()
        local state = assert(form.inspect_state())
        local desc = state.components.description
        assert(not mapping(desc.bufnr, "i", "<Tab>"), module .. " must not map insert Tab")
        assert(not mapping(desc.bufnr, "i", "<S-Tab>"), module .. " must not map insert Shift-Tab")
        assert(mapping(desc.bufnr, "n", "<Tab>"))
        assert(mapping(state.components.title.bufnr, "i", "<Tab>"))
        vim.api.nvim_set_current_win(desc.winid)
        press("i<Tab>")
        assert(vim.api.nvim_get_current_win() == desc.winid, "insert Tab must stay in description")
        assert(vim.api.nvim_buf_get_lines(desc.bufnr, 0, 1, false)[1]:match("%s"), "Tab must insert indentation")
        vim.cmd("stopinsert")
        press("<Tab>")
        assert(vim.api.nvim_get_current_win() == state.components.footer.winid, "normal Tab should switch fields")
        vim.api.nvim_set_current_win(desc.winid)
        press("<F1>")
        local help = assert(state.help)
        assert(vim.api.nvim_buf_get_lines(help.bufnr, 0, 1, false)[1]:find("Description", 1, true))
        press("q")
        assert(vim.api.nvim_get_current_win() == desc.winid)
        if state.force_close then state.force_close("discarded") else state.close("discarded") end
        settle()
    end
end)

local function overdue(kind)
    return { id = 1, kind = kind or "task", title = "Overdue", status = "todo", priority = 2,
        due_date = "2020-01-01", due_time = "09:00", tags = {}, sync_revision = "r1",
        reminder = { enabled = true, scheduled_at = 100, next_reminder_at = 100, repeat_interval_seconds = 300 } }
end

test("reminder postpone default, invalid input retry, cancellation and help", function()
    local popup = require("todo.ui.reminder_popup")
    local action, value
    popup.show(overdue(), function(a, v) action, value = a, v end)
    settle()
    local owner = assert(popup.inspect_state())
    press("p")
    local input = owner.component
    assert(vim.api.nvim_buf_get_lines(input.bufnr, 0, 1, false)[1] == "1d")
    press("<F1>")
    assert(owner.help and vim.api.nvim_get_current_win() == owner.help.winid)
    press("q")
    assert(owner.component == input and vim.api.nvim_get_current_win() == input.winid)
    vim.api.nvim_buf_set_lines(input.bufnr, 0, -1, false, { "0m" })
    press("i<CR>")
    assert(action == nil and popup.inspect_state() == owner)
    local retry = owner.component
    assert(retry ~= input and vim.api.nvim_buf_get_lines(retry.bufnr, 0, 1, false)[1] == "0m")
    press("<Esc>")
    assert(action == nil and popup.inspect_state() == owner)
    assert(owner.component ~= retry, "cancel returns to main reminder")
    press("p")
    local custom = owner.component
    vim.api.nvim_buf_set_lines(custom.bufnr, 0, -1, false, { "2h" })
    press("i<CR>")
    assert(action == "postpone" and value == 7200)
    assert(popup.inspect_state() == nil)
    popup.show(overdue("notice"), function(a) action = a end)
    settle()
    owner = popup.inspect_state()
    local main = owner.component
    press("p")
    assert(owner.component == main, "notice must not open a postponement input")
    popup.close()
end)

test("postpone errors release the scheduler and continue the queue", function()
    for _, failure in ipairs({ "conflict", "database", "success" }) do
        local task = overdue()
        local callbacks, now = {}, 1800000000
        local called = false
        local svc = {
            store = { get = function() local t = vim.deepcopy(task); t.sync_revision = failure == "conflict" and "r2" or "r1"; return t end },
            postpone = function(_, id, seconds, time, revision)
                called = true
                assert(id == 1 and seconds == 86400 and time == now and revision == "r1")
                if failure == "database" then error("save failed") end
                local updated = vim.deepcopy(task)
                updated.due_date, updated.due_time = "2027-01-01", "12:00"
                return updated
            end,
        }
        local scheduler = require("todo.scheduler").new(svc, {
            now = function() return now end, timer = {}, play_sound = function() end,
            presenter = function(_, cb) callbacks[#callbacks + 1] = cb end,
        })
        scheduler.queue = { task }
        scheduler.pending_ids[1] = true
        scheduler:_drain()
        callbacks[1]("postpone", 86400)
        assert(called == (failure ~= "conflict"))
        assert(not scheduler.presenting and scheduler.active_task == nil and not scheduler.pending_ids[1])
        scheduler.queue = { task }
        scheduler:_drain()
        assert(#callbacks == 2, "next reminder should still present")
    end
end)
print(string.format("%d contextual UI tests passed, %d failed", passed, failed))
if failed > 0 then vim.cmd("cquit 1") end
vim.cmd("qa!")
