local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local description = { "The detail pane should remain visible." }
for index = 1, 60 do
    description[#description + 1] = "Detail line " .. index
end

local tasks = {}
for index = 1, 8 do
    tasks[index] = {
        id = index,
        title = index == 1 and "Wide dashboard task" or ("Wide dashboard task " .. index),
        description = table.concat(description, "\n"),
        status = "in_progress",
        priority = 1,
        tags = { "ui", "wide" },
        created_at = index,
        updated_at = index,
    }
end

local store = {}
function store:list(opts)
    return opts.archived and {} or vim.deepcopy(tasks)
end

function store:get(id)
    return tasks[id]
end

function store:stats()
    return { active = #tasks, emergency = #tasks, archived = 0 }
end

function store:list_tags()
    return { "ui", "wide" }
end

require("todo.config").setup({ keymaps = { enabled = false } })
local service = require("todo.service").new(store)
package.loaded.todo = {
    _service = function()
        return service
    end,
}
local panel = require("todo.ui.panel")
panel.open({ mode = "float", view = "active" })
vim.wait(30)
local state = panel.inspect_state()
assert(state.owner.wide == true, "expected wide dashboard layout")
assert(state.owner.detail and vim.api.nvim_win_is_valid(state.owner.detail.winid), "expected detail pane")
assert(vim.api.nvim_win_get_width(state.owner.list.winid) > vim.api.nvim_win_get_width(state.owner.detail.winid))
local detail_lines = vim.api.nvim_buf_get_lines(state.owner.detail.bufnr, 0, -1, false)
assert(
    vim.iter(detail_lines):any(function(line)
        return line:find("The detail pane should remain visible.", 1, true) ~= nil
    end),
    "expected selected task description in detail pane"
)
assert(detail_lines[1] == "# Wide dashboard task", "expected a markdown heading, got " .. tostring(detail_lines[1]))
assert(vim.bo[state.owner.detail.bufnr].filetype == "markdown", "expected markdown filetype on the detail pane")
assert(
    vim.iter(detail_lines):any(function(line)
        return line:find("`e` Edit", 1, true) ~= nil
    end),
    "expected readable detail actions"
)

local press = function(keys)
    vim.fn.feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt")
end

local function check_detail_navigation(component)
    local row, id = state.cursor_row, state.selected_id
    local list_win = state.owner.split and state.owner.split.winid or state.owner.list.winid
    local list_cursor = vim.api.nvim_win_get_cursor(list_win)
    local original_lines = vim.api.nvim_buf_get_lines(component.bufnr, 0, -1, false)
    local function line()
        return vim.api.nvim_win_get_cursor(component.winid)[1]
    end
    local function navigate(keys)
        press(keys)
        assert(vim.api.nvim_get_current_win() == component.winid, keys .. " should keep focus in details")
        assert(state.cursor_row == row and state.selected_id == id, keys .. " must not change task selection")
        assert(vim.deep_equal(vim.api.nvim_win_get_cursor(list_win), list_cursor), keys .. " must not move the list cursor")
        assert(
            vim.deep_equal(vim.api.nvim_buf_get_lines(component.bufnr, 0, -1, false), original_lines),
            keys .. " must not replace detail content"
        )
    end
    navigate("gg")
    assert(line() == 1, "gg should reach the detail start")
    navigate("j")
    assert(line() == 2, "j should move down in details")
    navigate("k")
    assert(line() == 1, "k should move up in details")
    navigate("3j")
    assert(line() == 4, "detail navigation should honor counts")
    navigate("G")
    assert(line() == #original_lines, "G should reach the detail end")
    navigate("<C-u>")
    local up = line()
    assert(up < #original_lines, "Ctrl-U should move up in details")
    navigate("<C-d>")
    assert(line() > up, "Ctrl-D should move down in details")
end

press("l")
assert(vim.api.nvim_get_current_win() == state.owner.detail.winid, "l should enter details")
check_detail_navigation(state.owner.detail)
press("h")
assert(vim.api.nvim_get_current_win() == state.owner.list.winid, "h should return to the list")
local first_id = state.selected_id
press("j")
assert(state.selected_id ~= first_id, "j in the list should select another task")
press("k")
assert(state.selected_id == first_id, "k in the list should select the previous task")
press("G")
assert(state.cursor_row == #state.rows, "G in the list should select the last row")
assert(state.selected_id == 8, "G should land on the last task")
assert(vim.api.nvim_buf_get_lines(state.owner.detail.bufnr, 0, 1, false)[1] == "# Wide dashboard task 8")
press("gg")
assert(state.cursor_row == 1, "gg in the list should select the first row")
press("<C-d>")
local down = state.cursor_row
assert(down > 1, "Ctrl-D in the list should advance selection")
press("<C-u>")
assert(state.cursor_row < down, "Ctrl-U in the list should retreat selection")

-- Reusing the persistent detail buffer across layouts must not restore task
-- navigation callbacks in the overlay or in a reopened fixed pane.
local detail_buf = state.owner.detail.bufnr
panel.close()
require("todo.config").setup({ keymaps = { enabled = false }, ui = { float = { width = 0.5 } } })
panel.open({ mode = "float", view = "active" })
vim.wait(30)
state = panel.inspect_state()
press("<CR>")
local overlay = assert(state.owner.detail_overlay)
assert(overlay.bufnr == detail_buf, "overlay should reuse the detail buffer")
check_detail_navigation(overlay)
press("q")
vim.wait(30)
assert(vim.api.nvim_get_current_win() == state.owner.list.winid, "closing details should return to the list")
panel.close()
require("todo.config").setup({ keymaps = { enabled = false } })
panel.open({ mode = "float", view = "active" })
vim.wait(30)
state = panel.inspect_state()
assert(state.owner.detail.bufnr == detail_buf, "reopened pane should reuse the detail buffer")
press("l")
check_detail_navigation(state.owner.detail)
panel.close()
print("ok - wide NUI dashboard keeps detail navigation separate from task selection")
vim.cmd("qa!")
