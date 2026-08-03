local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local database = vim.fn.tempname() .. ".db"
local todo = require("todo")
todo.setup({
  db_path = database,
  language = "zh-CN",
  keymaps = { enabled = false },
  reminders = { enabled = false },
})

local task = assert(todo._service():create({
  title = "完整启动测试",
  description = "SQLite、服务层和 NUI 应当协同工作。",
  priority = "P1",
  deadline = "2026-08-02 18:00",
  reminder_interval = "5m",
  tags = { "集成", "UI" },
}))

local notice = assert(todo._service():create({
  kind = "notice",
  title = "五分钟后洗澡",
  trigger = "5m",
  reminder_interval = "2m",
  recurrence = { kind = "once" },
}))

assert(vim.fn.exists(":Todo") == 2, ":Todo command was not registered")
vim.cmd("Todo open float notices")
vim.wait(30)
local panel = require("todo.ui.panel")
assert(panel.current_task().id == notice.id, "notice view did not select the persisted notice")
vim.cmd("Todo open float emergency")
vim.wait(30)
assert(panel.is_open(), "dashboard did not open")
assert(panel.current_task().id == task.id, "created task is not selected")
assert(panel.inspect_state().stats.emergency == 1, "emergency count is incorrect")
vim.cmd("Todo add 从命令打开表单")
assert(
  vim.wait(100, function()
    return require("todo.ui.form").inspect_state() ~= nil
  end),
  "command did not open the add form"
)
assert(not panel.is_open(), "command add did not suspend the dashboard")
local form_state = require("todo.ui.form").inspect_state()
local status_line = vim.api.nvim_buf_get_lines(form_state.components.status.bufnr, 0, 1, false)[1]
assert(
  status_line:find("待办", 1, true) and status_line:find("进行中", 1, true),
  "Chinese status choices are missing"
)
local deadline_line = vim.api.nvim_buf_get_lines(form_state.components.deadline.bufnr, 0, 1, false)[1]
assert(deadline_line:find("尚未选择", 1, true), "Chinese deadline picker is unclear")
form_state.open_calendar()
assert(form_state.calendar_state and form_state.choose_calendar_date, "calendar picker did not open")
form_state.choose_calendar_date()
vim.wait(20)
require("todo.ui.form").close(true)
assert(
  vim.wait(100, function()
    return panel.is_open()
  end),
  "dashboard did not resume after command form closed"
)
vim.cmd("Todo tags")
local tag_panel = require("todo.ui.tag_panel")
assert(tag_panel.is_open(), ":Todo tags did not open the manager")
local tag_lines = vim.api.nvim_buf_get_lines(tag_panel.inspect_state().popup.bufnr, 0, -1, false)
assert(
  vim.iter(tag_lines):any(function(line)
    return line:find("#集成", 1, true) ~= nil
  end),
  "tag manager did not show persisted tags"
)
tag_panel.close()
todo.close()
todo._reset_for_tests()

for _, suffix in ipairs({ "", "-wal", "-shm" }) do
  os.remove(database .. suffix)
end

print("ok - full SQLite and NUI startup")
vim.cmd("qa!")
