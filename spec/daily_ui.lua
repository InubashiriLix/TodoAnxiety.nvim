package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
vim.env.XDG_STATE_HOME = vim.fn.tempname()
require("todo.config").setup({
    db_path = vim.fn.tempname() .. ".db",
    reminders = { enabled = false },
    ai = { enabled = true, api_key = "mock-daily-ui" },
})
local todo = require("todo")
local svc = todo._service()
local ws = svc.store.workspace
local task = assert(svc:create({ title = "Daily UI test", description = "Original" }))
local planner = require("todo.planning").new(ws, svc)
planner:add(task.sync_uuid)
local ai = require("todo.ai").new(ws, svc, {
    transport = function(opts, cb)
        vim.defer_fn(function()
            cb(nil, {
                choices = {
                    {
                        finish_reason = "stop",
                        message = {
                            content = vim.json.encode({
                                message = "Choose a goal",
                                action = "question",
                                understanding = {
                                    goal_clear = false,
                                    goal = "",
                                    deliverable = "",
                                    unknowns = { "Goal" },
                                    evidence = {},
                                },
                                questions = {
                                    {
                                        id = "q",
                                        intent = "goal",
                                        header = "Goal",
                                        question = "Choose?",
                                        options = {
                                            { id = "a", label = "A", description = "Description A" },
                                            { id = "b", label = "B" },
                                            { id = "c", label = "C" },
                                        },
                                    },
                                },
                            }),
                        },
                    },
                },
                usage = { prompt_tokens = 10, completion_tokens = 5 },
            })
        end, 40)
        return {
            running = true,
            cancel = function()
                cb("cancelled")
            end,
        }
    end,
})
todo._ai = function()
    return ai
end
local ui = require("todo.ui.daily")
local o = todo.plan()
assert(o == ui.inspect_state())
local function press(k)
    vim.fn.feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), "xt")
    vim.wait(90)
end
assert(vim.bo[o.composer.bufnr].modifiable)
assert(not vim.bo[o.questions.bufnr].modifiable)
assert(vim.api.nvim_get_mode().mode == "n")
local function title(pop)
    local chunks = vim.api.nvim_win_get_config(pop.winid).title
    return type(chunks) == "table" and chunks[1][1] or chunks or ""
end
local function footer(owner)
    return table.concat(vim.api.nvim_buf_get_lines(owner.footer.bufnr, 0, -1, false), "\n")
end
assert(title(o.timeline):find("Context", 1, true), "context border must have a visible title")
assert(title(o.questions):find("Tasks", 1, true))
vim.wait(60) -- Focus-dependent hints settle after WinEnter.
assert(footer(o):find("Confirm fixed items", 1, true))
assert(not footer(o):find("Add note", 1, true), "preparation edits the task, not an answer")
press("<CR>")
press("w")
assert(
    vim.wait(5000, function()
        return o.controller.state.status == "awaiting" and not o.controller.busy
    end),
    o.controller.state.last_error
)
vim.wait(100)
vim.api.nvim_set_current_win(o.questions.winid)
-- Tab opens the supplement editor; Tab again saves and returns to options.
press("<Tab>")
assert(vim.api.nvim_get_current_win() == o.composer.winid, "Tab must open supplement")
press("<Tab>")
assert(vim.api.nvim_get_current_win() == o.questions.winid, "Tab in supplement must return to options")
press("<Space>")
press("e")
local option_buf = o.composer.bufnr
vim.api.nvim_buf_set_lines(option_buf, 0, -1, false, { "Extra option information" })
press("<Esc>")
local ctl = o.controller
local round = ctl.cache.rounds[ctl:item_id(ctl:current())]
assert(round.answers.q.notes.a == "Extra option information")
vim.api.nvim_set_current_win(o.questions.winid)
press("i")
vim.api.nvim_buf_set_lines(o.composer.bufnr, 0, -1, false, { "Also account for the API migration." })
press("<Esc>")
assert(round.answers.q.selected.a, "supplement must preserve selected answer")
assert(round.answers.q.custom == "Also account for the API migration.")
vim.api.nvim_set_current_win(o.questions.winid)
press("j<Space>")
assert(round.answers.q.selected.b and not round.answers.q.selected.a)
assert(round.answers.q.custom == "Also account for the API migration.", "switching answer must preserve supplement")
press("e")
option_buf = o.composer.bufnr
for _, size in ipairs({ { 80, 24 }, { 40, 12 }, { 20, 6 }, { 160, 50 } }) do
    vim.o.columns = size[1]
    vim.o.lines = size[2]
    vim.api.nvim_exec_autocmds("VimResized", {})
    vim.wait(150)
    assert(not o.closed and o.composer.bufnr == option_buf, "resize must preserve composer")
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local c = vim.api.nvim_win_get_config(win)
        if c.relative ~= "" then
            assert(c.width <= size[1] and c.height <= size[2], vim.inspect(c))
        end
    end
