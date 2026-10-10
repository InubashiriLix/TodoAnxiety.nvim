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

-- The detail pane stays focusable, but gg/G/Ctrl-U/Ctrl-D must still move the
-- list selection and hand focus back to the list instead of scrolling the text.
local press = function(keys)
    vim.fn.feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt")
end
local focus_detail = function()
    vim.api.nvim_set_current_win(state.owner.detail.winid)
end

focus_detail()
press("gg")
assert(state.cursor_row == 1, "gg from details should select the first row")
assert(vim.api.nvim_get_current_win() == state.owner.list.winid, "gg from details should return focus to the list")

focus_detail()
press("G")
assert(state.cursor_row == #state.rows, "G from details should select the last row")
assert(state.rows[#state.rows].task.id == 8, "G should land on the last task")
assert(vim.api.nvim_get_current_win() == state.owner.list.winid, "G from details should return focus to the list")

focus_detail()
press("gg")
local top = state.cursor_row
focus_detail()
press("<C-d>")
assert(state.cursor_row > top, "Ctrl-D from details should advance the list selection")
assert(vim.api.nvim_get_current_win() == state.owner.list.winid, "Ctrl-D from details should return focus to the list")

local down = state.cursor_row
focus_detail()
press("<C-u>")
assert(state.cursor_row < down, "Ctrl-U from details should retreat the list selection")
assert(vim.api.nvim_get_current_win() == state.owner.list.winid, "Ctrl-U from details should return focus to the list")

panel.close()
print("ok - wide NUI dashboard uses list/detail layout")
vim.cmd("qa!")
