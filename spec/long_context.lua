package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
vim.env.XDG_STATE_HOME = vim.fn.tempname()
require("todo.config").setup({
    db_path = vim.fn.tempname() .. ".db",
    reminders = { enabled = false },
    ai = { enabled = true, api_key = "mock-long", context_tokens = 2048 },
})

local questions = require("todo.ai.questions")
local tools = require("todo.ai.tools")
local function fails(fn, label)
    assert(not pcall(fn), label .. " should fail")
end

-- Open-ended questions may have no options; choice questions are 3-5 only.
assert(questions.normalize({ questions = { { id = "open", question = "Anything?", options = {} } } }, 4))
assert(questions.normalize({
    questions = {
        { id = "one", question = "Pick", options = { "A", "B", "C" } },
    },
}, 4))
assert(questions.normalize({
    questions = {
        { id = "five", question = "Pick", options = { "A", "B", "C", "D", "E" } },
    },
}, 4))
fails(function()
    questions.normalize({
        questions = { { id = "two", question = "Pick", options = { "A", "B" } } },
    }, 4)
end, "two options")
fails(function()
    questions.normalize({
        questions = { { id = "dup", question = "Pick", options = { "Same", "same", "C" } } },
    }, 4)
end, "duplicate labels")
fails(function()
    questions.normalize({
        questions = { { id = "long", question = string.rep("x", 4001), options = { "A", "B", "C" } } },
    }, 4)
end, "overlong question")
assert(tools.validate_option_count(3, false))
assert(tools.validate_option_count(0, false))
fails(function()
    tools.validate_option_count(2, false)
end, "tool schema option count")
-- Malformed entries and extra questions must not discard an otherwise usable round.
local compact = questions.normalize({
    questions = {
        { id = "bad", question = "", options = {} },
        { id = "one", question = "Keep one?", options = {} },
        { id = "two", question = "Keep two?", options = {} },
        { id = "three", question = "Drop three?", options = {} },
    },
}, 2)
assert(#compact.questions == 2 and compact.questions[1].id == "one", "invalid questions must be dropped")
assert(compact.questions[2].id == "two", "rounds must be truncated to the configured limit")
-- Reproduces the "invalid options" failure from providers that return >5 choices.
local many = questions.normalize({
    questions = {
        { id = "many", question = "Pick one", options = { "A", "B", "C", "D", "E", "F" } },
    },
}, 4)
assert(#many.questions[1].options == 5, "extra options must be truncated instead of failing")
local not_list = questions.normalize({
    questions = {
        { id = "open", question = "Explain", options = { a = "A", b = "B" } },
    },
}, 4)
assert(#not_list.questions[1].options == 0, "non-list options must fall back to open-ended")
local long_option = questions.normalize({
    questions = {
        {
            id = "long",
            question = "Pick",
            options = {
                { label = string.rep("L", 600), description = string.rep("D", 2500) },
                { label = "B" },
                { label = "C" },
            },
        },
    },
}, 4)
assert(#long_option.questions[1].options[1].label == 500, "option labels must be clamped")
assert(#long_option.questions[1].options[1].description == 2000, "option descriptions must be clamped")
-- A declined question counts as handled and tells the AI not to ask again.
local declined = questions.normalize({
    questions = {
        { id = "q1", question = "First?", options = {} },
        { id = "q2", question = "Second?", options = {} },
    },
}, 4)
declined.answers.q1 = { selected = {}, notes = {}, custom = "", declined = true }
assert(questions.answered(declined, declined.questions[1]), "declined questions count as answered")
assert(not questions.answered(declined, declined.questions[2]))
assert(questions.transcript(declined):find("no answer needed", 1, true))
assert(questions.display(declined):find("Skipped", 1, true))

-- Long transcripts keep all answers and options without collapsing into an
-- unreadable single line.
local round = questions.normalize({
    questions = (function()
        local list = {}
        for index = 1, 4 do
            list[index] = {
                id = "q" .. index,
                header = string.rep("H", 40),
                question = string.rep("Long question ", 40),
                multiple = index % 2 == 0,
                options = {
                    { id = "a", label = string.rep("Option A ", 8), description = string.rep("detail ", 50) },
                    { id = "b", label = string.rep("Option B ", 8) },
                    { id = "c", label = string.rep("Option C ", 8) },
                    { id = "d", label = string.rep("Option D ", 8) },
                    { id = "e", label = string.rep("Option E ", 8) },
                },
            }
        end
        return list
    end)(),
}, 4)
for _, question in ipairs(round.questions) do
    round.answers[question.id] = {
        selected = { a = true, c = true },
        notes = { b = string.rep("note ", 20) },
        custom = string.rep("custom ", 20),
    }
end
local transcript, answers = questions.transcript(round)
assert(#transcript > 1000)
assert(transcript:find("Long question", 1, true))
assert(transcript:find("Option B", 1, true))
assert(transcript:find("custom", 1, true))
assert(answers.q1.notes.b and answers.q4.custom)
local display = questions.display(round)
assert(display:find("✓", 1, true) and display:find("↳", 1, true))

-- Long UI labels are truncated to the requested display width.
local viewmodel = require("todo.ui.viewmodel")
local long_task = {
    kind = "task",
    id = 1,
    title = string.rep("很长的标题", 40),
    status = "todo",
    priority = 0,
    due_date = "2099-12-31",
    due_time = "23:59",
    tags = { "one", "two", "three", "four", "five", "six" },
}
for _, width in ipairs({ 20, 30, 80 }) do
    local line1, line2 = viewmodel.card(long_task, width, "overdue", {
        plan_state = "today",
        ai_selected = true,
    })
    assert(vim.fn.strdisplaywidth(line1) <= width, "card line1 overflow at " .. width)
    assert(vim.fn.strdisplaywidth(line2) <= width, "card line2 overflow at " .. width)
end

-- Large workspaces switch to compact task summaries instead of sending every
-- full description. The full text remains available through read_tasks.
local store = require("todo.store").open(vim.fn.tempname() .. ".db")
local ws = require("todo.workspace").new(store)
local svc = require("todo.service").new(store)
local candidates = {}
for index = 1, 40 do
    local task = assert(
        svc:create({
            title = "Long task " .. index,
            description = string.rep("A long task description. ", 300),
            priority = index % 4,
        })
    )
    candidates[#candidates + 1] = task.sync_uuid
end
local ai = require("todo.ai").new(ws, svc)
local session = ai:start({ date = "2026-10-18", max_questions = 10, max_requests = 20 })
session.candidate_uuids = {}
for _, uuid in ipairs(candidates) do
    session.candidate_uuids[uuid] = true
end
local ok_ctx, payload = pcall(ai.context, ai, session)
assert(ok_ctx, payload)
assert(payload.full_task_text == false, "large workspace must compact task text")
assert(#payload.tasks == 40)
for _, task in ipairs(payload.tasks) do
    assert(task.description == nil, "compact snapshot must omit full descriptions")
    assert(task.task_ref and task.task_uuid)
end
assert(#payload.notes == 0)
store:close()

print("ok - long-context option schema, transcripts, card widths and compact workspace snapshots")
vim.cmd("qa!")