end
vim.api.nvim_set_current_win(o.questions.winid)
press("M")
press("j<CR>")
assert(ctl.mode == "build")
local decisions = 0
ctl.permission = {
    tool = "read_file",
    target = "/project/brief.md",
    reason = "Understand deliverable",
    explanation = "Explicit permission required",
    mode = "build",
}
ctl.permission_reply = function(decision)
    assert(decision == "deny")
    decisions = decisions + 1
end
ctl:emit()
vim.wait(100)
press("n")
assert(decisions == 1 and not ctl.permission)
ui.close()
assert(ctl.state.status == "paused")
o = todo.plan()
assert(o.controller == ctl)
assert(ctl.cache.rounds[ctl:item_id(ctl:current())].answers.q.notes.a == "Extra option information")
ui.close()
-- Enter confirms and advances; Space toggles without advancing.
local o2 = todo.plan()
local ctl2 = o2.controller
local round2 = ctl2.cache.rounds[ctl2:item_id(ctl2:current())]
round2.questions[2] = vim.deepcopy(round2.questions[1])
round2.questions[2].id, round2.questions[2].multiple = "q2", true
round2.answers.q2 = { selected = {}, notes = {} }
o2.render()
vim.api.nvim_set_current_win(o2.questions.winid)
local layout_calls, original_update = 0, o2.layout.update
o2.layout.update = function(...)
    layout_calls = layout_calls + 1
    return original_update(...)
