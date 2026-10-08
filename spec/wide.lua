local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local description = { "The detail pane should remain visible." }
for index = 1, 60 do
    description[#description + 1] = "Detail line " .. index
end

local tasks = {
    {
        id = 1,
        title = "Wide dashboard task",
        description = table.concat(description, "\n"),
        status = "in_progress",
        priority = 1,
        tags = { "ui", "wide" },
        created_at = os.time(),
        updated_at = os.time(),
    },
}

local store = {}
function store:list(opts)
    return opts.archived and {} or vim.deepcopy(tasks)
end

function store:get(id)
    return id == 1 and tasks[1] or nil
end

function store:stats()
    return { active = 1, emergency = 1, archived = 0 }
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
vim.api.nvim_set_current_win(state.owner.detail.winid)
local press = function(keys)
    vim.fn.feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt")
end
press("G")
assert(vim.api.nvim_win_get_cursor(state.owner.detail.winid)[1] == #detail_lines, "G should reach the detail end")
press("gg")
assert(vim.api.nvim_win_get_cursor(state.owner.detail.winid)[1] == 1, "gg should reach the detail start")
press("<C-d>")
local down_line = vim.api.nvim_win_get_cursor(state.owner.detail.winid)[1]
assert(down_line > 1, "Ctrl-D should move down in details")
press("<C-u>")
assert(vim.api.nvim_win_get_cursor(state.owner.detail.winid)[1] < down_line, "Ctrl-U should move up in details")
panel.close()
print("ok - wide NUI dashboard uses list/detail layout")
vim.cmd("qa!")
