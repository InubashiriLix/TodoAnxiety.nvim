package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
local mark = require("todo.ui.task_mark")
local overdue = { priority = 0, status = "todo", due_date = "2020-01-01", due_time = "10:00" }
assert(mark.priority_group(overdue) == "TodoPriorityBadge0")
assert(mark.right_group(overdue) == "TodoBarOverdue")
assert(mark.due_group(overdue) == "TodoDueOverdue")
assert(mark.left_group(overdue, "today") == "TodoBarToday")
assert(mark.left_group(overdue, "review") == "TodoBarReview")
assert(mark.left_group(overdue, nil) == "TodoBarActive")
local done = vim.tbl_extend("force", overdue, { status = "done" })
assert(mark.priority_group(done) == "TodoMuted")
assert(mark.right_group(done) == nil)
assert(mark.left_group(done, "today") == nil)
local viewmodel = require("todo.ui.viewmodel")
local line1, line2, info = viewmodel.card(overdue, 80, "overdue", {
    plan_state = "today",
    ai_selected = true,
})
assert(line1:find("▎", 1, true) and line1:find("■", 1, true) and line1:find("▐", 1, true))
assert(line2:find("▐", 1, true))
assert(info.left_group == "TodoBarToday" and info.ai_group == "TodoBarAI")
assert(info.priority_group == "TodoPriorityBadge0" and info.right_group == "TodoBarOverdue")
print("ok - task card left/right bars, AI mark and priority/due groups")
vim.cmd("qa!")