end
press("j<CR>")
assert(o2.tab == 2 and round2.answers.q.selected.b, "Enter must select and advance")
press("<Space>")
assert(o2.tab == 2 and round2.answers.q2.selected.a, "Space toggles without advancing")
press("<Space>")
assert(o2.tab == 2 and not round2.answers.q2.selected.a)
press("h")
assert(o2.tab == 1 and o2.option == 2, "restore per-question cursor")
assert(layout_calls == 0, "question tabs must not rebuild layout")
press("<CR>")
assert(o2.tab == 2, "Enter advances")
press("<Space>")
assert(round2.answers.q2.selected.a, "Space selects on the new question")
press("<CR>")
assert(o2.tab == 3, "Enter on the last question opens preview")
press("<Esc>")
press("h")
assert(o2.tab == 1 and o2.option == 2)
press("e")
vim.cmd("stopinsert")
vim.api.nvim_buf_set_lines(o2.composer.bufnr, 0, -1, false, { "explicit return" })
press("<CR>")
assert(vim.api.nvim_get_current_win() == o2.questions.winid)
assert(o2.tab == 1 and o2.option == 2)
assert(round2.answers.q.notes.b == "explicit return")
-- Autosaved drafts and the :w baseline must stay distinct.
press("e")
vim.cmd("stopinsert")
local saved_buf = o2.composer.bufnr
vim.api.nvim_buf_set_lines(saved_buf, 0, -1, false, { "saved baseline" })
vim.cmd("w")
vim.api.nvim_buf_set_lines(saved_buf, 0, -1, false, { "autosaved but discarded" })
assert(round2.answers.q.notes.b == "autosaved but discarded")
local quit_ok = pcall(vim.cmd, "q")
vim.wait(40)
assert(not quit_ok and vim.api.nvim_buf_is_valid(saved_buf), "q must retain daily draft")
vim.cmd("q!")
vim.wait(40)
assert(round2.answers.q.notes.b == "saved baseline", "q! must roll back the autosaved answer too")
assert(o2.composer.bufnr == saved_buf and not o2.closed)
assert(vim.api.nvim_get_current_win() == o2.questions.winid)
press("w")
assert(o2.tab == 3)
assert(title(o2.questions):find("Answer preview", 1, true))
assert(footer(o2):find("Send answers", 1, true), "preview must advertise submission")
press("<Esc>")
assert(o2.tab == 1 and o2.option == 2, "preview returns to exact question")
press("+")
assert(o2.maximized == "questions")
assert(title(o2.questions):find("Choices", 1, true), "maximize must preserve the pane title")
press("<C-j>")
assert(o2.maximized == "composer")
press("+")
assert(not o2.maximized)
-- Alternate screens cannot alter answers hidden behind them.
vim.api.nvim_set_current_win(o2.questions.winid)
local answers_before = vim.deepcopy(round2.answers)
local tab_before = o2.tab
press("b<Space>lhgse")
assert(o2.queue_open and vim.deep_equal(round2.answers, answers_before))
assert(not ctl2.busy and not ctl2:current().deferred, "queue preview must not finish or defer the hidden task")
assert(o2.tab == tab_before, "queue navigation changed an invisible question")
press("<CR>")
assert(not o2.queue_open and vim.deep_equal(round2.answers, answers_before))
press("l")
assert(o2.tab == 2)
press("l<Esc>")
assert(o2.tab == 2, "Esc must return from a preview reached through tabs")
-- Error output distinguishes unverified text and keeps internal paths in diagnostics.
ctl2.state.last_error = "Invalid AI response: /private/path/daily.lua:529: Understanding evidence must quote exactly"
ctl2.partial = "Unverified streamed response"
o2.render()
local timeline = table.concat(vim.api.nvim_buf_get_lines(o2.timeline.bufnr, 0, -1, false), "\n")
assert(timeline:find("Unverified response", 1, true) and not timeline:find("private/path", 1, true))
assert(footer(o2):find("Retry saved request", 1, true))
ctl2.state.last_error, ctl2.partial = nil, nil
-- Returning to preparation must not use the last option note as today's intention.
ctl2.state.intent = "Today's original intention"
ctl2.cache.drafts.intent = nil
press("p")
assert(o2.composing_key == "intent")
assert(ctl2.state.intent == "Today's original intention")
local original_start = ctl2.start
local starts = 0
ctl2.start = function(self)
    assert(self.state.intent == "Today's original intention")
    starts = starts + 1
end
press("<CR>w")
assert(starts == 1)
ctl2.start = original_start
ui.close()
-- Key configuration is shared with hints; collisions fail before opening a UI.
local keyset = require("todo.ui.daily_keys")
assert(not pcall(keyset.validate, { next_question = "q" }))
assert(not pcall(keyset.validate, { next_question = "h" }))
assert(not pcall(keyset.validate, { next_question = { bad = "key" } }))
assert(pcall(keyset.validate, { next_question = "]", read_latest = false }))
require("todo.config").get().ui.daily_keys = { next_question = "]", read_latest = false }
local custom = todo.plan()
assert(vim.api.nvim_buf_call(custom.questions.bufnr, function()
    return vim.fn.maparg("]", "n")
end) ~= "")
assert(vim.api.nvim_buf_call(custom.questions.bufnr, function()
    return vim.fn.maparg("l", "n")
end) == "")
assert(keyset.label("next_question") == "]" and keyset.label("read_latest") == "")
ui.close()
print("ok - daily inline questions, option notes, pause/reopen and 160→80→40→20→160 resize retains buffers")
vim.cmd("qa!")
